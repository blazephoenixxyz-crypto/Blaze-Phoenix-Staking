// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  atq-1111 (staking front) — the ten-year emission, read as an adversary would
//
//  ORACLE: the schedule as the docs state it (12M a year for five years, then 6M a year for
//  five), written here in the test's own integer arithmetic. `emittedAt` is the thing measured,
//  never the yardstick.
//  TOLERANCES are derived, not chosen:
//   - curve: the per-second rate is floor(60M/HP), so after dt seconds of a period the curve
//     sits below the nominal line by less than dt wei, and never above it;
//   - accumulator: each `_updateGlobal` step floors reward*WAD/weight once, which strands less
//     than weight/WAD + 1 wei of that step's reward, and each settle floors once more.
//
//  1. The curve at the turns and one second either side; never above nominal; never decreasing.
//  2. The rate view at the turns.
//  3. Ten years on a funded pool: what leaves is never above the curve, the emission that ran
//     before anyone staked goes to the treasury, and nothing but floor dust stays behind.
//  4. Splitting a window into n updates never pays more than one update (I7).
//  5. The lock-versus-programme-end gates at their exact seconds.
//
//  Paired mutants: [ATQ-staking-53..63] in .github/scripts/mutants.py.
//  Run: forge test --match-path test/atq/AtqEmissionCurve.t.sol
// =============================================================================

import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";

