// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================================
//  EMISSION SCHEDULE MATRIX — the 90M / 8-year schedule (a linear base plus a bonus that halves
//  every two years, biennial halving), range x vector x dimension.
//
//  Every literal below is derived independently of the contract, from the published numbers
//  (a 60M base, linear over 8 years; a 30M bonus paid 16M, 8M, 4M, 2M over four 2-year periods;
//  90M in total), never from the contract's closed form or its private series:
//    P = 2 * 365 days = 63 072 000 s (one period), T = 4 * P = 252 288 000 s (the close);
//    the base pays RB = floor(60M / T) = 237 823 439 878 234 398 wei/s throughout;
//    period q pays its bonus budget at the floored rate floor(budget_q / P), so the rate in force is
//      R0 = RB + floor(16M / P) = 491 501 775 748 351 090 wei/s,  R1 = RB + floor(8M / P) = 364 662 607 813 292 744,
//      R2 = RB + floor(4M / P)  = 301 243 023 845 763 571 wei/s,  R3 = RB + floor(2M / P) = 269 533 231 861 998 984;
//    the bonus floor leaves REM0..REM3 = 2 176 000 / 1 088 000 / 544 000 / 31 808 000 wei and the base
//    floor leaves REM_BASE = 60M - RB * T = 197 376 000 wei; each bonus remainder is paid in the
//    turn second that closes its period (at P, 2P, 3P), and REM3 + REM_BASE in the closing second
//    (at T), so the close is exact: E(T) = 90M = TOTAL_REWARDS.
//
//  Ranges:     dt = 0, 1 s, every year boundary k * 365 days (k = 1..8), kP - 1 / kP / kP + 1 at each
//              turn (k = 1, 2, 3), T - 1 / T / T + 1, long after the close; fuzz over dt.
//  Vectors:    funding at TOTAL - 1 / TOTAL / TOTAL + 1 and in tranches; empty windows (the first
//              year, the first period, the whole programme); a lone weight of 1 wei, MIN - 1, MIN,
//              MIN + 1; an under-funded window; the sweep at T - 1, at T, and after a full pool.
//  Dimensions: unit, fuzz (256 runs, the default), invariant (EmissionScheduleInvariantTest
//              below) and gas (emittedAt costs the same in all four periods: no loop over periods).
//
//  A lone position is normalised at its unlockTime (`pokeExpiredLock`, what any transaction's
//  lock window does), so the whole window is paid at one weight and the delivery is exact.
// =============================================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";

