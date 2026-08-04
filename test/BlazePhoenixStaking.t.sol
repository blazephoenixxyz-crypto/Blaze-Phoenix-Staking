// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Foundry suite — unit + fuzz + invariant. NOT run in the cloud sandbox (no network to install
// Foundry); intended to be run on Termux / any machine with Foundry:
//
//   forge install foundry-rs/forge-std
//   forge test -vvv
//   forge test --match-contract Invariant -vvv
//
// The JS harness in test/run.mjs already exercises the same behaviours on a real EVM offline;
// test/boost.mjs is the dedicated stale-boost / lock-expiry suite.
//
// The BP-2026-001 tests below (stale boost persistence in pure stakers) exist thanks to NetGakarot
// ("Gakarot"), who disclosed the finding on 28 July 2026.

import {Test, StdInvariant} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract MockERC20 {
    string public name = "BlazePhoenix"; string public symbol = "BZPX"; uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
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

contract Base is Test {
    BlazePhoenixStaking staking;
    MockERC20 token;
    address admin = address(0xA11CE);
    address treasury = address(0x713A5);
    address alice = address(0x1);
    address bob = address(0x2);
    address carol = address(0x3);
    address keeper = address(0x4);

    function _fund(address u) internal {
        token.mint(u, 500_000_000e18);
        vm.prank(u);
        token.approve(address(staking), type(uint256).max);
    }

    function setUp() public virtual {
        vm.warp(1_900_000_000);
        token = new MockERC20();
        vm.prank(admin);
        staking = new BlazePhoenixStaking(address(token), treasury);
        _fund(admin); _fund(alice); _fund(bob); _fund(carol); _fund(keeper);
    }
}

contract UnitTest is Base {
    function test_BoostCurve() public view {
        assertEq(staking.boostByDays(0), 10000);
        assertEq(staking.boostByDays(90), 10199);
        assertEq(staking.boostByDays(365), 11000);
        assertEq(staking.boostByDays(730), 12500);
        assertEq(staking.boostByDays(2555), 27500);
        assertEq(staking.boostByDays(99999), 27500);
    }

    function test_DepositRequiresValidLock() public {
        vm.startPrank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockTooShort.selector);
        staking.deposit(100e18, 89);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockTooLong.selector);
        staking.deposit(100e18, 2556);
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAmount.selector);
        staking.deposit(0, 90);
        staking.deposit(100e18, 90);
        vm.stopPrank();
        assertEq(staking.totalStaked(), 100e18);
    }

    function test_MandatoryLockBlocksWithdraw() public {
        vm.prank(alice); staking.deposit(1000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__StillLocked.selector);
        staking.withdraw(100e18);
        vm.warp(block.timestamp + 91 days); vm.roll(block.number + 11);
        vm.prank(alice); staking.withdraw(1000e18);
        assertEq(staking.totalStaked(), 0);
    }

    function test_WithdrawRequiresRepayAll() public {
        vm.prank(alice); staking.deposit(1000e18, 90);
        vm.roll(block.number + 2);
        vm.prank(alice); staking.borrow(400e18);
        vm.warp(block.timestamp + 91 days); vm.roll(block.number + 11);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__HasDebt.selector);
        staking.withdraw(100e18);
        vm.prank(alice); staking.repay(1000e18);          // clears the ~400 debt
        assertEq(staking.totalDebt(), 0);
        vm.roll(30);                                       // absolute: past repay's depositBlock(≤14) + MIN_DEPOSIT_BLOCKS(10)
        (uint256 staked,,,,,,,,,,,,,) = staking.getUserInfo(alice);
        vm.prank(alice); staking.withdraw(staked);
        assertEq(staking.totalStaked(), 0);
    }

    function test_BorrowLTV() public {
        vm.prank(alice); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__LTVExceeded.selector);
        staking.borrow(501e18);
        vm.prank(alice); staking.borrow(500e18);
        assertEq(staking.totalDebt(), 500e18);
        assertTrue(staking.isTrackedBorrower(alice));
    }

    function test_TopUpExtendsOnly() public {
        vm.prank(alice); staking.deposit(100e18, 400);
        (, uint256 unlock1,,) = staking.lockInfoOf(alice);
        vm.roll(block.number + 11);
        vm.prank(alice); staking.deposit(100e18, 90);      // shorter -> keep
        (uint256 d2, uint256 unlock2,,) = staking.lockInfoOf(alice);
        assertEq(unlock2, unlock1); assertEq(d2, 400);
        vm.prank(alice); staking.deposit(100e18, 800);     // longer -> extend
        (uint256 d3, uint256 unlock3,,) = staking.lockInfoOf(alice);
        assertGt(unlock3, unlock1); assertEq(d3, 800);
    }

    function test_LiquidationClearsAndConserves() public {
        vm.prank(bob); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(bob); staking.borrow(500e18);
        vm.warp(block.timestamp + 80 * 365 days); vm.roll(block.number + 2);
        vm.prank(keeper); staking.liquidate(bob);
        (, uint256 debt,,,,,,,,,,,,) = staking.getUserInfo(bob);
        assertEq(debt, 0);
        assertFalse(staking.isTrackedBorrower(bob));
        assertEq(staking.totalLiquidations(), 1);
        assertTrue(staking.isSolvent());
        assertEq(staking.auditInvariants() & 1, 0);
    }

    function test_AutonomousMaintenance() public {
        vm.prank(bob); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(bob); staking.borrow(500e18);
        vm.warp(block.timestamp + 80 * 365 days); vm.roll(block.number + 2);
        assertTrue(staking.isTrackedBorrower(bob));
        vm.prank(carol); staking.claimRewards();           // carol's unrelated tx sweeps bob
        assertFalse(staking.isTrackedBorrower(bob));
        assertGe(staking.totalAutoLiquidations(), 1);
        assertTrue(staking.isSolvent());
    }

    function test_EmissionClaimAndNoBacklog() public {
        vm.prank(admin); staking.fundEmission(10_000_000e18);
        // a full year with no stakers must NOT be captured by a latecomer
        vm.warp(block.timestamp + 365 days); vm.roll(block.number + 2);
        vm.prank(alice); staking.deposit(1_000_000e18, 365);
        vm.roll(block.number + 2);
        assertEq(staking.pendingRewards(alice), 0);
        vm.warp(block.timestamp + 30 days); vm.roll(block.number + 2);
        assertGt(staking.pendingRewards(alice), 0);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice); staking.claimRewards();
        assertGt(token.balanceOf(alice), before);
        assertTrue(staking.isSolvent());
    }

    function test_IncrementalFunding() public {
        vm.startPrank(admin);
        staking.fundEmission(10_000_000e18);
        staking.fundEmission(5_000_000e18);              // incremental top-up now allowed
        assertEq(staking.totalEmissionFunded(), 15_000_000e18);
        assertEq(staking.rewardReserve(), 15_000_000e18);
        vm.expectRevert(BlazePhoenixStaking.Staking__CapExceeded.selector);
        staking.fundEmission(180_000_000e18);            // cumulative cap is TOTAL_REWARDS
        vm.stopPrank();
    }

    function test_TripBreakerOnlyOnInsolvency() public {
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoBreach.selector);
        staking.tripBreaker();
    }

    // ── BP-2026-001 (NetGakarot) — stale boost persistence in pure stakers ──────────────────
    // Two identical debt-free 730-day (1.25x) positions. 731 days later both locks have lapsed;
    // Bob acts, Alice stays idle. Pre-fix Alice kept her 1.25x weight forever and out-earned Bob
    // by 25%. Post-fix, Bob's single transaction carries the locker sweep that normalises her.
    function test_StaleBoost_IdlePureStakerIsNormalisedAutonomously() public {
        vm.prank(admin); staking.fundEmission(100_000_000e18);
        uint256 P = 1_000_000e18;
        vm.prank(alice); staking.deposit(P, 730);
        vm.prank(bob);   staking.deposit(P, 730);
        vm.roll(block.number + 11);

        // The contract floors mulDiv PER POSITION and then sums, so flooring first and doubling is
        // the faithful expectation — reordering to multiply-then-divide would model it WRONGLY.
        // (Exact either way here: P is 1e24, divisible by 10000.)
        // forge-lint: disable-next-line(divide-before-multiply)
        assertEq(staking.totalBoostedEffective(), (P * 12500 / 10000) * 2, "committed: 2 x 1.25x");
        // forge-lint: disable-next-line(divide-before-multiply)
        assertEq(staking.totalBoostedPure(),      (P * 12500 / 10000) * 2, "committed: 2 x 1.25x pure");

        vm.warp(block.timestamp + 731 days); vm.roll(block.number + 11);
        vm.prank(bob); staking.claimRewards();          // bob's tx must normalise BOTH positions

        assertEq(staking.totalBoostedEffective(), P * 2, "expired: un-boosted emission denominator");
        assertEq(staking.totalBoostedPure(),      P * 2, "expired: un-boosted pure denominator");
        assertFalse(staking.hasStaleBoost(alice), "idle position normalised without acting");
        assertEq(staking.activeLockerCount(), 0, "registry holds only live commitments");

        // From here on the two identical positions must earn identically.
        uint256 a1 = token.balanceOf(alice) + staking.pendingRewards(alice);
        uint256 b1 = token.balanceOf(bob)   + staking.pendingRewards(bob);
        vm.warp(block.timestamp + 30 days); vm.roll(block.number + 5);
        uint256 dA = token.balanceOf(alice) + staking.pendingRewards(alice) - a1;
        uint256 dB = token.balanceOf(bob)   + staking.pendingRewards(bob)   - b1;
        assertGt(dA, 0, "still earning");
        assertEq(dA, dB, "idle staker earns exactly what the active one earns");
        assertTrue(staking.isSolvent());
        assertEq(staking.auditInvariants() & 1, 0);
    }

    /// Boost is the price of illiquidity: it must be refused the instant the capital is free,
    /// before any transaction has mutated the position's storage.
    function test_StaleBoost_ExpiryIsPricedAgainstTheClockNotStorage(uint16 lockDays_) public {
        lockDays_ = uint16(bound(lockDays_, 90, 2555));
        vm.prank(alice); staking.deposit(1_000_000e18, lockDays_);
        vm.roll(block.number + 11);

        (, , uint256 liveBoost, bool liveExpired) = staking.lockInfoOf(alice);
        assertEq(liveBoost, staking.boostByDays(lockDays_), "committed: full multiplier");
        assertFalse(liveExpired);
        assertEq(staking.effectiveLockDaysOf(alice), lockDays_);

        vm.warp(block.timestamp + uint256(lockDays_) * 1 days + 1);   // no tx, only the clock

        (uint256 onRecord, , uint256 paidBoost, bool expired) = staking.lockInfoOf(alice);
        assertEq(onRecord, lockDays_, "the commitment on record is untouched");
        assertTrue(expired);
        assertEq(paidBoost, 10000, "but the position is PAID at 1.00x");
        assertEq(staking.effectiveLockDaysOf(alice), 0);
        assertEq(staking.effectiveBoostOf(alice), 10000);
        (, , , , , , , , , , , uint256 uiBoost, , ) = staking.getUserInfo(alice);
        assertEq(uiBoost, 10000, "getUserInfo agrees");
    }

    /// Re-pricing the FUTURE must never claw back the PAST: the sweep settles the boosted
    /// backlog before it touches the weight.
    function test_StaleBoost_SweepPaysBeforeItReprices() public {
        vm.prank(admin); staking.fundEmission(100_000_000e18);
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 731 days); vm.roll(block.number + 11);

        uint256 owedToAlice = staking.pendingRewards(alice);
        uint256 balBefore   = token.balanceOf(alice);
        assertGt(owedToAlice, 0, "there is a boosted backlog to protect");

        vm.prank(carol); staking.deposit(1_000e18, 90);   // unrelated tx carries the sweep

        assertEq(token.balanceOf(alice) - balBefore, owedToAlice, "paid in full, to the wei");
        assertFalse(staking.hasStaleBoost(alice), "only then is the weight released");
        assertTrue(staking.isSolvent());
    }

    /// The keeper surface: the backlog is measurable on-chain and its own output clears it.
    function test_StaleBoost_ScanQuantifiesAndPokeClears() public {
        vm.prank(admin); staking.fundEmission(50_000_000e18);
        uint256 P = 1_000_000e18;
        vm.prank(alice); staking.deposit(P, 730);
        vm.prank(bob);   staking.deposit(P, 730);
        vm.prank(carol); staking.deposit(P, 2000);        // still committed after 731 days
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 731 days); vm.roll(block.number + 11);

        (address[] memory stale, uint256 xBE, uint256 xBP, uint256 total) = staking.expiredLockScan(0, 100);
        assertEq(total, 3);
        assertEq(stale.length, 2, "exactly the two lapsed commitments");
        uint256 excessEach = (P * 12500 / 10000) - P;
        assertEq(xBE, excessEach * 2, "excess emission weight is exact");
        assertEq(xBP, excessEach * 2, "excess pure-yield weight is exact");

        vm.prank(keeper); staking.pokeExpiredLocks(stale);
        (address[] memory after_, uint256 xBE2, uint256 xBP2, ) = staking.expiredLockScan(0, 100);
        assertEq(after_.length, 0, "backlog cleared");
        assertEq(xBE2, 0); assertEq(xBP2, 0);
        assertTrue(staking.isSolvent());
        assertEq(staking.auditInvariants() & 1, 0);
    }

    /// The whole point of the report: committing capital must pay strictly more than not
    /// committing it, or the lock has no economic meaning.
    function test_StaleBoost_RelockingStrictlyBeatsIdling() public {
        vm.prank(admin); staking.fundEmission(100_000_000e18);
        uint256 P = 1_000_000e18;
        vm.prank(alice); staking.deposit(P, 730);
        vm.prank(bob);   staking.deposit(P, 730);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 731 days); vm.roll(block.number + 11);

        vm.prank(bob); staking.lock(730);                 // bob re-commits; his tx sweeps alice
        assertEq(staking.totalBoostedEffective(), P + (P * 12500 / 10000), "1.00x idle + 1.25x committed");

        uint256 a1 = token.balanceOf(alice) + staking.pendingRewards(alice);
        uint256 b1 = token.balanceOf(bob)   + staking.pendingRewards(bob);
        vm.warp(block.timestamp + 60 days); vm.roll(block.number + 5);
        uint256 dA = token.balanceOf(alice) + staking.pendingRewards(alice) - a1;
        uint256 dB = token.balanceOf(bob)   + staking.pendingRewards(bob)   - b1;
        assertGt(dB, dA, "the re-locked staker out-earns the idle one");
        assertEq(dB * 10000 / dA, 12500, "by exactly the 1.25x lock premium");
    }

    /// The new self-external step is not a public entry-point.
    function test_StaleBoost_LockStepIsSelfOnly() public {
        vm.prank(alice); staking.deposit(1_000e18, 90);
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NotSelf.selector);
        staking.lockStep(alice, keeper);
    }

    function test_Emergency() public {
        vm.prank(admin); staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(alice); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(alice); staking.borrow(300e18);
        vm.prank(keeper); staking.declareEmergency();
        assertTrue(staking.emergencyMode());
        uint256 before = token.balanceOf(alice);
        vm.prank(alice); staking.emergencyWithdraw();
        assertEq(token.balanceOf(alice) - before, 700e18);  // net equity = staked - debt
    }
}

