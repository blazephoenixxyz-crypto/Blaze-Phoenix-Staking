// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// EMG-01/EMG-02 regression suite — the pro-rata emergency haircut with UNDERWATER positions.
//
// THE HOLE the existing H-05 suite never reaches. H-05 proves the haircut over books where every
// position is positive-equity: the burn creates the pot shortfall, but `claims = totalStaked -
// totalDebt` still equals Σ max(equity,0) because nothing is underwater. The bug lives one step
// further out. When a position is UNDERWATER (debt > staked), it draws 0 from the pot yet its
// negative equity is netted into `claims`, so `claims = Σmax(equity,0) - overhang < E`. Two failures:
//   EMG-01: when the haircut engages, pot/claims > pot/E → early positive exiters over-paid →
//           the pot drains and a solvent latecomer's transfer reverts (permanently stranded).
//   EMG-02: in the band claims <= pot < E the gate `pot < claims` is FALSE → no haircut at all →
//           full-equity FCFS drain in the very state the haircut exists for.
// The fix is the denominator E = totalPositiveEquity = Σ max(staked - debt, 0), maintained through
// the single writer `_applyBoost`, plus an interest freeze during the emergency.
//
// Making a position underwater DETERMINISTICALLY: give it debt, warp years, poke it. Interest is
// deducted from its own stake; once accrued interest exceeds its stake the per-user clamp zeroes
// staked and leaves the debt — the position is maximally underwater (staked 0, debt D). A debt-free
// pure staker's stake never erodes (accrual for debt==0 only re-checkpoints), so the pure stakers'
// equities stay the literal constants and every payout assertion over THEM is to-the-wei. The
// underwater position contributes 0 to both the pot draw and E, so its (accrual-dependent) numbers
// never enter a payout — only the difference between the correct E and the buggy `claims`.
//
//   forge test --match-contract EMGHaircutUnderwater -vvv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract MockERC20EMG {
    string public name = "BlazePhoenix"; string public symbol = "BZPX"; uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function burn(address from, uint256 a) external { balanceOf[from] -= a; totalSupply -= a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal"); balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a, "bal");
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a, "allow"); allowance[f][msg.sender] = al - a; }
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract EMGHaircutUnderwaterTest is Test {
    BlazePhoenixStaking staking;
    MockERC20EMG token;
    address admin    = address(0xA11CE);
    address treasury = address(0x713A5);
    address alice = address(0x1);   // pure staker (positive)
    address bob   = address(0x2);   // pure staker (positive)
    address carol = address(0x3);   // pushed underwater
    address dave  = address(0x4);   // second underwater in the deep case
    address keeper = address(0x5);

    function _fund(address u) internal {
        token.mint(u, 1_000_000_000e18);
        vm.prank(u); token.approve(address(staking), type(uint256).max);
    }

    function setUp() public {
        vm.warp(1_900_000_000);
        token = new MockERC20EMG();
        vm.prank(admin);
        staking = new BlazePhoenixStaking(address(token), treasury);
        _fund(admin); _fund(alice); _fund(bob); _fund(carol); _fund(dave); _fund(keeper);
    }

    function _declareEmergency() internal {
        vm.prank(admin); staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(keeper); staking.declareEmergency();
        assertTrue(staking.emergencyMode());
    }

    function _exit(address who) internal returns (uint256 got) {
        uint256 before = token.balanceOf(who);
        vm.prank(who); staking.emergencyWithdraw();
        got = token.balanceOf(who) - before;
    }

    /// Drive `who` maximally underwater: borrow near the cap, warp many years, poke so the
    /// per-user interest clamp zeroes its stake. Returns once staked==0 && debt>0.
    function _makeUnderwater(address who, uint256 stakeAmt, uint256 borrowAmt) internal {
        vm.prank(who); staking.deposit(stakeAmt, 2555);
        vm.roll(block.number + 2);
        vm.prank(who); staking.borrow(borrowAmt);
        // Warp long enough that a single lazy accrual charges interest > the whole stake, so the
        // per-user clamp in _accrueInterestFor zeroes it. Utilisation here is tiny (large debt-free
        // stakers dominate), so the rate sits near the 1% floor and the accrual needs a very long
        // arm: ~1000 years. Interest is independent of emission (which ends at year 16), and a
        // debt-free staker's stake never erodes, so the pure stakers stay exact across this warp.
        vm.warp(block.timestamp + 365_000 days);
        vm.roll(block.number + 2);
        // `who` triggers its OWN accrual — repay runs _accrueInterestFor(who) first (clamping stake
        // to 0 as interest > stake), and because who == msg.sender the auto-maintenance sweep at the
        // end EXCLUDES it (the beneficiary is never self-liquidated). The position is left underwater
        // AND present — exactly the state the haircut must handle. A poke by a third party would let
        // the sweep liquidate it instead, dissolving the very case under test.
        vm.prank(who); staking.repay(1);
        (uint256 s, uint256 d,) = _position(who);
        assertEq(s, 0, "underwater setup: stake fully eroded to zero");
        assertGt(d, 0, "underwater setup: debt remains -> position is underwater");
    }

    function _position(address who) internal view returns (uint256 s, uint256 d, uint256 eq) {
        (s, d,,,,,,,,,,,,) = staking.getUserInfo(who);
        eq = s > d ? s - d : 0;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // ACCUMULATOR INVARIANT — the equality that empirically settles the design: at every point
    // totalPositiveEquity == Σ max(staked_i − debt_i, 0). Build a mixed book, then assert.
    // MUST FAIL on main (no such variable) — this test only compiles/passes post-fix.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_EMG_AccumulatorEqualsSumMaxEquity() public {
        vm.prank(alice); staking.deposit(600_000e18, 90);
        vm.prank(bob);   staking.deposit(400_000e18, 90);
        _makeUnderwater(carol, 90_000e18, 30_000e18);

        (uint256 sa, uint256 da,) = _position(alice);
        (uint256 sb, uint256 db,) = _position(bob);
        (uint256 sc, uint256 dc,) = _position(carol);
        uint256 sumMax =
            (sa > da ? sa - da : 0) + (sb > db ? sb - db : 0) + (sc > dc ? sc - dc : 0);
        assertEq(staking.totalPositiveEquity(), sumMax, "E accumulator == Sigma max(equity,0)");
        // and it strictly exceeds the buggy netting whenever an underwater position exists:
        uint256 claims = staking.totalStaked() > staking.totalDebt()
            ? staking.totalStaked() - staking.totalDebt() : 0;
        assertGt(staking.totalPositiveEquity(), claims, "E > claims while carol is underwater");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // EMG-01 — haircut ENGAGES but the buggy denominator would over-drain. Alice 600k, Bob 400k
    // (pure, exact), Carol underwater. E = 1,000,000e18. Burn so pot = 500,000e18 < E → fraction
    // 1/2 over the true E. Both pure stakers must get exactly half, Σpayouts ≤ pot, nobody stranded.
    // On main, `claims` < E would over-scale and Bob's transfer would revert (TransferFailed).
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_EMG01_UnderwaterPresent_NoOverdrain_NoStranding() public {
        vm.prank(alice); staking.deposit(600_000e18, 90);
        vm.prank(bob);   staking.deposit(400_000e18, 90);
        _makeUnderwater(carol, 90_000e18, 30_000e18);

        uint256 E = staking.totalPositiveEquity();
        assertEq(E, 1_000_000e18, "E = alice + bob (carol contributes 0)");

        // burn the pot down to half of E. pot holds alice+bob+carol stake minus carol's borrowed-out.
        uint256 pot0 = staking.backing();
        token.burn(address(staking), pot0 - 500_000e18);
        assertEq(staking.backing(), 500_000e18, "pot = E/2");

        _declareEmergency();

        uint256 aliceGot = _exit(alice);
        uint256 bobGot   = _exit(bob);
        assertEq(aliceGot, 300_000e18, "alice: exactly half of 600k");
        assertEq(bobGot,   200_000e18, "bob: exactly half of 400k -- NOT stranded");
        assertEq(aliceGot + bobGot, 500_000e18, "sum of payouts == pot, exact");
        assertEq(aliceGot * 400_000e18, bobGot * 600_000e18, "same fraction both exiters");

        // carol (underwater) draws nothing.
        uint256 carolGot = _exit(carol);
        assertEq(carolGot, 0, "underwater position draws 0 from the pot");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // EMG-02 — the DISARM band. Deep-underwater dave makes `claims` small enough that
    // claims < pot < E. On main the gate `pot < claims` is false → no haircut → FCFS full-pay
    // → the late pure staker is stranded. Post-fix the gate compares against E and engages.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_EMG02_DisarmBand_HaircutEngages_LateStakerPaid() public {
        vm.prank(alice); staking.deposit(600_000e18, 90);
        vm.prank(bob);   staking.deposit(400_000e18, 90);
        _makeUnderwater(dave, 200_000e18, 60_000e18);   // large residual debt shrinks `claims`

        uint256 E = staking.totalPositiveEquity();
        assertEq(E, 1_000_000e18, "E = alice + bob");
        uint256 claims = staking.totalStaked() > staking.totalDebt()
            ? staking.totalStaked() - staking.totalDebt() : 0;

        // choose pot in the band claims < pot < E.
        uint256 potTarget = (claims + E) / 2;
        assertGt(potTarget, claims, "pot above the buggy claims");
        assertLt(potTarget, E, "pot below the true E");
        uint256 pot0 = staking.backing();
        token.burn(address(staking), pot0 - potTarget);
        assertEq(staking.backing(), potTarget, "pot in the disarm band");

        _declareEmergency();

        uint256 aliceGot = _exit(alice);
        uint256 bobGot   = _exit(bob);
        // both are haircut by pot/E; the LATE staker must still be paid > 0 (the EMG-02 anchor).
        assertGt(aliceGot, 0);
        assertGt(bobGot, 0, "late pure staker never stranded in the disarm band");
        assertLe(aliceGot + bobGot, potTarget, "never over-drains the pot");
        assertEq(aliceGot * 400_000e18, bobGot * 600_000e18, "same fraction");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // EXIT-ORDER INVARIANCE with an underwater position present. Same book as EMG-01, opposite
    // order; each pure staker's payout must be identical to the wei. On main an underwater exit
    // between them would shift the denominator (72 vs 90 swing).
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_EMG_ExitOrderInvariant_WithUnderwater() public {
        vm.prank(alice); staking.deposit(600_000e18, 90);
        vm.prank(bob);   staking.deposit(400_000e18, 90);
        _makeUnderwater(carol, 90_000e18, 30_000e18);
        uint256 pot0 = staking.backing();
        token.burn(address(staking), pot0 - 500_000e18);
        _declareEmergency();

        // order: carol (underwater) FIRST, then bob, then alice.
        uint256 carolGot = _exit(carol);
        uint256 bobGot   = _exit(bob);
        uint256 aliceGot = _exit(alice);
        assertEq(carolGot, 0);
        assertEq(bobGot,   200_000e18, "bob half regardless of carol exiting first");
        assertEq(aliceGot, 300_000e18, "alice half regardless of order");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // S4 — interest is FROZEN during the emergency: warp inside the halt and assert no
    // retroactive interest is charged, and cancelEmergency resumes with no lump.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_EMG_S4_InterestFrozenDuringEmergency() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(alice); staking.borrow(300_000e18);

        _declareEmergency();
        uint256 idxAtHalt = staking.accInterestPerDebt();

        vm.warp(block.timestamp + 365 days);       // a year passes under the halt
        // a fresh exit must not have accrued anything for the emergency window:
        uint256 idxAfterWarp = staking.accInterestPerDebt();
        assertEq(idxAfterWarp, idxAtHalt, "interest index frozen across the emergency");

        // cancel and confirm no retroactive lump on the next accrual.
        vm.prank(admin); staking.cancelEmergency();
        vm.prank(admin); staking.unpause();
        vm.roll(block.number + 2);
        vm.prank(bob); staking.deposit(1e18, 90);   // any action advances the index from NOW
        // one block of interest at most — the year under halt was not charged.
        assertApproxEqAbs(staking.accInterestPerDebt(), idxAtHalt, 1e12,
            "no retroactive charge for the frozen window");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // HONEST OPERATION UNCHANGED — solvent (pot >= E) emergency pays full net equity, no haircut,
    // exactly as before the fix. Guards against the haircut taxing a solvent exit.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_EMG_SolventEmergency_FullEquityUnchanged() public {
        vm.prank(alice); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(alice); staking.borrow(300e18);
        assertEq(staking.backing(), 700e18, "pot == E boundary");
        _declareEmergency();
        uint256 got = _exit(alice);
        assertEq(got, 700e18, "full net equity, no haircut when solvent");
    }
}
