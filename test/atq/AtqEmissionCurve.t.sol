// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  atq-1111 (staking front) — the 8-year emission, read as an adversary would
//
//  ORACLE: the schedule as the docs state it (a 60M linear base over eight years plus a bonus
//  that halves every two years: 16M, 8M, 4M, 2M per two-year period), written here in the test's
//  own integer arithmetic. `emittedAt` is the thing measured, never the yardstick.
//  TOLERANCES are derived, not chosen:
//   - curve: the base rate is floor(60M/LEN) and the bonus rate of period p is floor(BONUS_p/HP),
//     so after dt seconds of the programme, inP of them in the current period, the curve sits
//     below the nominal line by less than dt + inP wei, and never above it;
//   - accumulator: each `_updateGlobal` step floors reward*WAD/weight once, which strands less
//     than weight/WAD + 1 wei of that step's reward, and each settle floors once more.
//
//  1. The curve at every turn and one second either side; never above nominal; never decreasing;
//     every second releases exactly its period's rate (plus the period's remainder at its turn).
//  2. The rate view at every turn.
//  3. Eight years on a funded pool: what leaves is never above the curve, the emission that ran
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
    uint256 internal constant HP     = 2 * 365 days;   // one bonus period
    uint256 internal constant LEN    = 4 * HP;         // eight years
    uint256 internal constant BASE   = 60_000_000e18;
    uint256 internal constant ALL    = 90_000_000e18;
    address internal constant STRANGER = address(0x57A6E);
    uint256 internal start;
    uint256 internal end;

    function setUp() public override {
        super.setUp();
        start = staking.emissionStart();
        end   = staking.emissionEnd();
        assertEq(end - start, LEN, "eight years");
    }

    /// The bonus of period p (16M, 8M, 4M, 2M).
    function _bonus(uint256 p) internal pure returns (uint256) {
        return [uint256(16_000_000e18), 8_000_000e18, 4_000_000e18, 2_000_000e18][p];
    }

    /// The bonus emitted by the periods before p.
    function _bonusBefore(uint256 p) internal pure returns (uint256 sum) {
        for (uint256 q; q < p; ++q) sum += _bonus(q);
    }

    /// The nominal line and how far under it the two per-second floors may leave the curve.
    function _nominal(uint256 t) internal view returns (uint256 e, uint256 slack) {
        if (t <= start) return (0, 0);
        if (t >= end) return (ALL, 0);
        uint256 dt = t - start;
        uint256 p = dt / HP;
        uint256 inP = dt - p * HP;
        return (BASE * dt / LEN + _bonusBefore(p) + _bonus(p) * inP / HP, dt + inP);
    }

    /// The curve to the wei, from the floored literal rates: base floor(60M/LEN) every second,
    /// bonus floor(BONUS_p/HP) in period p; each turn lands exactly on the completed bonus.
    function _exact(uint256 t) internal view returns (uint256) {
        if (t <= start) return 0;
        if (t >= end) return ALL;
        uint256 dt = t - start;
        uint256 p = dt / HP;
        return (BASE / LEN) * dt + _bonusBefore(p) + (_bonus(p) / HP) * (dt - p * HP);
    }

    function _poke() internal { vm.prank(STRANGER); staking.claimRewards(); }

    // ── 1. the curve ───────────────────────────────────────────────────────────────────────────
    function test_AtqEmissionCurve_ExactAtTheTurnsAndOneSecondEitherSide() public view {
        uint256 rb = BASE / LEN;
        assertEq(staking.emittedAt(0), 0, "before time");
        assertEq(staking.emittedAt(start - 1), 0, "one second before the start");
        assertEq(staking.emittedAt(start), 0, "at the start");
        assertEq(staking.emittedAt(start + 1), rb + _bonus(0) / HP, "first second");
        for (uint256 k = 1; k <= 3; ++k) {
            uint256 turn = start + k * HP;
            assertEq(staking.emittedAt(turn - 1), _exact(turn - 1), "last second of a period");
            assertEq(staking.emittedAt(turn), rb * k * HP + _bonusBefore(k), "a halving turn is exact");
            assertEq(staking.emittedAt(turn + 1), _exact(turn) + rb + _bonus(k) / HP, "first second of a period");
        }
        // the turns in wei: 31M, 54M, 73M less the base's floored share (49,344,000 wei a period)
        assertEq(staking.emittedAt(start + HP), 31_000_000e18 - 49_344_000, "end of period one");
        assertEq(staking.emittedAt(start + 2 * HP), 54_000_000e18 - 98_688_000, "end of period two");
        assertEq(staking.emittedAt(start + 3 * HP), 73_000_000e18 - 148_032_000, "end of period three");
        assertEq(staking.emittedAt(end - 1), _exact(end - 1), "last second of the programme");
        assertEq(staking.emittedAt(end), ALL, "the end is exact");
        assertEq(staking.emittedAt(end + 1), ALL, "one second after the end");
        assertEq(staking.emittedAt(type(uint256).max), ALL, "the far future");
        uint256[8] memory table = [uint256(15_500_000e18), 31_000_000e18, 42_500_000e18, 54_000_000e18,
            63_500_000e18, 73_000_000e18, 81_500_000e18, 90_000_000e18];
        for (uint256 y = 1; y <= 8; ++y) {
            (uint256 want, uint256 slack) = _nominal(start + y * 365 days);
            assertEq(want, table[y - 1], "oracle: the nominal line departs from the published table");
            uint256 got = staking.emittedAt(start + y * 365 days);
            assertLe(got, want, "a year mark above the schedule");
            if (slack == 0) assertEq(got, want, "the end mark is not exact");
            else assertLt(want - got, slack, "a year mark under the schedule by more than the floor");
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
        // one more second releases exactly its period's rate, plus that period's bonus remainder at
        // the turn that closes it and the base remainder at the end
        uint256 step;
        if (a >= start && a < end) {
            uint256 p = (a - start) / HP;
            step = BASE / LEN + _bonus(p) / HP;
            if ((a + 1 - start) % HP == 0) step += _bonus(p) % HP;
            if (a + 1 == end) step += BASE % LEN;
        }
        assertEq(staking.emittedAt(a + 1) - ea, step, "a second off its period's rate");
    }

    // ── 2. the rate view ───────────────────────────────────────────────────────────────────────
    function test_AtqRewardRateView_AtTheTurns() public {
        uint256 rb = BASE / LEN;
        assertEq(staking.currentRewardPerSec(), rb + _bonus(0) / HP, "start");
        for (uint256 k = 1; k <= 3; ++k) {
            vm.warp(start + k * HP - 1);
            assertEq(staking.currentRewardPerSec(), rb + _bonus(k - 1) / HP, "last second of a period");
            vm.warp(start + k * HP);
            assertEq(staking.currentRewardPerSec(), rb + _bonus(k) / HP, "a halving turn");
        }
        vm.warp(end - 1);
        assertEq(staking.currentRewardPerSec(), rb + _bonus(3) / HP, "last second of the programme");
        vm.warp(end);
        assertEq(staking.currentRewardPerSec(), 0, "the end");
    }

    // ── 3. eight years, end to end ─────────────────────────────────────────────────────────────
    function testFuzz_AtqEightYears_NothingAboveTheCurve_TheUnstakedHeadGoesToTheTreasury(
        uint256 head, uint256 stake, uint256[12] memory gaps
    ) public {
        head  = bound(head, 0, 3 * 365 days);            // the head reaches past the first turn
        stake = bound(stake, 10_000e18, 30_000_000e18);
        // the longest lock that still fits: 2555 days to the end of year 1, then the whole days left
        uint256 lockDays = (LEN - head) / 1 days;
        if (lockDays > 2555) lockDays = 2555;
        vm.prank(admin);
        staking.fundEmission(ALL);
        vm.warp(start + head);
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        staking.deposit(stake, lockDays);
        uint256 weight = stake * staking.boostByDays(lockDays) / 10_000;  // the largest weight the book ever holds
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
