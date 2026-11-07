// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================================
//  EMISSION SCHEDULE MATRIX — the 90M / 10-year halving schedule, range x vector x dimension.
//
//  Every literal below is derived independently of the contract, from the published numbers
//  (12M a year in years 1-5, 6M a year in years 6-10, 90M in total), never from the contract's
//  closed form or its private series:
//    P = 5 * 365 days = 157 680 000 s (one period), T = 2 * P = 315 360 000 s (the close);
//    each period pays its budget (60M, then 30M) at the floored rate floor(budget / P):
//      R0 = floor(60M / P) = 380 517 503 805 175 038 wei/s,  R1 = floor(30M / P) = 190 258 751 902 587 519 wei/s;
//    the floor leaves REM0 = 60M - R0 * P = 8 160 000 wei and REM1 = 30M - R1 * P = 4 080 000 wei,
//    which the curve returns in the rollover second (at P) and in the closing second (at T), so the
//    anchors are exact: E(P) = 60M and E(T) = 90M = TOTAL_REWARDS.
//
//  Ranges:     dt = 0, 1 s, every year boundary k * 365 days (k = 1..10), P - 1 / P / P + 1,
//              T - 1 / T / T + 1, long after the close; fuzz over dt.
//  Vectors:    funding at TOTAL - 1 / TOTAL / TOTAL + 1 and in tranches; empty windows (the first
//              year, the first period, the whole programme); a lone weight of 1 wei, MIN - 1, MIN,
//              MIN + 1; an under-funded window; the sweep at T - 1, at T, and after a full pool.
//  Dimensions: unit, fuzz (256 runs, the default), invariant (EmissionScheduleInvariantTest
//              below) and gas (emittedAt is O(1) in the period index).
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
    uint256 internal constant P     = 157_680_000;                     // 5 * 365 days
    uint256 internal constant T     = 315_360_000;                     // 2 * P
    uint256 internal constant TOTAL = 90_000_000e18;
    uint256 internal constant R0    = 380_517_503_805_175_038;         // floor(60M / P) wei/s
    uint256 internal constant R1    = 190_258_751_902_587_519;         // floor(30M / P) wei/s
    uint256 internal constant REM0  = 8_160_000;                       // 60M - R0 * P
    uint256 internal constant REM1  = 4_080_000;                       // 30M - R1 * P
    uint256 internal constant MIN_W = 1_000e18;                        // MIN_EMISSION_WEIGHT
    /// TOTAL - E(90 days): what the window from a 90-day unlock to the close schedules.
    uint256 internal constant AFTER_90_DAYS = 87_041_095_890_410_958_904_512_000;
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

    // ── ranges: the curve, unit ──────────────────────────────────────────────────────────

    function test_EmittedAtIsZeroAtTheStartAndAtEveryEarlierTime() public view {
        assertEq(staking.emissionStart(), START, "fixture: the programme starts at the deployment");
        assertEq(staking.emittedAt(START), 0, "dt = 0");
        assertEq(staking.emittedAt(START - 1), 0, "one second before the start");
        assertEq(staking.emittedAt(0), 0, "timestamp zero");
    }

    function test_EmittedAtOneSecondInIsExactlyTheInitialRate() public view {
        assertEq(staking.emittedAt(START + 1), R0, "one second at the period-0 rate");
    }

    function test_EmittedAtEachYearReleasesItsExactScheduledDelta() public view {
        uint256[10] memory d = [
            uint256(11_999_999_999_999_999_998_368_000),   // years 1-4: R0 * 365 days
            11_999_999_999_999_999_998_368_000,
            11_999_999_999_999_999_998_368_000,
            11_999_999_999_999_999_998_368_000,
            12_000_000_000_000_000_006_528_000,            // year 5: R0 * 365 days + REM0 (the rollover second)
            5_999_999_999_999_999_999_184_000,             // years 6-9: R1 * 365 days
            5_999_999_999_999_999_999_184_000,
            5_999_999_999_999_999_999_184_000,
            5_999_999_999_999_999_999_184_000,
            6_000_000_000_000_000_003_264_000              // year 10: R1 * 365 days + REM1 (the closing second)
        ];
        uint256 sum;
        for (uint256 k = 1; k <= 10; ++k) {
            uint256 delta = staking.emittedAt(START + k * YEAR) - staking.emittedAt(START + (k - 1) * YEAR);
            assertEq(delta, d[k - 1], string.concat("year ", vm.toString(k)));
            sum += d[k - 1];
        }
        assertEq(sum, TOTAL, "oracle self-check: the ten years partition the budget");
        assertEq(staking.emittedAt(START + 5 * YEAR), 60_000_000e18, "five years: exactly the first period");
    }

    function test_EmittedAtTheFiveYearRolloverJumpsByTheRatePlusTheFloorRemainder() public view {
        uint256 before_ = staking.emittedAt(START + P - 1);
        uint256 at      = staking.emittedAt(START + P);
        uint256 after_  = staking.emittedAt(START + P + 1);
        assertEq(before_, 59_999_999_619_482_496_186_664_962, "P - 1: still on the period-0 line");
        assertEq(at,      60_000_000e18,                       "P: the anchor is the exact 60M");
        assertEq(after_,  60_000_000_190_258_751_902_587_519,  "P + 1: one second at the halved rate");
        assertEq(at - before_, 380_517_503_813_335_038, "the rollover second pays R0 plus the 8 160 000 wei the floor left");
        assertEq(after_ - at, R1, "the next second pays R1");
    }

    function test_EmittedAtTheTenYearCloseReadsExactlyTotalRewards() public view {
        assertEq(staking.emissionEnd() - staking.emissionStart(), T, "fixture: the programme lasts ten 365-day years");
        uint256 before_ = staking.emittedAt(START + T - 1);
        assertEq(before_, 89_999_999_809_741_248_093_332_481, "T - 1: still on the period-1 line");
        assertEq(staking.emittedAt(START + T), TOTAL, "T: exactly TOTAL_REWARDS");
        assertEq(staking.emittedAt(START + T + 1), TOTAL, "T + 1: flat");
        assertEq(TOTAL - before_, 190_258_751_906_667_519, "the closing second pays R1 plus the 4 080 000 wei the floor left");
    }

    function test_EmittedAtStaysAtTotalRewardsForeverAfterTheClose() public view {
        assertEq(staking.emittedAt(START + T + 100 * YEAR), TOTAL, "a century after the close");
        assertEq(staking.emittedAt(type(uint256).max), TOTAL, "the end of time");
    }

    function test_CurrentRewardPerSecHalvesAtFiveYearsAndStopsAtTen() public {
        assertEq(staking.currentRewardPerSec(), R0, "dt = 0");
        vm.warp(START + P - 1); assertEq(staking.currentRewardPerSec(), R0, "P - 1");
        vm.warp(START + P);     assertEq(staking.currentRewardPerSec(), R1, "P: halved");
        vm.warp(START + T - 1); assertEq(staking.currentRewardPerSec(), R1, "T - 1");
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

    function testFuzz_EmittedAtGrowsLinearlyAtThePeriodRateInsideEachPeriod(bool second, uint256 o1, uint256 o2) public view {
        o1 = bound(o1, 0, P - 1);
        o2 = bound(o2, 0, P - 1);
        if (o1 > o2) (o1, o2) = (o2, o1);
        uint256 base = START + (second ? P : 0);
        uint256 rate = second ? R1 : R0;
        assertEq(staking.emittedAt(base + o2) - staking.emittedAt(base + o1), rate * (o2 - o1));
    }

    function testFuzz_AWindowAcrossTheRolloverPaysBothRatesAndTheFloorRemainder(uint256 a, uint256 b) public view {
        a = bound(a, START, START + P - 1);
        b = bound(b, START + P, START + T - 1);
        assertEq(staking.emittedAt(b) - staking.emittedAt(a), R0 * (START + P - a) + REM0 + R1 * (b - START - P));
    }

    function testFuzz_TheLastWindowClosesAtExactlyTotalRewards(uint256 a, uint256 b) public view {
        a = bound(a, START + P, START + T - 1);
        b = bound(b, START + T, type(uint256).max);
        assertEq(staking.emittedAt(b) - staking.emittedAt(a), R1 * (START + T - a) + REM1);
    }

    /// Two producers of "the rate in force": `currentRewardPerSec` and the one-second step of `emittedAt`.
    function testFuzz_TheRateInForceIsTheOneSecondStepOfTheCurve(uint256 dt) public {
        dt = bound(dt, 0, T - 1);
        vm.warp(START + dt);
        uint256 rate = staking.currentRewardPerSec();
        assertEq(rate, dt < P ? R0 : R1, "the rate in force is the period's floored rate");
        uint256 step = staking.emittedAt(START + dt + 1) - staking.emittedAt(START + dt);
        uint256 rem  = dt + 1 == P ? REM0 : (dt + 1 == T ? REM1 : 0);
        assertEq(step, rate + rem, "one second of the curve pays the rate (and the remainder in the two rollover seconds)");
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
        uint256 expected;
        if (b < START + P)       expected = R0 * (b - a);
        else if (a >= START + P) expected = R1 * (b - a);
        else                     expected = R0 * (START + P - a) + REM0 + R1 * (b - START - P);
        assertEq(staking.totalRewardDistributed() - d0, expected);
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
        assertEq(staking.totalRewardDistributed(), 78_000_000_000_000_000_001_632_000, "TOTAL - E(1 year)");
        assertEq(staking.rewardReserve(), 11_999_999_999_999_999_998_368_000, "E(1 year) stays in the reserve");
        assertEq(_sweep(), 11_999_999_999_999_999_998_368_000, "and the sweep sends exactly that to the treasury");
    }

    function test_AnEmptyFirstPeriodLeavesExactlySixtyMillionForTheSweep() public {
        vm.prank(admin); staking.fundEmission(TOTAL);
        vm.warp(START + P); vm.roll(block.number + 2);              // five years with nobody staked
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        _normaliseAtUnlock(alice);
        _claimAtTheClose(alice);
        assertEq(staking.totalRewardDistributed(), 30_000_000e18, "the second period, exactly");
        assertEq(staking.rewardReserve(), 60_000_000e18, "the first period, exactly");
        assertEq(_sweep(), 60_000_000e18, "the sweep sends the whole empty period to the treasury");
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
        assertEq(_deliveredAfterUnlock(1), 87_041, "floor(X * 1 / 1e21)");
    }

    function test_OneWeiBelowMinWeightIsStillThrottled() public {
        assertEq(_deliveredAfterUnlock(MIN_W - 1), 87_041_095_890_410_958_904_424_958, "floor(X * (1e21 - 1) / 1e21)");
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
        vm.warp(START + 2 * YEAR); vm.roll(block.number + 2);       // ~24M scheduled against a 10M reserve
        vm.prank(admin); staking.fundEmission(80_000_000e18);       // settles the dry window first
        assertEq(staking.totalRewardDistributed(), 10_000_000e18, "the dry window paid what the reserve held");
        assertEq(staking.rewardReserve(), 80_000_000e18, "the new tranche is untouched by the past");
        _normaliseAtUnlock(alice);
        _claimAtTheClose(alice);
        assertEq(staking.totalRewardDistributed(), 76_000_000_000_000_000_003_264_000, "10M + (TOTAL - E(2 years))");
        assertEq(staking.rewardReserve(), 13_999_999_999_999_999_996_736_000, "80M - (TOTAL - E(2 years))");
        assertEq(_sweep(), 13_999_999_999_999_999_996_736_000, "what the dry window could not pay goes to the treasury");
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

    function test_EmittedAtCostsTheSameGasAnywhereInEitherPeriod() public view {
        staking.emittedAt(START + 1);                                // warm the account and its slots
        uint256 g = _calleeGasOfEmittedAt(START + 12_345);
        assertEq(_calleeGasOfEmittedAt(START + P - 1),      g, "late in period 0");
        assertEq(_calleeGasOfEmittedAt(START + P + 12_345), g, "early in period 1");
        assertEq(_calleeGasOfEmittedAt(START + T - 1),      g, "late in period 1: O(1), no loop over periods");
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
