// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  atq-1111 (staking front) — stateful campaign WITH the emergency surface
//
//  test/InvariantsFullSurface.t.sol leaves emergency mode out on purpose. This
//  campaign keeps its whole handler and adds: a token-level loss (the balance drops
//  under the books), declareEmergency, cancelEmergency, pause, unpause, syncEquity,
//  absorbBadDebt and emergencyWithdraw, in any sequence with the normal surface.
//
//  What is held after EVERY call:
//    * the floor-free conservation identity, EXACT up to the dust once the two things the
//      contract cannot know are added by the test: the simulated loss (balance side) and the
//      haircut each breached exit left behind (book side);
//    * totalPositiveEquity is never below the stored positive equity (a stale-low
//      total would over-pay a haircut), and is exact once every position is synced;
//    * the borrower registry is exactly the positions with stored debt;
//    * inside an emergency: paused, and emission and interest do not move;
//    * an exit never pays above the stored equity and leaves nothing behind;
//    * cancelEmergency never succeeds on a short book; syncEquity never reverts.
//  ORACLES: raw storage of the positions (staked, debt, interest index), the token balance and
//  plain integer arithmetic.
//
//  Paired mutants: [ATQ-staking-40..43] in .github/scripts/mutants.py.
//  Run: forge test --match-path test/atq/AtqEmergencySurface.invariant.t.sol
// =============================================================================

import {StdInvariant, console2} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Base, MockERC20} from "../BlazePhoenixStaking.t.sol";
import {FullSurfaceHandler} from "../InvariantsFullSurface.t.sol";