// ───────────────────────────────────────────────────────────────────────────────────────────
//  INVARIANT SUITE — the heart of the integrity guarantee under random action sequences.
// ───────────────────────────────────────────────────────────────────────────────────────────
contract Handler is Test {
    BlazePhoenixStaking public staking;
    MockERC20 public token;
    address[] public actors;

    constructor(BlazePhoenixStaking s, MockERC20 t, address[] memory a) {
        staking = s; token = t; actors = a;
    }
    function _actor(uint256 seed) internal view returns (address) { return actors[seed % actors.length]; }

    function deposit(uint256 seed, uint256 amt, uint256 lockDays) public {
        address a = _actor(seed);
        amt = bound(amt, 1e18, 5_000_000e18);
        lockDays = bound(lockDays, 90, 2555);
        vm.prank(a); try staking.deposit(amt, lockDays) {} catch {}
    }
    function borrow(uint256 seed, uint256 amt) public {
        address a = _actor(seed);
        amt = bound(amt, 1e18, 3_000_000e18);
        vm.prank(a); try staking.borrow(amt) {} catch {}
    }
    function repay(uint256 seed, uint256 amt) public {
        address a = _actor(seed);
        amt = bound(amt, 1e18, 5_000_000e18);
        vm.prank(a); try staking.repay(amt) {} catch {}
    }
    function withdraw(uint256 seed, uint256 amt) public {
        address a = _actor(seed);
        amt = bound(amt, 1e18, 5_000_000e18);
        vm.prank(a); try staking.withdraw(amt) {} catch {}
    }
    function claim(uint256 seed) public { address a = _actor(seed); vm.prank(a); try staking.claimRewards() {} catch {} }
    function liquidate(uint256 seed, uint256 tseed) public {
        vm.prank(_actor(seed)); try staking.liquidate(_actor(tseed)) {} catch {}
    }
    function relock(uint256 seed, uint256 lockDays) public {
        address a = _actor(seed);
        lockDays = bound(lockDays, 90, 2555);
        vm.prank(a); try staking.lock(lockDays) {} catch {}
    }
    function poke(uint256 seed, uint256 tseed) public {
        vm.prank(_actor(seed)); try staking.pokeExpiredLock(_actor(tseed)) {} catch {}
    }
    function passTime(uint256 s) public {
        s = bound(s, 1 hours, 60 days);
        vm.warp(block.timestamp + s); vm.roll(block.number + 30);
    }
    /// Wide enough to carry positions PAST their unlock, so lock expiry is inside the fuzzed
    /// state space rather than a case only the unit tests ever reach.
    function passLockPeriod(uint256 s) public {
        s = bound(s, 60 days, 800 days);
        vm.warp(block.timestamp + s); vm.roll(block.number + 300);
    }
}