contract EmissionScheduleMatrixTest is Base {
    uint256 internal constant START = 1_900_000_000;                   // Base.setUp deploys here
    uint256 internal constant YEAR  = 31_536_000;                      // 365 days
    uint256 internal constant P     = 63_072_000;                      // 2 * 365 days
    uint256 internal constant T     = 252_288_000;                     // 4 * P = 2920 days
    uint256 internal constant TOTAL = 90_000_000e18;
    uint256 internal constant R0    = 491_501_775_748_351_090;         // floor(60M / T) + floor(16M / P) wei/s
    uint256 internal constant R1    = 364_662_607_813_292_744;         // floor(60M / T) + floor(8M / P)
    uint256 internal constant R2    = 301_243_023_845_763_571;         // floor(60M / T) + floor(4M / P)
    uint256 internal constant R3    = 269_533_231_861_998_984;         // floor(60M / T) + floor(2M / P)
    uint256 internal constant REM0  = 2_176_000;                       // 16M - floor(16M / P) * P
    uint256 internal constant REM1  = 1_088_000;                       // 8M - floor(8M / P) * P
    uint256 internal constant REM2  = 544_000;                         // 4M - floor(4M / P) * P
    uint256 internal constant REM3  = 31_808_000;                      // 2M - floor(2M / P) * P
    uint256 internal constant REM_BASE = 197_376_000;                  // 60M - floor(60M / T) * T
    uint256 internal constant MIN_W = 1_000e18;                        // MIN_EMISSION_WEIGHT
    /// TOTAL - E(90 days) = TOTAL - R0 * 90 days: what the window from a 90-day unlock to the close schedules.
    uint256 internal constant AFTER_90_DAYS = 86_178_082_191_780_821_924_160_000;
    /// Bound on what the per-share floor of the accumulator leaves accrued but unpaid.
    uint256 internal constant DUST_BOUND = 1e10;

    // ── helpers ──────────────────────────────────────────────────────────────────────────

    /// @dev What any transaction's lock window does once `who`'s commitment has elapsed.
    function _normaliseAtUnlock(address who) internal {
        (, uint256 unlock,,) = staking.lockInfoOf(who);
        vm.warp(unlock); vm.roll(block.number + 2);
        vm.prank(keeper); staking.pokeExpiredLock(who);
    }

    function _claimAtTheClose(address who) internal {
        vm.warp(START + T); vm.roll(block.number + 2);
        vm.prank(who); staking.claimRewards();
    }

    function _sweep() internal returns (uint256 swept) {
        uint256 before_ = token.balanceOf(treasury);
        vm.prank(admin); staking.sweepUndistributedEmission();
        swept = token.balanceOf(treasury) - before_;
    }

    /// @dev Gas of the callee frame alone (`vm.lastCallGas`), so the caller's code generation
    ///      around each call site cannot move the reading.
    function _calleeGasOfEmittedAt(uint256 x) internal view returns (uint256) {
        staking.emittedAt(x);
        return vm.lastCallGas().gasTotalUsed;
    }

    /// @dev The rate in force in period q (base + floored bonus), from the literals above.
    function _rate(uint256 q) internal pure returns (uint256) {
        return q == 0 ? R0 : q == 1 ? R1 : q == 2 ? R2 : R3;
    }

    /// @dev The bonus floor remainder of period q, paid in the second that closes it.
    function _rem(uint256 q) internal pure returns (uint256) {
        return q == 0 ? REM0 : q == 1 ? REM1 : q == 2 ? REM2 : REM3;
    }

    /// @dev Test-side oracle of the scheduled emission over (a, b], START <= a <= b: a walk over the
    ///      four periods at their rates, plus each remainder whose closing second lies in the window
    ///      (REM_BASE rides with REM3 at the close). Not the contract's closed form.
    function _scheduled(uint256 a, uint256 b) internal pure returns (uint256 s) {
        if (b > START + T) b = START + T;
        for (uint256 q; q < 4; ++q) {
            uint256 lo = START + q * P;
            uint256 hi = lo + P;
            uint256 x = a > lo ? a : lo;
            uint256 y = b < hi ? b : hi;
            if (y > x) s += _rate(q) * (y - x);
            if (a < hi && hi <= b) s += _rem(q);
        }
        if (a < START + T && START + T <= b) s += REM_BASE;
    }

    // ── ranges: the curve, unit ──────────────────────────────────────────────────────────

    function test_EmittedAtIsZeroAtTheStartAndAtEveryEarlierTime() public view {
        assertEq(staking.emissionStart(), START, "fixture: the programme starts at the deployment");
        assertEq(staking.emittedAt(START), 0, "dt = 0");
        assertEq(staking.emittedAt(START - 1), 0, "one second before the start");
        assertEq(staking.emittedAt(0), 0, "timestamp zero");
    }

    function test_EmittedAtOneSecondInIsExactlyTheInitialRate() public view {
        assertEq(staking.emittedAt(START + 1), 491_501_775_748_351_090,
                 "one second at the period-0 rate: floor(60M / 2920 days) + floor(16M / 730 days)");
    }

    function test_EmittedAtEachYearReleasesItsExactScheduledDelta() public view {
        uint256[8] memory d = [
            uint256(15_499_999_999_999_999_974_240_000),   // year 1: R0 * 365 days
            15_499_999_999_999_999_976_416_000,            // year 2: R0 * 365 days + REM0 (the first turn second)
            11_499_999_999_999_999_974_784_000,            // year 3: R1 * 365 days
            11_499_999_999_999_999_975_872_000,            // year 4: R1 * 365 days + REM1 (the second turn)
            9_499_999_999_999_999_975_056_000,             // year 5: R2 * 365 days
            9_499_999_999_999_999_975_600_000,             // year 6: R2 * 365 days + REM2 (the third turn)
            8_499_999_999_999_999_959_424_000,             // year 7: R3 * 365 days
            8_500_000_000_000_000_188_608_000              // year 8: R3 * 365 days + REM3 + REM_BASE (the closing second)
        ];
        uint256 sum;
        for (uint256 k = 1; k <= 8; ++k) {
            uint256 delta = staking.emittedAt(START + k * YEAR) - staking.emittedAt(START + (k - 1) * YEAR);
            assertEq(delta, d[k - 1], string.concat("year ", vm.toString(k)));
            sum += d[k - 1];
        }
        assertEq(sum, TOTAL, "oracle self-check: the eight years partition the budget");
        assertEq(staking.emittedAt(START + 2 * YEAR), 30_999_999_999_999_999_950_656_000,
                 "two years: the first period's 31M less the 49 344 000 wei the base floor holds back to the close");
    }

    /// Each of the three turns (2, 4 and 6 years): the second before is on the old period's line,
    /// the turn second pays the old rate plus that period's bonus remainder, the next second the new rate.
    function test_EmittedAtEachBiennialTurnJumpsByTheRatePlusTheFloorRemainder() public view {
        uint256[3] memory before_ = [
            uint256(30_999_999_508_498_224_200_128_910), 53_999_999_635_337_392_086_931_256, 72_999_999_698_756_976_005_660_429
        ];
        uint256[3] memory at_ = [
            uint256(30_999_999_999_999_999_950_656_000), 53_999_999_999_999_999_901_312_000, 72_999_999_999_999_999_851_968_000
        ];
        uint256[3] memory after_ = [
            uint256(31_000_000_364_662_607_763_948_744), 54_000_000_301_243_023_747_075_571, 73_000_000_269_533_231_713_966_984
        ];
        for (uint256 k = 1; k <= 3; ++k) {
            string memory turn = string.concat("turn ", vm.toString(k), " (", vm.toString(2 * k), " years)");
            uint256 b = staking.emittedAt(START + k * P - 1);
            uint256 a = staking.emittedAt(START + k * P);
            uint256 n = staking.emittedAt(START + k * P + 1);
            assertEq(b, before_[k - 1], string.concat(turn, ": kP - 1, still on the old period's line"));
            assertEq(a, at_[k - 1],     string.concat(turn, ": kP, the anchor"));
            assertEq(n, after_[k - 1],  string.concat(turn, ": kP + 1, one second at the new rate"));
            assertEq(a - b, _rate(k - 1) + _rem(k - 1), string.concat(turn, ": the turn second pays the old rate plus the bonus remainder"));
            assertEq(n - a, _rate(k), string.concat(turn, ": the next second pays the new rate"));
        }
        assertEq(at_[0] - before_[0], 491_501_775_750_527_090, "turn 1 second: R0 + 2 176 000 wei");
        assertEq(at_[1] - before_[1], 364_662_607_814_380_744, "turn 2 second: R1 + 1 088 000 wei");
        assertEq(at_[2] - before_[2], 301_243_023_846_307_571, "turn 3 second: R2 + 544 000 wei");
    }

    function test_EmittedAtTheEightYearCloseReadsExactlyTotalRewards() public view {
        assertEq(staking.emissionEnd() - staking.emissionStart(), T, "fixture: the programme lasts eight 365-day years");
        uint256 before_ = staking.emittedAt(START + T - 1);
        assertEq(before_, 89_999_999_730_466_767_908_817_016, "T - 1: still on the period-3 line");
        assertEq(staking.emittedAt(START + T), TOTAL, "T: exactly TOTAL_REWARDS");
        assertEq(staking.emittedAt(START + T + 1), TOTAL, "T + 1: flat");
        assertEq(TOTAL - before_, 269_533_232_091_182_984,
                 "the closing second pays R3 plus the 31 808 000 + 197 376 000 wei the two floors left");
        assertEq(TOTAL - before_, R3 + REM3 + REM_BASE, "oracle self-check");
    }

    function test_EmittedAtStaysAtTotalRewardsForeverAfterTheClose() public view {
        assertEq(staking.emittedAt(START + T + 100 * YEAR), TOTAL, "a century after the close");
        assertEq(staking.emittedAt(type(uint256).max), TOTAL, "the end of time");
    }

    function test_CurrentRewardPerSecHalvesTheBonusEveryTwoYearsAndStopsAtEight() public {
        assertEq(staking.currentRewardPerSec(), R0, "dt = 0");
        for (uint256 k = 1; k <= 3; ++k) {
            string memory turn = string.concat("turn ", vm.toString(k));
            vm.warp(START + k * P - 1); assertEq(staking.currentRewardPerSec(), _rate(k - 1), string.concat(turn, ": kP - 1"));
            vm.warp(START + k * P);     assertEq(staking.currentRewardPerSec(), _rate(k), string.concat(turn, ": kP, the bonus halved"));
            vm.warp(START + k * P + 1); assertEq(staking.currentRewardPerSec(), _rate(k), string.concat(turn, ": kP + 1"));
        }
        vm.warp(START + T - 1); assertEq(staking.currentRewardPerSec(), R3, "T - 1");
        vm.warp(START + T);     assertEq(staking.currentRewardPerSec(), 0,  "T: closed");
        vm.warp(START + T + 1); assertEq(staking.currentRewardPerSec(), 0,  "T + 1");
    }

    // ── ranges: the curve, fuzz ──────────────────────────────────────────────────────────

    function testFuzz_EmittedAtNeverDecreasesAndNeverExceedsTotalRewards(uint256 x, uint256 step) public view {
        uint256 a = bound(x, START - 1 days, START + T + 1 days);
        uint256 b = a + bound(step, 0, T);
        uint256 ea = staking.emittedAt(a);
        uint256 eb = staking.emittedAt(b);
        assertLe(ea, eb, "monotone non-decreasing");
        assertLe(eb, TOTAL, "never above TOTAL_REWARDS");
    }

    function testFuzz_EmittedAtGrowsLinearlyAtThePeriodRateInsideEachPeriod(uint256 q, uint256 o1, uint256 o2) public view {
        q  = bound(q, 0, 3);
        o1 = bound(o1, 0, P - 1);
        o2 = bound(o2, 0, P - 1);
        if (o1 > o2) (o1, o2) = (o2, o1);
        uint256 base = START + q * P;
        assertEq(staking.emittedAt(base + o2) - staking.emittedAt(base + o1), _rate(q) * (o2 - o1));
    }

    /// A window that crosses at least one turn: it pays each period's rate over its share of the
    /// window plus the bonus remainder of every period it closes.
    function testFuzz_AWindowAcrossTheTurnsPaysEachRateAndTheFloorRemainders(uint256 q, uint256 a, uint256 b) public view {
        q = bound(q, 0, 2);
        a = bound(a, START + q * P, START + (q + 1) * P - 1);
        b = bound(b, START + (q + 1) * P, START + T - 1);
        assertEq(staking.emittedAt(b) - staking.emittedAt(a), _scheduled(a, b));
    }

    function testFuzz_TheLastWindowClosesAtExactlyTotalRewards(uint256 a, uint256 b) public view {
        a = bound(a, START + 3 * P, START + T - 1);
        b = bound(b, START + T, type(uint256).max);
        assertEq(staking.emittedAt(b) - staking.emittedAt(a), R3 * (START + T - a) + REM3 + REM_BASE);
    }

    /// Two producers of "the rate in force": `currentRewardPerSec` and the one-second step of `emittedAt`.
    function testFuzz_TheRateInForceIsTheOneSecondStepOfTheCurve(uint256 dt) public {
        dt = bound(dt, 0, T - 1);
        vm.warp(START + dt);
        uint256 rate = staking.currentRewardPerSec();
        assertEq(rate, _rate(dt / P), "the rate in force is the period's floored rate");
        uint256 step = staking.emittedAt(START + dt + 1) - staking.emittedAt(START + dt);
        uint256 rem;
        if (dt + 1 == T) rem = REM3 + REM_BASE;
        else if ((dt + 1) % P == 0) rem = _rem((dt + 1) / P - 1);
        assertEq(step, rate + rem, "one second of the curve pays the rate (and the remainders in the turn and closing seconds)");
    }

    /// The accumulator delivers the curve's delta: with one weight in the pool and a funded reserve,
    /// `totalRewardDistributed` moves by exactly the scheduled emission of the window.
    function testFuzz_AFullPoolReceivesExactlyTheCurveDeltaOfAnyWindow(uint256 a, uint256 b) public {
        vm.prank(admin); staking.fundEmission(TOTAL);
        vm.prank(alice); staking.deposit(1_000_000e18, 2555);      // unlock at 7 years: one weight throughout
        uint256 last = START + 2555 days - 1;
        a = bound(a, START + 1, last);
        b = bound(b, a, last);
        vm.warp(a); vm.roll(block.number + 2);
        vm.prank(alice); staking.claimRewards();
        uint256 d0 = staking.totalRewardDistributed();
        vm.warp(b); vm.roll(block.number + 2);
        vm.prank(alice); staking.claimRewards();
        assertEq(staking.totalRewardDistributed() - d0, _scheduled(a, b));
    }

    // ── vectors: funding against the cap ─────────────────────────────────────────────────

    function test_FundEmissionAcceptsTotalMinusOneThenTheLastWei_OneWeiMoreIsRefused() public {
        vm.startPrank(admin);
        staking.fundEmission(TOTAL - 1);
        staking.fundEmission(1);
        assertEq(staking.totalEmissionFunded(), TOTAL, "the cap is reachable to the wei");
        vm.expectRevert(BlazePhoenixStaking.Staking__CapExceeded.selector);
        staking.fundEmission(1);
        vm.stopPrank();
        assertEq(staking.rewardReserve(), TOTAL, "the refused wei never landed");
    }

    function test_FundEmissionAcceptsExactlyTotalRewardsInOneCall() public {
        vm.prank(admin); staking.fundEmission(TOTAL);
        assertEq(staking.totalEmissionFunded(), TOTAL);
        assertEq(staking.rewardReserve(), TOTAL);
        assertEq(token.balanceOf(address(staking)), TOTAL, "the tokens arrived");
    }

    function test_FundEmissionRefusesTotalRewardsPlusOneWei() public {
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__CapExceeded.selector);
        staking.fundEmission(TOTAL + 1);
        assertEq(staking.totalEmissionFunded(), 0);
    }

    function test_SplitFundingReachesTotalRewards_OneWeiMoreIsRefused() public {
        vm.startPrank(admin);
        staking.fundEmission(12_000_000e18);
        staking.fundEmission(48_000_000e18);
        staking.fundEmission(30_000_000e18);
        assertEq(staking.totalEmissionFunded(), TOTAL, "three tranches add up to the cap");
        vm.expectRevert(BlazePhoenixStaking.Staking__CapExceeded.selector);
        staking.fundEmission(1);
        vm.stopPrank();
        assertEq(staking.rewardReserve(), TOTAL);
    }

    function test_FundEmissionRefusesZero() public {
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAmount.selector);
        staking.fundEmission(0);
    }

    function testFuzz_AnyTwoTranchesThatReachTotalRewardsAreAccepted_OneWeiMoreIsRefused(uint256 first) public {
        first = bound(first, 1, TOTAL - 1);
        vm.startPrank(admin);
        staking.fundEmission(first);
        staking.fundEmission(TOTAL - first);
        assertEq(staking.totalEmissionFunded(), TOTAL);
        assertEq(staking.rewardReserve(), TOTAL);
        vm.expectRevert(BlazePhoenixStaking.Staking__CapExceeded.selector);
        staking.fundEmission(1);
        vm.stopPrank();
    }

    // ── vectors: empty, throttled and under-funded windows ───────────────────────────────

    function test_AnEmptyFirstYearStaysInTheReserve_TheRestIsDeliveredExactly() public {
        vm.prank(admin); staking.fundEmission(TOTAL);
        vm.warp(START + YEAR); vm.roll(block.number + 2);           // a year with nobody staked
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        _normaliseAtUnlock(alice);
        _claimAtTheClose(alice);
        assertEq(staking.totalRewardDistributed(), 74_500_000_000_000_000_025_760_000, "TOTAL - E(1 year)");
        assertEq(staking.rewardReserve(), 15_499_999_999_999_999_974_240_000, "E(1 year) = R0 * 365 days stays in the reserve");
        assertEq(_sweep(), 15_499_999_999_999_999_974_240_000, "and the sweep sends exactly that to the treasury");
    }

    function test_AnEmptyFirstPeriodLeavesExactlyItsScheduleForTheSweep() public {
        vm.prank(admin); staking.fundEmission(TOTAL);
        vm.warp(START + P); vm.roll(block.number + 2);              // the first two years with nobody staked
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        _normaliseAtUnlock(alice);
        _claimAtTheClose(alice);
        assertEq(staking.totalRewardDistributed(), 59_000_000_000_000_000_049_344_000,
                 "periods 1-3, exactly: 59M plus the 49 344 000 wei of base floor paid at the close");
        assertEq(staking.rewardReserve(), 30_999_999_999_999_999_950_656_000, "the first period, exactly: E(2 years)");
        assertEq(_sweep(), 30_999_999_999_999_999_950_656_000, "the sweep sends the whole empty period to the treasury");
        assertEq(staking.rewardReserve(), 0);
    }

    function test_AnEmptyProgrammeSweepsTheWholeTotalRewardsToTheTreasury() public {
        vm.prank(admin); staking.fundEmission(TOTAL);
        vm.warp(START + T + 10 * YEAR); vm.roll(block.number + 2);  // long after the close
        assertEq(_sweep(), TOTAL, "nothing was delivered, so everything goes to the treasury");
        assertEq(staking.totalRewardDistributed(), 0);
        assertEq(staking.rewardReserve(), 0);
    }

    /// @dev A lone position of `amount`, normalised to 1.00x at its 90-day unlock, then left alone to
    ///      the close. Returns what the window [unlock, T] delivered at weight `amount`.
    function _deliveredAfterUnlock(uint256 amount) internal returns (uint256) {
        vm.prank(admin); staking.fundEmission(TOTAL);
        vm.prank(alice); staking.deposit(amount, 90);
        (, uint256 unlock,,) = staking.lockInfoOf(alice);
        assertEq(unlock, START + 90 days, "fixture: the window opens 90 days in");
        _normaliseAtUnlock(alice);
        assertEq(staking.totalBoostedEffective(), amount, "fixture: the weight is the stake at 1.00x");
        uint256 d0 = staking.totalRewardDistributed();
        _claimAtTheClose(alice);
        return staking.totalRewardDistributed() - d0;
    }

    function test_OneWeiOfWeightIsPaidTheScheduleScaledByOneOverMinWeight() public {
        assertEq(_deliveredAfterUnlock(1), 86_178, "floor(X * 1 / 1e21)");
    }

    function test_OneWeiBelowMinWeightIsStillThrottled() public {
        assertEq(_deliveredAfterUnlock(MIN_W - 1), 86_178_082_191_780_821_924_073_821, "floor(X * (1e21 - 1) / 1e21)");
    }

    function test_ExactlyMinWeightIsPaidTheFullSchedule() public {
        assertEq(_deliveredAfterUnlock(MIN_W), AFTER_90_DAYS, "no throttle at the mark");
    }

    function test_OneWeiAboveMinWeightIsPaidTheFullSchedule() public {
        assertEq(_deliveredAfterUnlock(MIN_W + 1), AFTER_90_DAYS, "no throttle above the mark");
    }

    function test_AnUnderfundedWindowPaysWhatTheReserveHeld_LaterFundingIsNeverRetroactive() public {
        vm.prank(admin); staking.fundEmission(10_000_000e18);
        vm.prank(alice); staking.deposit(1_000_000e18, 2555);
        vm.warp(START + 2 * YEAR); vm.roll(block.number + 2);       // ~31M scheduled against a 10M reserve
        vm.prank(admin); staking.fundEmission(80_000_000e18);       // settles the dry window first
        assertEq(staking.totalRewardDistributed(), 10_000_000e18, "the dry window paid what the reserve held");
        assertEq(staking.rewardReserve(), 80_000_000e18, "the new tranche is untouched by the past");
        _normaliseAtUnlock(alice);
        _claimAtTheClose(alice);
        assertEq(staking.totalRewardDistributed(), 69_000_000_000_000_000_049_344_000, "10M + (TOTAL - E(2 years))");
        assertEq(staking.rewardReserve(), 20_999_999_999_999_999_950_656_000, "80M - (TOTAL - E(2 years))");
        assertEq(_sweep(), 20_999_999_999_999_999_950_656_000, "what the dry window could not pay goes to the treasury");
    }

    // ── vectors: the sweep ───────────────────────────────────────────────────────────────

    function test_SweepIsRefusedOneSecondBeforeTheClose() public {
        vm.prank(admin); staking.fundEmission(TOTAL);
        vm.warp(START + T - 1); vm.roll(block.number + 2);
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmissionNotEnded.selector);
        staking.sweepUndistributedEmission();
    }

    function test_SweepIsAllowedAtTheCloseSecond() public {
        vm.prank(admin); staking.fundEmission(TOTAL);
        vm.warp(START + T); vm.roll(block.number + 2);
        assertEq(_sweep(), TOTAL, "at T the programme is over and the whole empty budget is swept");
    }

    function test_AFullPoolFromStartToCloseLeavesNoResidue_TheSweepRefusesZeroAmount() public {
        vm.prank(admin); staking.fundEmission(TOTAL);
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        _normaliseAtUnlock(alice);
        _claimAtTheClose(alice);
        assertEq(staking.totalRewardDistributed(), TOTAL, "a full pool takes the whole schedule");
        assertEq(staking.rewardReserve(), 0, "the schedule closes at exactly TOTAL_REWARDS: no residue at all");
        uint256 dust = staking.totalRewardDistributed() - staking.totalRewardsPaid();
        emit log_named_uint("accrued-but-unpaid accumulator dust (wei)", dust);
        assertLe(dust, DUST_BOUND, "the per-share floor leaves only dust owed");
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAmount.selector);
        staking.sweepUndistributedEmission();
    }

    // ── dimension: gas ───────────────────────────────────────────────────────────────────

    function test_EmittedAtCostsTheSameGasAnywhereInAnyPeriod() public {
        staking.emittedAt(START + 1);                                // warm the account and its slots
        uint256 g = _calleeGasOfEmittedAt(START + 12_345);
        emit log_named_uint("emittedAt callee gas, early in period 0", g);
        assertEq(_calleeGasOfEmittedAt(START + P - 1), g, "late in period 0");
        for (uint256 q = 1; q < 4; ++q) {
            uint256 early = _calleeGasOfEmittedAt(START + q * P + 12_345);
            uint256 late  = _calleeGasOfEmittedAt(START + (q + 1) * P - 1);
            emit log_named_uint(string.concat("emittedAt callee gas, early in period ", vm.toString(q)), early);
            emit log_named_uint(string.concat("emittedAt callee gas, late in period ", vm.toString(q)), late);
            assertEq(early, g, string.concat("early in period ", vm.toString(q), ": O(1), no loop over periods"));
            assertEq(late,  g, string.concat("late in period ", vm.toString(q), ": O(1), no loop over periods"));
        }
    }
}