contract AtqEmergencyHandler is FullSurfaceHandler {
    uint256 internal constant USERS_SLOT = 36;
    uint256 internal constant DUST = 1e10;
    address public adm;
    address public guardian;

    uint256 public lost;                    // tokens taken out of the balance by the simulated loss
    uint256 public lossEvents;
    uint256 public haircut;                 // equity the breached exits did not pay
    uint256 public haircutExits;
    uint256 public exitOverpaid;
    uint256 public exitLeftover;
    uint256 public cancelledWhileBreached;
    uint256 public cancelRefusedSolvent;    // fix1112: a solvent book must stay cancellable after exits
    uint256 public frozenMoved;
    uint256 public equityMismatch;
    uint256 public syncReverted;

    bool internal frozenSet;
    uint256 internal fDist; uint256 internal fAccR; uint256 internal fAccI; uint256 internal fIntG;

    constructor(BlazePhoenixStaking s, MockERC20 t, address[] memory a, address adm_, address guardian_)
        FullSurfaceHandler(s, t, a) { adm = adm_; guardian = guardian_; }

    function raw(address a) public view returns (uint256 s, uint256 d) {
        uint256 base = uint256(keccak256(abi.encode(a, USERS_SLOT)));
        s = uint256(vm.load(address(staking), bytes32(base)));
        d = uint256(vm.load(address(staking), bytes32(base + 1)));
    }
    /// Equity of a position after the interest it already owes is attributed (what an exit pays on).
    function trueEquity(address a) public view returns (uint256) {
        (uint256 s, uint256 d) = raw(a);
        if (d != 0) {
            uint256 base = uint256(keccak256(abi.encode(a, USERS_SLOT)));
            uint256 idx = uint256(vm.load(address(staking), bytes32(base + 5)));
            uint256 i = d * (staking.accInterestPerDebt() - idx) / 1e18;
            s -= i > s ? s : i;
        }
        return s > d ? s - d : 0;
    }
    function sumEquity() public view returns (uint256 e) {
        for (uint256 i = 0; i < actors.length; i++) { (uint256 s, uint256 d) = raw(actors[i]); if (s > d) e += s - d; }
    }

    /// Inside one emergency, emission and interest stand still. The snapshot belongs to ONE episode:
    /// it is taken by the first handler action that sees the emergency and dropped by the cancel
    /// (the only way out). A write made from the invariant function itself is not kept between
    /// steps, so the handler's own actions carry the snapshot; the invariant only compares.
    function observe() public {
        if (!staking.emergencyMode()) { frozenSet = false; return; }
        uint256 a = staking.totalRewardDistributed(); uint256 b = staking.accRewardPerShare();
        uint256 c = staking.accInterestPerDebt();     uint256 d = staking.totalInterestAccruedGlobal();
        if (!frozenSet) { fDist = a; fAccR = b; fAccI = c; fIntG = d; frozenSet = true; }
        else if (a != fDist || b != fAccR || c != fAccI || d != fIntG) frozenMoved++;
    }

    function simulateLoss(uint256 amt) public {
        if (lossEvents >= 2) return;
        uint256 bal = token.balanceOf(address(staking));
        if (bal < 2) return;
        // three scales: inside the dust, a few tokens, and anything up to the whole balance
        if (amt % 3 == 0) amt = bound(amt, 1, 2e10);
        else if (amt % 3 == 1) amt = bound(amt, 1, bal > 1_000e18 ? 1_000e18 : bal - 1);
        else amt = bound(amt, 1, bal - 1);
        vm.prank(address(staking)); token.transfer(address(0xDEAD), amt);
        lost += amt; lossEvents++; _hit("simulateLoss");
    }
    function declareEmergency() public {
        vm.prank(guardian);
        try staking.declareEmergency() { frozenSet = false; observe(); _hit("declareEmergency"); } catch {}
    }
    function cancelEmergency() public {
        bool breached = staking.backing() + DUST < staking.owed();
        observe();                      // before the prank: observe() makes external calls
        vm.prank(adm);
        try staking.cancelEmergency() { frozenSet = false; if (breached) cancelledWhileBreached++; _hit("cancelEmergency"); }
        catch { if (!breached && staking.emergencyMode()) cancelRefusedSolvent++; }
    }
    function pause() public { vm.prank(guardian); try staking.pause() { _hit("pause"); } catch {} }
    function unpause() public { vm.prank(adm); try staking.unpause() { _hit("unpause"); } catch {} }
    function syncEquity(uint256 seed) public {
        if (!staking.emergencyMode()) return;
        observe();
        try staking.syncEquity(_actor(seed)) { _hit("syncEquity"); } catch { syncReverted++; }
    }
    function syncAll() public {
        if (!staking.emergencyMode()) return;
        observe();
        for (uint256 i = 0; i < actors.length; i++) {
            try staking.syncEquity(actors[i]) {} catch { syncReverted++; }
        }
        if (staking.totalPositiveEquity() != sumEquity()) equityMismatch++;
        _hit("syncAll");
    }
    function absorbBadDebt(uint256 seed, uint256 amt) public {
        amt = bound(amt, 1, 1_000_000e18);
        observe();
        vm.prank(_actor(seed));
        try staking.absorbBadDebt(amt) { _hit("absorbBadDebt"); } catch {}
    }
    function emergencyWithdraw(uint256 seed) public {
        address a = _actor(seed);
        observe();
        uint256 eq = trueEquity(a);
        uint256 b0 = token.balanceOf(a);
        uint256 r0 = staking.rewardReserve();
        uint256 p0 = staking.protocolReserve();
        vm.prank(a);
        try staking.emergencyWithdraw() {
            uint256 got = token.balanceOf(a) - b0;
            // fix1112: the hatch returns the exiter's stale-weight excess from `totalRewardDistributed`
            // to `rewardReserve` (emission, `_settleEmission`) and to `protocolReserve` (pure yield,
            // `_settlePure`); the frozen snapshot moves by exactly that, nothing else may move it.
            // An underwater exit can draw a reserve down to cover the loss: a reserve that fell
            // contributes 0, so the snapshot then under-moves and the frozen check turns red (fails safe).
            uint256 r1 = staking.rewardReserve();
            uint256 p1 = staking.protocolReserve();
            if (frozenSet) fDist -= (r1 > r0 ? r1 - r0 : 0) + (p1 > p0 ? p1 - p0 : 0);
            if (got > eq) exitOverpaid++;
            else if (got < eq) { haircut += eq - got; haircutExits++; }
            (uint256 s1, uint256 d1) = raw(a);
            if (s1 != 0 || d1 != 0 || staking.isTrackedBorrower(a) || staking.isTrackedLocker(a)) exitLeftover++;
            _hit("emergencyWithdraw");
        } catch {}
    }
    /// fix1112: the sequence lapse -> declare -> exit -> cancel in one call, so the fuzzer composes
    /// at every depth what the four independent handlers rarely line up: a lock that lapsed inside
    /// the window, a halt, a solvent exit that returns its stale excess (emission and pure yield)
    /// and the cancel that must still pass (`cancelRefusedSolvent` counts a refusal; `_check`
    /// asserts it stays 0, which is what kills the mutant "the hatch moves distributed but not the
    /// 3326 anchor" through the invariant itself).
    function lapseDeclareExitCancel(uint256 seed) public {
        passLockPeriod(91 days + (seed % 300 days));
        declareEmergency();
        emergencyWithdraw(seed);
        cancelEmergency();
    }
}