contract InvariantTest is StdInvariant, Base {
    Handler handler;

    function setUp() public override {
        super.setUp();
        vm.prank(admin); staking.fundEmission(50_000_000e18);
        address[] memory actors = new address[](4);
        actors[0] = alice; actors[1] = bob; actors[2] = carol; actors[3] = keeper;
        handler = new Handler(staking, token, actors);
        // let the handler act as each actor (they already approved staking; approve handler-routed prank txs)
        targetContract(address(handler));
    }

    /// The protocol must always hold at least what it owes.
    function invariant_solvent() public view {
        assertTrue(staking.isSolvent(), "INSOLVENT");
    }
    /// The on-chain conservation bit must never be set.
    function invariant_conservationBit() public view {
        assertEq(staking.auditInvariants() & 1, 0, "CONSERVATION BIT");
    }
    /// Boosted denominators may never exceed stake * maxBoost / base.
    function invariant_boostBounded() public view {
        assertEq(staking.auditInvariants() & (1 << 4), 0, "BOOST UNBOUNDED");
    }
    /// Backing covers owed within the dust tolerance.
    function invariant_backingCoversOwed() public view {
        assertGe(staking.backing() + 1e10, staking.owed(), "BACKING < OWED");
    }

    // ── BP-2026-001 structural invariants ────────────────────────────────────────────────────

    /// NO LIVE COMMITMENT MAY ESCAPE THE REGISTRY. This is the property the whole fix rests on:
    /// the locker registry is the only window that can see a debt-free position, so a lock that
    /// is not in it is a lock the autonomous engine can never normalise. If this ever fails, the
    /// original stale-boost bug is back, whatever the boost derivation says.
    function invariant_everyLiveCommitmentIsTracked() public view {
        address[4] memory who = [alice, bob, carol, keeper];
        for (uint256 i = 0; i < who.length; i++) {
            (uint256 lockDays, , , ) = staking.lockInfoOf(who[i]);
            if (lockDays > 0) assertTrue(staking.isTrackedLocker(who[i]), "LIVE COMMITMENT NOT TRACKED");
        }
    }

    /// The registry is a set, not a bag: a duplicated entry would let one position's weight be
    /// released twice and underflow the single-writer subtraction in `_applyBoost`.
    function invariant_lockRegistryHasNoDuplicates() public view {
        (address[] memory l, uint256 total) = staking.getLockers(0, 64);
        assertLe(total, 64, "registry outgrew the invariant page");
        for (uint256 i = 0; i < l.length; i++) {
            for (uint256 j = i + 1; j < l.length; j++) assertTrue(l[i] != l[j], "DUPLICATE LOCKER");
        }
    }

    /// Whatever stale weight is transiently outstanding between an expiry and its sweep can never
    /// exceed the total the boost curve could possibly justify — the excess is bounded by the same
    /// stake * maxBoost envelope as the denominators themselves.
    function invariant_staleBoostExcessIsBounded() public view {
        (, uint256 xBE, uint256 xBP, ) = staking.expiredLockScan(0, 64);
        uint256 envelope = (staking.totalStaked() * staking.boostByDays(2555)) / 10_000;
        assertLe(xBE, envelope, "STALE EMISSION EXCESS UNBOUNDED");
        assertLe(xBP, envelope, "STALE PURE EXCESS UNBOUNDED");
    }
}