// =============================================================================================
//  INVARIANT — warps, deposits (dust to whale), claims, lock pokes and partial fundings, no debt.
//  With no debt no pure yield exists, so `totalRewardDistributed` carries emission only (with
//  borrowers it also carries pure yield) and the emission book reads:
//    totalRewardDistributed <= emittedAt(min(now, emissionEnd)) <= TOTAL_REWARDS
//    rewardReserve + totalRewardDistributed == totalEmissionFunded
// =============================================================================================

contract EmissionScheduleHandler is Test {
    BlazePhoenixStaking internal immutable staking;
    address internal immutable admin;
    address internal immutable keeper;
    address[3] internal actors;
    uint256 internal constant TOTAL = 90_000_000e18;

    constructor(BlazePhoenixStaking staking_, address admin_, address keeper_, address a, address b, address c) {
        staking = staking_; admin = admin_; keeper = keeper_;
        actors[0] = a; actors[1] = b; actors[2] = c;
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1, 120 days);
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
    }

    function deposit(uint256 who, uint256 amount, uint256 lockDays) external {
        address a = actors[who % 3];
        uint256 avail = staking.maxLockDaysAvailable();
        if (avail < 90) return;                                      // the programme has closed for new locks
        lockDays = bound(lockDays, 90, avail);
        amount = bound(amount, 1, 1_000_000e18);                     // from dust (throttled) to whale
        (uint256 staked,,,,,,,,,,,,,) = staking.getUserInfo(a);
        if (staked + amount > 30_000_000e18) return;                 // MAX_STAKE_PER_WALLET
        vm.prank(a); staking.deposit(amount, lockDays);
    }

    function claim(uint256 who) external {
        vm.prank(actors[who % 3]); staking.claimRewards();
    }

    function poke(uint256 who) external {
        address a = actors[who % 3];
        (uint256 lockDays, uint256 unlock,,) = staking.lockInfoOf(a);
        if (lockDays == 0 || block.timestamp < unlock) return;
        vm.prank(keeper); staking.pokeExpiredLock(a);
    }

    function fund(uint256 amount) external {
        uint256 room = TOTAL - staking.totalEmissionFunded();
        if (room == 0) return;
        amount = bound(amount, 1, room < 20_000_000e18 ? room : 20_000_000e18);   // partial tranches
        vm.prank(admin); staking.fundEmission(amount);
    }
}

contract EmissionScheduleInvariantTest is Base {
    EmissionScheduleHandler internal handler;
    uint256 internal constant TOTAL = 90_000_000e18;

    function setUp() public override {
        super.setUp();
        vm.prank(admin); staking.fundEmission(10_000_000e18);        // a partial first tranche
        handler = new EmissionScheduleHandler(staking, admin, keeper, alice, bob, carol);
        targetContract(address(handler));
    }

    function invariant_DistributedNeverExceedsTheScheduleWhichNeverExceedsTotalRewards() public view {
        assertEq(staking.totalDebt(), 0, "regime: no debt, so the distributed side carries emission only");
        uint256 end = staking.emissionEnd();
        uint256 scheduled = staking.emittedAt(block.timestamp < end ? block.timestamp : end);
        assertLe(staking.totalRewardDistributed(), scheduled, "distributed <= scheduled");
        assertLe(scheduled, TOTAL, "scheduled <= TOTAL_REWARDS");
    }

    function invariant_ReservePlusDistributedIsAlwaysWhatWasFunded() public view {
        assertEq(staking.rewardReserve() + staking.totalRewardDistributed(), staking.totalEmissionFunded(),
                 "every funded wei is either in the reserve or distributed");
    }
}