contract AtqEmergencySurfaceTest is StdInvariant, Base {
    AtqEmergencyHandler handler;
    uint256 internal constant DUST = 1e10;   // CONSERVATION_DUST

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        staking.fundEmission(1_000_000e18);      // small, so a loss can leave the pot under the equity
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.stopPrank();
        address[] memory a = new address[](4);
        a[0] = alice; a[1] = bob; a[2] = carol; a[3] = address(0x5);
        _fund(a[3]);
        handler = new AtqEmergencyHandler(staking, token, a, admin, keeper);
        targetContract(address(handler));
    }

    function _check() internal {
        handler.observe();
        uint256 bal  = token.balanceOf(address(staking));
        uint256 dist = staking.totalRewardDistributed();
        uint256 paid = staking.totalRewardsPaid();
        uint256 lost = handler.lost();
        uint256 lhs = bal + staking.totalDebt() + staking.totalBadDebt() + staking.stakedOverdraw() + lost;
        uint256 rhs = staking.totalStaked() + staking.rewardReserve() + staking.protocolReserve()
            + (dist > paid ? dist - paid : 0) + handler.totalDonated() + handler.haircut();
        assertGe(lhs + DUST, rhs, "identity: the books claim more than balance + loss explains");
        assertGe(rhs + DUST, lhs, "identity: the balance holds more than the books + haircut explain");
        assertGe(lost + DUST, handler.haircut(), "the exits were cut by more than was ever lost");

        assertGe(staking.totalPositiveEquity(), handler.sumEquity(), "totalPositiveEquity below the stored positive equity");
        for (uint256 i = 0; i < 4; i++) {
            address a = handler.actors(i);
            (, uint256 d) = handler.raw(a);
            assertEq(staking.isTrackedBorrower(a), d != 0, "borrower registry differs from the stored debt");
        }
        if (staking.emergencyMode()) assertTrue(staking.paused(), "an emergency that is not paused");

        assertEq(handler.frozenMoved(), 0, "emission or interest moved inside an emergency");
        assertEq(handler.exitOverpaid(), 0, "an exit paid above the stored equity");
        assertEq(handler.exitLeftover(), 0, "an exit left a position or a registry entry behind");
        assertEq(handler.cancelledWhileBreached(), 0, "cancelEmergency passed on a short book");
        assertEq(handler.cancelRefusedSolvent(), 0, "cancelEmergency refused on a solvent book");
        assertEq(handler.equityMismatch(), 0, "after syncing every position the accumulator is not the sum");
        assertEq(handler.syncReverted(), 0, "syncEquity reverted inside an emergency");
        assertTrue(handler.breakerTrips() == 0 || lost != 0, "the breaker tripped with no loss");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 150
    function invariant_AtqEmergencySurfaceKeepsTheBooksUpToTheSimulatedLoss() public {
        _check();
    }

    /// Per-campaign coverage is fuzz luck (see InvariantsFullSurface.afterInvariant): a run that
    /// opens with a pause or an emergency may settle no deposit at all, so nothing is demanded per
    /// run. This prints what the run reached; the deterministic walk below carries the per-action
    /// coverage claim and the paired mutants ([ATQ-staking-40], [42]) prove the campaign can fail.
    function afterInvariant() public view {
        console2.log("atq-emg", handler.calls("declareEmergency"), handler.calls("emergencyWithdraw"), handler.haircutExits());
        console2.log("atq-emg2", handler.calls("cancelEmergency"), handler.lossEvents(), handler.breakerTrips());
    }

    /// Anti-vacuity and a deterministic path through every added action: the handler's emergency
    /// actions do succeed, and the same checks hold along a scripted sequence that includes a
    /// borrower with unattributed interest, time passing inside the halt, and exits.
    function test_AtqScriptedEmergencySequenceHoldsEveryCheck() public {
        handler.declareEmergency(); _check();
        handler.cancelEmergency(); handler.unpause(); _check();
        assertEq(handler.calls("declareEmergency"), 1); assertEq(handler.calls("cancelEmergency"), 1);
        assertEq(handler.calls("unpause"), 1);

        for (uint256 i = 0; i < 4; i++) handler.deposit(i, 1_000_000e18, 90);
        assertEq(handler.calls("deposit"), 4, "setup: four positions");
        vm.roll(vm.getBlockNumber() + 11);
        handler.borrow(1, 400_000e18); handler.borrow(2, 100_000e18);
        assertEq(handler.calls("borrow"), 2, "setup: two borrowers");
        handler.passTime(30 days); _check();
        handler.pause(); handler.unpause(); _check();

        handler.simulateLoss(2_000_000e18);                 // 2e24 % 3 == 2: the third scale, taken as asked
        assertEq(handler.lost(), 2_000_000e18, "setup: the loss asked is the loss taken");
        assertGt(handler.lost(), 1_000_000e18, "setup: the loss is larger than the emission funded");
        handler.tripBreaker(3); _check();
        assertEq(handler.breakerTrips(), 1, "setup: the breaker trips on the short book");
        vm.warp(vm.getBlockTimestamp() + 20 days); vm.roll(vm.getBlockNumber() + 11);
        handler.cancelEmergency(); _check();
        assertEq(handler.calls("cancelEmergency"), 1, "a short book does not resume");
        handler.syncEquity(1); _check();
        handler.syncAll(); _check();
        handler.emergencyWithdraw(1); _check();             // a borrower
        vm.warp(vm.getBlockTimestamp() + 5 days);
        handler.emergencyWithdraw(0); _check();
        handler.emergencyWithdraw(2); handler.emergencyWithdraw(3); _check();
        assertEq(handler.calls("emergencyWithdraw"), 4, "every position exits");
        handler.cancelEmergency(); _check();                // still short: refused, and not counted as a solvent refusal
        assertEq(handler.calls("cancelEmergency"), 1, "a short book does not resume after the exits either");
        assertEq(handler.calls("syncAll"), 1); assertEq(handler.calls("syncEquity"), 1);
        assertEq(handler.haircutExits(), 4, "setup: the pot was short, every exit was cut");
        assertLe(token.balanceOf(address(staking)), 4, "a short pot is paid out to the last wei but the floors");
        handler.syncAll(); _check();
        assertEq(staking.totalPositiveEquity(), 0, "nothing is left to draw on the pot");
    }

    /// fix1112, second part (red at 80db7e9): on a solvent book, exits through the hatch carry a
    /// stale-weight excess back to the reserve; the cancel must still pass afterwards.
    function test_AtqScriptedSolventHatchKeepsTheCancelOpen() public {
        for (uint256 i = 0; i < 4; i++) handler.deposit(i, 1_000_000e18, 90);
        assertEq(handler.calls("deposit"), 4, "setup: four positions");
        handler.passLockPeriod(200 days); _check();         // every lock lapses inside the window
        handler.declareEmergency(); _check();
        assertEq(handler.calls("declareEmergency"), 1);
        uint256 r0 = staking.rewardReserve();
        handler.emergencyWithdraw(0); handler.emergencyWithdraw(2); _check();
        assertEq(handler.calls("emergencyWithdraw"), 2, "setup: two exits");
        assertEq(handler.haircutExits(), 0, "setup: a solvent pot pays in full");
        assertGt(staking.rewardReserve(), r0, "setup: the exits carried a stale-weight excess");
        handler.cancelEmergency(); _check();
        assertEq(handler.calls("cancelEmergency"), 1, "a solvent book resumes after the exits");
        assertFalse(staking.emergencyMode());
    }
}