contract AtqEmissionCurveTest is Base {
    uint256 internal constant HP     = 5 * 365 days;
    uint256 internal constant FIRST  = 60_000_000e18;
    uint256 internal constant SECOND = 30_000_000e18;
    uint256 internal constant ALL    = FIRST + SECOND;
    address internal constant STRANGER = address(0x57A6E);
    uint256 internal start;
    uint256 internal end;

    function setUp() public override {
        super.setUp();
        start = staking.emissionStart();
        end   = staking.emissionEnd();
        assertEq(end - start, 2 * HP, "ten years");
    }

    /// The nominal line and how far under it the per-second floor may leave the curve.
    function _nominal(uint256 t) internal view returns (uint256 e, uint256 slack) {
        if (t <= start) return (0, 0);
        if (t >= end) return (ALL, 0);
        uint256 dt = t - start;
        if (dt < HP) return (FIRST * dt / HP, dt);
        dt -= HP;
        return (FIRST + SECOND * dt / HP, dt);
    }

    function _poke() internal { vm.prank(STRANGER); staking.claimRewards(); }

    // ── 1. the curve ───────────────────────────────────────────────────────────────────────────
    function test_AtqEmissionCurve_ExactAtTheTurnsAndOneSecondEitherSide() public view {
        uint256 r1 = FIRST / HP;
        uint256 r2 = SECOND / HP;
        assertEq(staking.emittedAt(0), 0, "before time");
        assertEq(staking.emittedAt(start - 1), 0, "one second before the start");
        assertEq(staking.emittedAt(start), 0, "at the start");
        assertEq(staking.emittedAt(start + 1), r1, "first second");
        assertEq(staking.emittedAt(start + HP - 1), r1 * (HP - 1), "last second of period one");
        assertEq(staking.emittedAt(start + HP), FIRST, "the halving turn is exact");
        assertEq(staking.emittedAt(start + HP + 1), FIRST + r2, "first second of period two");
        assertEq(staking.emittedAt(end - 1), FIRST + r2 * (HP - 1), "last second of the programme");
        assertEq(staking.emittedAt(end), ALL, "the end is exact");
        assertEq(staking.emittedAt(end + 1), ALL, "one second after the end");
        assertEq(staking.emittedAt(type(uint256).max), ALL, "the far future");
        for (uint256 y = 1; y <= 10; ++y) {
            uint256 want = y <= 5 ? y * 12_000_000e18 : FIRST + (y - 5) * 6_000_000e18;
            uint256 got = staking.emittedAt(start + y * 365 days);
            assertLe(got, want, "a year mark above the schedule");
            assertLt(want - got, 5 * 365 days, "a year mark under the schedule by more than the floor");
        }
    }

    function testFuzz_AtqEmissionCurve_NeverAboveNominalNeverDecreasing(uint256 a, uint256 b) public view {
        a = bound(a, start - 10, end + 10);
        b = bound(b, a, end + 10);
        uint256 ea = staking.emittedAt(a);
        uint256 eb = staking.emittedAt(b);
        (uint256 na, uint256 slack) = _nominal(a);
        assertLe(ea, na, "above the nominal schedule");
        if (slack == 0) assertEq(ea, na, "off the schedule where no floor applies");
        else assertLt(na - ea, slack, "under the schedule by more than the floor");
        assertLe(ea, eb, "the curve went down");
        assertLe(eb, ALL, "above 90M");
        // one more second never releases more than the first-period rate plus the turn's remainder
        if (a < end) assertLe(staking.emittedAt(a + 1) - ea, FIRST / HP + FIRST % HP, "a second too rich");
    }

    // ── 2. the rate view ───────────────────────────────────────────────────────────────────────
    function test_AtqRewardRateView_AtTheTurns() public {
        uint256 r1 = FIRST / HP;
        assertEq(staking.currentRewardPerSec(), r1, "start");
        vm.warp(start + HP - 1);
        assertEq(staking.currentRewardPerSec(), r1, "last second of period one");
        vm.warp(start + HP);
        assertEq(staking.currentRewardPerSec(), r1 / 2, "the halving turn");
        vm.warp(end - 1);
        assertEq(staking.currentRewardPerSec(), r1 / 2, "last second of the programme");
        vm.warp(end);
        assertEq(staking.currentRewardPerSec(), 0, "the end");
    }

    // ── 3. ten years, end to end ───────────────────────────────────────────────────────────────
    function testFuzz_AtqTenYears_NothingAboveTheCurve_TheUnstakedHeadGoesToTheTreasury(
        uint256 head, uint256 stake, uint256[12] memory gaps
    ) public {
        head  = bound(head, 0, 3 * 365 days);
        stake = bound(stake, 10_000e18, 30_000_000e18);
        vm.prank(admin);
        staking.fundEmission(ALL);
        vm.warp(start + head);
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        staking.deposit(stake, 2555);
        uint256 weight = stake * staking.boostByDays(2555) / 10_000;     // the largest weight the book ever holds
        uint256 steps = 1;
        for (uint256 i; i < gaps.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(gaps[i], 1, 400 days));
            vm.roll(vm.getBlockNumber() + 20);
            _poke();
            ++steps;
        }
        if (vm.getBlockTimestamp() < end) vm.warp(end);
        vm.warp(vm.getBlockTimestamp() + 1 + bound(gaps[0], 0, 30 days));
        vm.roll(vm.getBlockNumber() + 20);
        vm.startPrank(alice);
        staking.claimRewards();
        staking.withdraw(stake);
        vm.stopPrank();
        steps += 3;                                      // the claim, the withdrawal, and the sweep below
        uint256 paid = token.balanceOf(alice) - aliceBefore;

        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(admin);
        try staking.sweepUndistributedEmission() {} catch (bytes memory why) {
            assertEq(bytes4(why), BlazePhoenixStaking.Staking__ZeroAmount.selector, "the sweep refused for another reason");
        }
        uint256 swept = token.balanceOf(treasury) - treasuryBefore;

        (uint256 headNominal, uint256 headSlack) = _nominal(start + head);
        assertLe(paid, ALL - (headNominal - headSlack), "the staker was paid emission from before the deposit");
        assertGe(swept + headSlack, headNominal, "the emission nobody earned did not reach the treasury");
        assertLe(paid + swept, ALL, "more than 90M left the contract");
        // what stays behind is floor dust only: one floor per update step, one per settle
        assertLe(token.balanceOf(address(staking)), steps * (weight / 1e18 + 2), "value stranded in the contract");
    }

    // ── 4. splitting a window never pays more ──────────────────────────────────────────────────
    function testFuzz_AtqSplittingAWindowNeverPaysMore(uint256 stake, uint256 span, uint8 cuts) public {
        stake = bound(stake, 10_000e18, 30_000_000e18);
        span  = bound(span, 1 days, 4 * 365 days);
        uint256 n = bound(cuts, 2, 24);
        vm.prank(admin);
        staking.fundEmission(ALL);
        vm.prank(alice);
        staking.deposit(stake, 2555);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 weight = stake * staking.boostByDays(2555) / 10_000;

        uint256 snap = vm.snapshot();
        vm.warp(t0 + span);
        uint256 b = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards();
        uint256 once = token.balanceOf(alice) - b;
        vm.revertTo(snap);

        for (uint256 i = 1; i < n; ++i) { vm.warp(t0 + span * i / n); _poke(); }
        vm.warp(t0 + span);
        b = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards();
        uint256 split = token.balanceOf(alice) - b;

        assertGt(once, 0, "vacuous: nothing was earned");
        assertLe(split, once, "splitting the window paid more");
        assertLe(once - split, n * (weight / 1e18 + 1), "splitting the window lost more than the floors");
    }

    // ── 5. the lock gates against the programme end ────────────────────────────────────────────
    function test_AtqLockGates_AtTheirExactSeconds() public {
        vm.prank(admin);
        staking.fundEmission(1_000_000e18);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockTooShort.selector);
        staking.deposit(1e18, 89);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockTooLong.selector);
        staking.deposit(1e18, 2556);
        vm.prank(alice);
        staking.deposit(1e18, 2555);
        vm.prank(bob);
        staking.deposit(1e18, 90);
        vm.roll(vm.getBlockNumber() + 11);

        // the last second a 90-day lock still fits, and the first it does not
        vm.warp(end - 90 days);
        assertEq(staking.maxLockDaysAvailable(), 90, "ninety days left");
        uint256 snap = vm.snapshot();
        vm.prank(carol);
        staking.deposit(1e18, 90);
        vm.revertTo(snap);
        vm.prank(carol);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
        staking.deposit(1e18, 91);
        vm.warp(end - 90 days + 1);
        assertEq(staking.maxLockDaysAvailable(), 89, "eighty-nine days left");
        vm.prank(carol);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
        staking.deposit(1e18, 90);
        vm.prank(bob);                                   // bob's 90 days have elapsed: a fresh lock is a longer one
        vm.expectRevert(BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
        staking.lock(90);

        // the last second of the programme, and the end itself
        vm.warp(end - 1);
        assertEq(staking.maxLockDaysAvailable(), 0, "less than a day left");
        vm.prank(carol);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
        staking.deposit(1e18, 90);
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmissionNotEnded.selector);
        staking.sweepUndistributedEmission();
        vm.warp(end);
        vm.prank(carol);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmissionEnded.selector);
        staking.deposit(1e18, 90);
        vm.prank(bob);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmissionEnded.selector);
        staking.lock(90);
        uint256 t = token.balanceOf(treasury);
        vm.prank(admin);
        staking.sweepUndistributedEmission();            // open from the end's own second
        assertGt(token.balanceOf(treasury), t, "the sweep moved nothing");
    }
}