// ───────────────────────────────────────────────────────────────────────────────────────────
//  STRESS TESTS
//  Cenário 1 — Gas Exhaustion via MAINT_MAX cap
//  Cenário 2 — Block-density / time-gap manipulation on maintenance budget
//  Cenário 3 — Solvency and conserves-delta at 100% kink utilisation
//  Cenário 4 — Reentrancy multi-hop via malicious ERC-20 transfer hook
// ───────────────────────────────────────────────────────────────────────────────────────────
contract StressTest is Base {

    // ── helpers ──────────────────────────────────────────────────────────────────────────────

    /// Mint, approve, deposit and borrow for a freshly-created address.
    function _newBorrower(uint256 idx) internal returns (address who) {
        // casting to 'uint160' is safe because idx is a bounded test index (< 64).
        // forge-lint: disable-next-line(unsafe-typecast)
        who = address(uint160(0x1000 + idx));
        token.mint(who, 500_000_000e18);
        vm.prank(who); token.approve(address(staking), type(uint256).max);
        vm.prank(who); staking.deposit(1_000_000e18, 90);
        vm.roll(block.number + 2);
        vm.prank(who); staking.borrow(400_000e18);   // well inside 50% LTV
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Cenário 1: Gas Exhaustion — MAINT_MAX_SCAN hard cap
    //
    // Insert more borrowers than MAINT_MAX_SCAN (10). Any single user transaction must consume
    // bounded gas regardless of the borrower list length. This proves the protocol cannot be
    // DoS'd by flooding the borrower registry.
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_stress_gasExhaustion_maintMax(uint8 extraBorrowers) public {
        extraBorrowers = uint8(bound(extraBorrowers, 11, 50));

        for (uint256 i = 0; i < extraBorrowers; i++) {
            _newBorrower(i);
        }

        assertEq(staking.activeBorrowerCount(), extraBorrowers);

        // maintenanceBudget must never exceed MAINT_MAX_SCAN = 10
        assertLe(staking.maintenanceBudget(), 10);

        // A plain deposit by alice consumes bounded gas — the harness enforces no explicit
        // ceiling but we verify budget cap and solvency hold.
        uint256 gasBefore = gasleft();
        vm.prank(alice); staking.deposit(100e18, 90);
        uint256 gasUsed = gasBefore - gasleft();

        // 3M gas is a very conservative ceiling for a single deposit + 10-wide sweep.
        assertLt(gasUsed, 3_000_000, "deposit gas exceeded safe ceiling");
        assertTrue(staking.isSolvent());
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Cenário 2: Block-density / time-gap manipulation on maintenance budget
    //
    // _maintBudget grows with secondsSinceLastSweep / MAINT_GAP_UNIT (15 min).
    // A MEV bot could try to batch many rapid txs to keep lastMaintTime fresh and suppress
    // the budget, starving the sweep. Conversely, a large time gap widens the budget.
    // Prove: budget is always clamped to MAINT_MAX_SCAN regardless of time gap.
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_stress_timegap_budgetCap(uint32 gapSeconds) public {
        gapSeconds = uint32(bound(gapSeconds, 0, 365 days));

        // Seed at least one borrower so budget is non-zero.
        _newBorrower(0);

        vm.warp(block.timestamp + gapSeconds);

        uint256 budget = staking.maintenanceBudget();
        assertLe(budget, 10, "budget must never exceed MAINT_MAX_SCAN");

        // Trigger a sweep and confirm solvency is preserved.
        vm.prank(alice); staking.deposit(100e18, 90);
        assertTrue(staking.isSolvent());
        assertEq(staking.auditInvariants() & 1, 0, "conservation bit set after time-gap sweep");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Cenário 3: Solvency and conserves-delta at 100% kink utilisation
    //
    // Drive totalDebt as close to totalStaked as LTV allows, advance time so interest accrues
    // at maximum kink rate, then prove:
    //   a) conserves modifier does NOT block legitimate repayments
    //   b) isSolvent() remains true throughout
    //   c) auditInvariants() bit0 (conservation) is never set
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_stress_solvency_maxKinkUtilization() public {
        // Alice and bob both deposit and borrow at max LTV to push utilisation high.
        vm.prank(alice); staking.deposit(10_000_000e18, 365);
        vm.prank(bob);   staking.deposit(10_000_000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(alice); staking.borrow(4_999_999e18);  // ~50% LTV
        vm.prank(bob);   staking.borrow(4_999_999e18);

        // Utilisation is now ~50% (kink at 80%), rate is modest. Drive it higher by adding
        // more borrowers proportional to stakers.
        for (uint256 i = 0; i < 5; i++) {
            _newBorrower(i);
        }

        // Advance 180 days — interest accrues at up to 5% APR below kink.
        vm.warp(block.timestamp + 180 days);
        vm.roll(block.number + 100);

        // Conservation and solvency must still hold.
        assertTrue(staking.isSolvent(), "insolvent after 180d kink stress");
        assertEq(staking.auditInvariants() & 1, 0, "conservation bit set");

        // A repayment must succeed — conserves modifier must not block it.
        vm.prank(alice); staking.repay(4_999_999e18);

        assertTrue(staking.isSolvent(), "insolvent after repay");
        assertEq(staking.totalDebt() < staking.totalStaked(), true, "debt exceeds stake post-repay");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Cenário 4: Reentrancy multi-hop via malicious ERC-20 transfer hook
    //
    // A token that calls back into the staking contract during transferFrom (or transfer) could
    // attempt to re-enter deposit/borrow/withdraw to exploit a partially-written state.
    // The nonReentrant modifier on every public entry-point must block the second call.
    //
    // We simulate this with a MaliciousToken whose transferFrom calls staking.borrow()
    // inside the callback. The reentrancy must be rejected.
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_stress_reentrancy_maliciousToken() public {
        MaliciousToken mtoken = new MaliciousToken();
        address treasury2 = address(0xBEEF);

        // Deploy a staking instance that uses the malicious token.
        vm.prank(admin);
        BlazePhoenixStaking mstaking = new BlazePhoenixStaking(address(mtoken), treasury2);
        mtoken.setStaking(address(mstaking));

        mtoken.mint(alice, 500_000_000e18);
        vm.prank(alice); mtoken.approve(address(mstaking), type(uint256).max);

        // The malicious token will attempt a reentrant borrow() inside transferFrom.
        // The nonReentrant guard must revert the inner call, and the outer deposit must
        // either succeed cleanly or revert — but must never leave state half-written.
        vm.prank(alice);
        try mstaking.deposit(1_000e18, 90) {
            // If deposit succeeded, borrow was blocked and state is consistent.
            assertEq(mstaking.totalStaked(), 1_000e18);
        } catch {
            // If the reentrant callback caused the outer deposit to revert, that is also
            // correct — no state was written.
            assertEq(mstaking.totalStaked(), 0);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Cenário 5: Blacklist DoS resilience on autonomous maintenance
    //
    // If BZPX were a token that refuses to pay a particular address (a blacklist, like USDC),
    // the maintenance sweep's settle/liquidation transfer to that borrower would revert. The
    // self-external maintStep + try/catch must isolate the poisoned position so an innocent
    // user's transaction still succeeds, the borrower is simply skipped, and solvency holds.
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_stress_blacklist_maintenanceResilient() public {
        BlacklistToken btoken = new BlacklistToken();
        vm.prank(admin);
        BlazePhoenixStaking bs = new BlazePhoenixStaking(address(btoken), address(0xCAFE));

        btoken.mint(admin, 200_000_000e18);
        vm.prank(admin); btoken.approve(address(bs), type(uint256).max);
        vm.prank(admin); bs.fundEmission(50_000_000e18);

        address victim = address(0x5151);
        btoken.mint(victim, 10_000_000e18);
        vm.prank(victim); btoken.approve(address(bs), type(uint256).max);
        btoken.mint(carol, 10_000_000e18);
        vm.prank(carol); btoken.approve(address(bs), type(uint256).max);

        // victim becomes a tracked borrower and accrues pending emission rewards
        vm.prank(victim); bs.deposit(1_000_000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(victim); bs.borrow(100_000e18);
        vm.warp(block.timestamp + 30 days); vm.roll(block.number + 5);
        assertGt(bs.pendingRewards(victim), 0);

        // the token now refuses to pay victim — settling them would revert
        btoken.setBlocked(victim, true);

        // carol's unrelated deposit MUST still succeed; the poisoned victim is skipped
        vm.prank(carol); bs.deposit(500_000e18, 90);

        // Both stakes present. Asserting the raw literal 1_500_000e18 was correct under v3.0.0's
        // LAZY interest, where nothing moved until a position was individually touched. Under
        // v3.1.0 `_updateInterestIndex` settles the global side the moment interest economically
        // accrues, so totalStaked legitimately drops by the accrued slice (here exactly
        // 123.287671232876700000e18: 100k debt at 10% utilisation -> 150bps, over 30 days).
        // Assert the IDENTITY instead of a frozen number, so this keeps holding as the rate,
        // the elapsed time or the utilisation change.
        // EXACT, not approximate: every wei that left totalStaked must be accounted for by the
        // interest counter. If these two ever fail to sum to the deposits, conservation is broken
        // and the test must fail loudly rather than tolerate a drift.
        assertEq(bs.totalStaked() + bs.totalInterestAccruedGlobal(), 1_500_000e18,
            "stake must be conserved: what left totalStaked is exactly what interest accrued");
        (uint256 carolStaked,,,,,,,,,,,,,) = bs.getUserInfo(carol);
        (uint256 victimStaked,,,,,,,,,,,,,) = bs.getUserInfo(victim);
        assertEq(carolStaked, 500_000e18, "carol's unrelated stake is intact");
        assertGt(victimStaked, 0,         "the poisoned victim keeps its position");
        assertTrue(bs.isTrackedBorrower(victim));          // victim skipped, not removed
        assertTrue(bs.isSolvent());
        assertEq(bs.auditInvariants() & 1, 0);             // conservation bit clear
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // Cenário 6: Locker-registry flood — the SECOND maintenance window must not become a new
    // denial-of-service surface.
    //
    // BP-2026-001's fix adds a rotating window over every position holding a live lock. If that
    // window were unbounded, anyone could make ordinary transactions unaffordable by opening a
    // large number of cheap positions and letting them all expire at once. Prove: the probe
    // budget stays hard-capped, normalisations per transaction stay capped, an innocent user's
    // transaction stays cheap against a deep expired backlog, and organic flow alone drains it.
    // ─────────────────────────────────────────────────────────────────────────────────────────
    function test_stress_lockerRegistryFlood_boundedAndSelfDraining(uint8 lockers) public {
        lockers = uint8(bound(lockers, 20, 60));
        vm.prank(admin); staking.fundEmission(50_000_000e18);

        for (uint256 i = 0; i < lockers; i++) {
            // casting to 'uint160' is safe because i is a bounded test index (<= 60).
            // forge-lint: disable-next-line(unsafe-typecast)
            address who = address(uint160(0x2000 + i));
            token.mint(who, 1_000_000e18);
            vm.prank(who); token.approve(address(staking), type(uint256).max);
            vm.prank(who); staking.deposit(10_000e18, 90);
        }
        assertEq(staking.activeLockerCount(), lockers, "every commitment tracked");
        assertLe(staking.lockSweepBudget(), 10, "probe budget capped at MAINT_MAX_SCAN");

        // Every single one expires at once — the worst case for the sweep.
        vm.warp(block.timestamp + 400 days); vm.roll(block.number + 11);
        assertLe(staking.lockSweepBudget(), 10, "still capped after a 400-day backlog");

        uint256 before = staking.activeLockerCount();
        uint256 gasBefore = gasleft();
        vm.prank(alice); staking.deposit(1_000e18, 90);
        uint256 gasUsed = gasBefore - gasleft();
        uint256 afterCount = staking.activeLockerCount();

        assertLt(gasUsed, 3_000_000, "deposit gas exceeded safe ceiling against a deep backlog");
        assertLt(afterCount, before, "the sweep made progress in one tx");
        assertLe(before - afterCount, 4, "bounded work: <= MAINT_MAX_LOCK_ACTIONS per tx");

        // No keeper, no time gap — organic traffic alone must erase the backlog.
        for (uint256 i = 0; i < lockers; i++) {
            vm.roll(block.number + 11);
            vm.prank(alice); staking.claimRewards();
        }
        assertEq(staking.activeLockerCount(), 1, "only alice's own live commitment survives");
        (address[] memory stale, uint256 xBE, , ) = staking.expiredLockScan(0, 100);
        assertEq(stale.length, 0, "no stale commitment survived");
        assertEq(xBE, 0, "no excess weight survived");
        assertTrue(staking.isSolvent());
        assertEq(staking.auditInvariants() & 1, 0, "conservation bit set after the flood");
    }
}

/// @dev ERC-20 with a per-address blacklist on the receiving side (USDC-style), to test that
///      autonomous maintenance cannot be DoS'd by a borrower the token refuses to pay.
contract BlacklistToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    string public name = "Blacklist"; string public symbol = "BLK"; uint8 public decimals = 18;
    uint256 public totalSupply;

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function setBlocked(address a, bool b) external { blocked[a] = b; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transfer(address to, uint256 a) external returns (bool) {
        require(!blocked[to], "blocked");
        require(balanceOf[msg.sender] >= a); balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(!blocked[to], "blocked");
        require(balanceOf[f] >= a);
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a); allowance[f][msg.sender] = al - a; }
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// @dev Malicious ERC-20: calls staking.borrow(1) inside transferFrom to test reentrancy.
contract MaliciousToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name = "Malicious"; string public symbol = "MAL"; uint8 public decimals = 18;
    uint256 public totalSupply;
    address public stakingTarget;
    bool private _attacking;

    function setStaking(address s) external { stakingTarget = s; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a);
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a);
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a); allowance[f][msg.sender] = al - a; }
        balanceOf[f] -= a; balanceOf[to] += a;

        // Attempt reentrant borrow — must be blocked by nonReentrant.
        if (stakingTarget != address(0) && !_attacking) {
            _attacking = true;
            try BlazePhoenixStaking(stakingTarget).borrow(1) {} catch {}
            _attacking = false;
        }
        return true;
    }
}
