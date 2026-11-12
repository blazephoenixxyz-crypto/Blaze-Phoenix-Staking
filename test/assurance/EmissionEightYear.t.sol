// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  The eight-year emission: a linear base plus a bonus that halves every two years.
//
//  ORACLE: the schedule as it is stated, written here in the test's own arithmetic and from
//  LITERALS, never from the contract's constants: 60M spread flat over 8 years (the base), plus
//  16M, 8M, 4M, 2M over four 2-year periods (the bonus). The oracle sums completed periods from
//  a literal table and divides; the contract shifts one series. `emittedAt` is the thing
//  measured, never the yardstick.
//
//  DERIVED DUST (every figure below is a literal the derivation produces, not a tolerance):
//    base rate   RB = floor(60M e18 / 252_288_000)  = 237_823_439_878_234_398 wei/s
//                60M e18 - RB * 252_288_000         = 197_376_000 wei   (lands at the close)
//    bonus rate  R0 = floor(16M e18 / 63_072_000)   = 253_678_335_870_116_692 wei/s
//                period remainder (16M >> p) e18 - (R0 >> p) * 63_072_000
//                                                   = 2_176_000 / 1_088_000 / 544_000 / 31_808_000
//                (each lands at the turn that closes its period)
//    so a two-year period releases 15M e18 - 49_344_000 wei of base (197_376_000 / 4) plus
//    its whole bonus, and the last one also takes the base remainder: 31M, 23M, 19M, 17M to
//    within those literals, and 90M to the wei.
//
//  DIMENSIONS x VECTORS x RANGES
//    time    every biennial turn -1 s / 0 / +1 s, every year mark, the start, the close, after it
//    weight  one wei / MIN_EMISSION_WEIGHT - 1 / at it / + 1 / the largest a wallet can hold
//    funding full (90M) / short (31M)
//    kinds   literal unit, fuzz against the independent oracle, metamorphic (shifted start,
//            split settle, permuted depositors), whole-programme walk, quote == execution
//
//  RED FIRST: written against the tree at 4e1b405 (two 5-year periods over 10 years), where
//  every test in this file fails; green from the commit that introduces the schedule above.
//  Paired mutants: [E8Y-*] in .github/scripts/mutants.py.
//  Run: forge test --match-path test/assurance/EmissionEightYear.t.sol
// =============================================================================

import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";

contract EmissionEightYearTest is Base {
    uint256 internal constant YEAR     = 365 days;
    uint256 internal constant PERIOD   = 63_072_000;                  // 2 * 365 days
    uint256 internal constant LENGTH   = 252_288_000;                 // 8 * 365 days
    uint256 internal constant ALL      = 90_000_000e18;
    uint256 internal constant BASE     = 60_000_000e18;
    uint256 internal constant RB       = 237_823_439_878_234_398;
    uint256 internal constant R0       = 253_678_335_870_116_692;
    uint256 internal constant BASE_REM = 197_376_000;
    uint256 internal constant MIN_W    = 1_000e18;
    uint256 internal constant WAD      = 1e18;
    address internal constant STRANGER = address(0x57A6E);

    uint256 internal start;
    uint256 internal end;

    function setUp() public override {
        super.setUp();
        start = staking.emissionStart();
        end   = staking.emissionEnd();
    }

    // ── the literal schedule ──────────────────────────────────────────────────────────────────
    function _bonus(uint256 p) internal pure returns (uint256) {
        if (p == 0) return 16_000_000e18;
        if (p == 1) return 8_000_000e18;
        if (p == 2) return 4_000_000e18;
        return 2_000_000e18;
    }

    function _bonusRem(uint256 p) internal pure returns (uint256) {
        if (p == 0) return 2_176_000;
        if (p == 1) return 1_088_000;
        if (p == 2) return 544_000;
        return 31_808_000;
    }

    /// What the schedule has released `t`: completed bonus periods summed from the table, the
    /// running period and the base at their floored per-second rates, 90M from the close on.
    function _oracle(uint256 t) internal view returns (uint256 e) {
        if (t <= start) return 0;
        if (t >= end) return ALL;
        uint256 dt = t - start;
        e = (BASE / LENGTH) * dt;
        uint256 p;
        while (dt >= PERIOD) { e += _bonus(p); dt -= PERIOD; ++p; }
        e += (_bonus(p) / PERIOD) * dt;
    }

    /// The exact (unfloored) line, and how far under it the per-second floors may leave the curve.
    function _nominal(uint256 t) internal view returns (uint256 n, uint256 slack) {
        if (t <= start) return (0, 0);
        if (t >= end) return (ALL, 0);
        uint256 dt = t - start;
        n = BASE * dt / LENGTH;
        uint256 p;
        uint256 d = dt;
        while (d >= PERIOD) { n += _bonus(p); d -= PERIOD; ++p; }
        n += _bonus(p) * d / PERIOD;
        slack = dt + d + 2;      // < 1 wei a second on the base, < 1 wei a second on the bonus, two floors here
    }

    function _poke(BlazePhoenixStaking s) internal { vm.prank(STRANGER); s.claimRewards(); }

    function _twin() internal returns (BlazePhoenixStaking s) {
        vm.prank(admin);
        s = new BlazePhoenixStaking(address(token), treasury);
        address[5] memory who = [admin, alice, bob, carol, keeper];
        for (uint256 i; i < who.length; ++i) { vm.prank(who[i]); token.approve(address(s), type(uint256).max); }
    }

    // ══ 1. constants ══════════════════════════════════════════════════════════════════════════
    function test_EmissionConstants_AreEightYearsFourBiennialPeriodsNinetyMillion() public view {
        assertEq(staking.EMISSION_LENGTH(), 8 * 365 days, "the programme is not eight years");
        assertEq(staking.HALVING_PERIOD(), 2 * 365 days, "the bonus period is not two years");
        assertEq(staking.EMISSION_PERIODS(), 4, "not four bonus periods");
        assertEq(staking.TOTAL_REWARDS(), ALL, "the budget is not 90M");
        assertEq(end - start, LENGTH, "the deployed clock is not eight years");
        assertEq(staking.INITIAL_REWARD_PER_SEC(), RB + R0, "the opening rate is not base + bonus");
        // the literals above are the stated schedule, re-derived here
        assertEq(LENGTH, 4 * PERIOD, "four periods do not fill the programme");
        assertEq(RB, BASE / LENGTH, "base rate literal");
        assertEq(R0, _bonus(0) / PERIOD, "bonus rate literal");
        assertEq(BASE - RB * LENGTH, BASE_REM, "base remainder literal");
        for (uint256 p; p < 4; ++p) {
            assertEq(_bonus(p) - (R0 >> p) * PERIOD, _bonusRem(p), "bonus remainder literal");
            assertEq(_bonus(p) / PERIOD, R0 >> p, "shifting the rate is not flooring the period");
        }
        assertEq(BASE + _bonus(0) + _bonus(1) + _bonus(2) + _bonus(3), ALL, "base + bonus is not 90M");
    }

    // ══ 2. the curve, by literal ══════════════════════════════════════════════════════════════
    function test_EmittedAt_IsExactAtEveryBiennialTurnAndOneSecondEitherSide() public view {
        uint256[3][5] memory want = [
            [uint256(0), 0, 491_501_775_748_351_090],
            [uint256(30_999_999_508_498_224_200_128_910), 30_999_999_999_999_999_950_656_000, 31_000_000_364_662_607_763_948_744],
            [uint256(53_999_999_635_337_392_086_931_256), 53_999_999_999_999_999_901_312_000, 54_000_000_301_243_023_747_075_571],
            [uint256(72_999_999_698_756_976_005_660_429), 72_999_999_999_999_999_851_968_000, 73_000_000_269_533_231_713_966_984],
            [uint256(89_999_999_730_466_767_908_817_016), 90_000_000_000_000_000_000_000_000, 90_000_000_000_000_000_000_000_000]
        ];
        for (uint256 k; k < 5; ++k) {
            uint256 turn = start + k * PERIOD;
            assertEq(staking.emittedAt(turn - 1), want[k][0], "one second before a turn");
            assertEq(staking.emittedAt(turn),     want[k][1], "at a turn");
            assertEq(staking.emittedAt(turn + 1), want[k][2], "one second after a turn");
        }
        assertEq(staking.emittedAt(0), 0, "before time");
        assertEq(staking.emittedAt(type(uint256).max), ALL, "the far future");
    }

    function test_EmittedAt_YearMarksAreTheLiteralTable() public view {
        uint256[8] memory want = [
            uint256(15_499_999_999_999_999_974_240_000),
            30_999_999_999_999_999_950_656_000,
            42_499_999_999_999_999_925_440_000,
            53_999_999_999_999_999_901_312_000,
            63_499_999_999_999_999_876_368_000,
            72_999_999_999_999_999_851_968_000,
            81_499_999_999_999_999_811_392_000,
            90_000_000_000_000_000_000_000_000
        ];
        // 15.5M, 11.5M, 9.5M, 8.5M a year, two years each
        uint256[8] memory nominal = [
            uint256(15_500_000e18), 31_000_000e18, 42_500_000e18, 54_000_000e18,
            63_500_000e18, 73_000_000e18, 81_500_000e18, 90_000_000e18
        ];
        for (uint256 y = 1; y <= 8; ++y) {
            uint256 got = staking.emittedAt(start + y * YEAR);
            assertEq(got, want[y - 1], "a year mark off the literal table");
            assertLe(got, nominal[y - 1], "a year mark above the stated schedule");
            assertLe(nominal[y - 1] - got, BASE_REM, "a year mark under the schedule by more than the base remainder");
        }
    }

    function test_BiennialTotals_Are31_23_19_17Million_AndSumToNinetyMillionToTheWei() public view {
        uint256[4] memory want = [
            uint256(30_999_999_999_999_999_950_656_000),
            22_999_999_999_999_999_950_656_000,
            18_999_999_999_999_999_950_656_000,
            17_000_000_000_000_000_148_032_000
        ];
        uint256 sum;
        for (uint256 p; p < 4; ++p) {
            uint256 d = staking.emittedAt(start + (p + 1) * PERIOD) - staking.emittedAt(start + p * PERIOD);
            assertEq(d, want[p], "a two-year period off its literal");
            sum += d;
        }
        // each of the first three is 15M of base less a quarter of the base remainder, plus its whole bonus;
        // the last one takes the three quarters back
        assertEq(want[0], 31_000_000e18 - BASE_REM / 4, "first period");
        assertEq(want[1], 23_000_000e18 - BASE_REM / 4, "second period");
        assertEq(want[2], 19_000_000e18 - BASE_REM / 4, "third period");
        assertEq(want[3], 17_000_000e18 + 3 * (BASE_REM / 4), "last period");
        assertEq(sum, ALL, "the four periods do not sum to 90M to the wei");
    }

    function test_TheClose_FoldsEveryFlooredRemainder_AndLandsOnTotalRewardsExactly() public view {
        assertEq(staking.emittedAt(end), staking.TOTAL_REWARDS(), "the close is not the budget");
        assertEq(staking.emittedAt(end), ALL, "the close is not 90M to the wei");
        assertEq(staking.emittedAt(end + 1), ALL, "one second after the close");
        // the last second pays its rate plus the two remainders the floors left: base and last bonus period
        assertEq(ALL - staking.emittedAt(end - 1), RB + (R0 >> 3) + BASE_REM + _bonusRem(3), "the closing second");
        assertEq(BASE_REM + _bonusRem(3), 229_184_000, "closing dust literal");
        // and each earlier turn folds exactly its own period's bonus remainder
        for (uint256 k = 1; k < 4; ++k) {
            uint256 turn = start + k * PERIOD;
            assertEq(staking.emittedAt(turn) - staking.emittedAt(turn - 1), RB + (R0 >> (k - 1)) + _bonusRem(k - 1), "a turn's second");
        }
    }

    // ══ 3. the shape: the bonus halves, the base does not, the total never halves ═════════════
    function test_TheBonusHalvesExactlyEveryTwoYears_AndTheBaseIsConstant() public view {
        uint256[4] memory perSec;
        for (uint256 p; p < 4; ++p) {
            uint256 mid = start + p * PERIOD + PERIOD / 2;
            perSec[p] = staking.emittedAt(mid + 1) - staking.emittedAt(mid);
            assertEq(perSec[p], RB + (R0 >> p), "a period's per-second release");
            assertEq(perSec[p] - (R0 >> p), RB, "the base moved between periods");
        }
        for (uint256 p; p < 3; ++p) {
            assertEq((perSec[p] - RB) / 2, perSec[p + 1] - RB, "the bonus did not halve");
            assertEq(perSec[p] - perSec[p + 1], (R0 >> p) - (R0 >> (p + 1)), "the step between periods is not the bonus alone");
        }
        // 8M, 4M, 2M, 1M a year of bonus and 7.5M a year of base, to within one wei a second
        uint256[4] memory bonusYear = [uint256(8_000_000e18), 4_000_000e18, 2_000_000e18, 1_000_000e18];
        for (uint256 p; p < 4; ++p) {
            uint256 y = (perSec[p] - RB) * YEAR;
            assertLe(y, bonusYear[p], "bonus a year above the statement");
            assertLt(bonusYear[p] - y, YEAR, "bonus a year under the statement by more than the floor");
        }
        assertLe(RB * YEAR, 7_500_000e18, "base a year above the statement");
        assertLt(7_500_000e18 - RB * YEAR, YEAR, "base a year under the statement by more than the floor");
    }

    function test_TheTotalRateNeverHalves_TheFirstPeriodIs31Over17OfTheLast() public view {
        uint256 d0 = staking.emittedAt(start + PERIOD);
        uint256 d3 = staking.emittedAt(end) - staking.emittedAt(start + 3 * PERIOD);
        // 17 * first = 31 * last, less the literal dust of section 2: 17 * 49_344_000 + 31 * 148_032_000
        assertEq(17 * d0 + 5_427_840_000, 31 * d3, "first : last is not 31 : 17");
        assertLt(d0, 2 * d3, "the first period is twice the last or more");
        for (uint256 p; p < 3; ++p) {
            uint256 a = staking.emittedAt(start + (p + 1) * PERIOD) - staking.emittedAt(start + p * PERIOD);
            uint256 b = staking.emittedAt(start + (p + 2) * PERIOD) - staking.emittedAt(start + (p + 1) * PERIOD);
            assertGt(a, b, "a later period released more");
            assertLt(a, 2 * b, "the total halved between two periods");
        }
    }

    function test_RateView_IsBasePlusBonusAtEveryTurn_AndZeroAtTheClose() public {
        assertEq(staking.currentRewardPerSec(), RB + R0, "the start");
        assertEq(staking.currentRewardPerSec(), staking.INITIAL_REWARD_PER_SEC(), "the opening rate constant");
        for (uint256 k = 1; k < 4; ++k) {
            vm.warp(start + k * PERIOD - 1);
            assertEq(staking.currentRewardPerSec(), RB + (R0 >> (k - 1)), "the last second of a period");
            vm.warp(start + k * PERIOD);
            assertEq(staking.currentRewardPerSec(), RB + (R0 >> k), "the turn");
        }
        vm.warp(end - 1);
        assertEq(staking.currentRewardPerSec(), RB + (R0 >> 3), "the last second of the programme");
        vm.warp(end);
        assertEq(staking.currentRewardPerSec(), 0, "the close");
        vm.warp(end + 365 days);
        assertEq(staking.currentRewardPerSec(), 0, "after the close");
    }

    // ══ 4. the curve, fuzzed against the independent oracle ═══════════════════════════════════
    function testFuzz_EmittedAt_EqualsTheIndependentOracle(uint256 t) public view {
        t = bound(t, start - 10, end + 10);
        uint256 got = staking.emittedAt(t);
        assertEq(got, _oracle(t), "the curve left the stated schedule");
        (uint256 n, uint256 slack) = _nominal(t);
        assertLe(got, n, "above the exact line");
        if (slack == 0) assertEq(got, n, "off the line where no floor applies");
        else assertLt(n - got, slack, "under the exact line by more than the floors");
        assertLe(got, ALL, "above 90M");
    }

    function testFuzz_EmittedAt_RisesEverySecondOfTheProgrammeAndNeverFallsAtTheClose(uint256 a, uint256 b) public view {
        a = bound(a, start - 10, end + 10);
        b = bound(b, a, end + 10);
        uint256 ea = staking.emittedAt(a);
        uint256 eb = staking.emittedAt(b);
        assertLe(ea, eb, "the curve went down");
        if (a >= start && a < b && a < end) assertLt(ea, eb, "a second of the programme released nothing");
    }

    function testFuzz_OneSecondReleasesItsRate_PlusTheRemainderOnlyAtATurn(uint256 dt) public view {
        dt = bound(dt, 0, LENGTH - 1);
        uint256 p = dt / PERIOD;
        uint256 got = staking.emittedAt(start + dt + 1) - staking.emittedAt(start + dt);
        uint256 want = RB + (R0 >> p);
        if ((dt + 1) % PERIOD == 0) want += _bonusRem(p);          // the second that closes a period
        if (dt + 1 == LENGTH) want += BASE_REM;                    // the second that closes the programme
        assertEq(got, want, "a second released something else than its rate and its turn's remainder");
    }

    // ══ 5. metamorphic ════════════════════════════════════════════════════════════════════════
    /// Deploying later moves the curve, and nothing else: it is a function of (t - start) alone.
    function testFuzz_ShiftingTheStartShiftsTheCurveAndNothingElse(uint256 shift, uint256 dt) public {
        shift = bound(shift, 1, 20 * 365 days);
        dt = bound(dt, 0, LENGTH + 10);
        vm.warp(start + shift);
        BlazePhoenixStaking later = _twin();
        assertEq(later.emissionStart(), start + shift, "fixture: the twin did not start later");
        assertEq(later.emittedAt(start + shift + dt), staking.emittedAt(start + dt), "the curve depends on more than the time since the start");
        assertEq(later.emissionEnd() - later.emissionStart(), LENGTH, "the twin's programme has another length");
    }

    /// One settle over a window, or k settles over the same window: the schedule released is the
    /// same to the wei (the curve telescopes), and what a holder may claim differs only by the
    /// accumulator's floor, once per settle, always against the holder (I7).
    function testFuzz_SplittingAWindowIntoKSettles_ReleasesTheSameAndPaysNoMore(uint256 k, uint256 from, uint256 len, uint256 stake) public {
        k     = bound(k, 2, 24);
        from  = bound(from, 0, LENGTH - 91 days);                // a 90-day lock still fits
        len   = bound(len, k, 3 * 365 days);                     // long enough to cross a turn, or the close
        stake = bound(stake, 1_000e18, 30_000_000e18);           // weight >= MIN_EMISSION_WEIGHT: no damping
        BlazePhoenixStaking once = staking;
        BlazePhoenixStaking many = _twin();
        vm.startPrank(admin);
        once.fundEmission(ALL);
        many.fundEmission(ALL);
        vm.stopPrank();
        vm.warp(start + from);
        uint256 lockDays = once.maxLockDaysAvailable();         // the longest lock on offer: 90..2555 days
        vm.startPrank(alice);
        once.deposit(stake, lockDays);
        many.deposit(stake, lockDays);
        vm.stopPrank();
        uint256 weight = once.totalBoostedEffective();
        assertGe(weight, MIN_W, "fixture: the damped regime");
        uint256 t0 = vm.getBlockTimestamp();
        for (uint256 i = 1; i < k; ++i) {
            vm.warp(t0 + len * i / k);
            vm.roll(vm.getBlockNumber() + 1);
            _poke(many);
        }
        vm.warp(t0 + len);
        vm.roll(vm.getBlockNumber() + 20);
        _poke(once);
        _poke(many);
        uint256 window = _oracle(t0 + len) - _oracle(t0);
        // The single settle prices the whole window at the weight it opened with, lapsed lock or not.
        assertEq(once.accRewardPerShare(), window * WAD / weight, "one settle did not release the window");
        assertEq(once.totalRewardDistributed() + once.rewardReserve(), ALL, "one settle broke the budget");
        assertEq(many.totalRewardDistributed() + many.rewardReserve(), ALL, "k settles broke the budget");
        assertLe(once.totalRewardDistributed(), window, "one settle left more distributed than the window");
        assertLe(many.totalRewardDistributed(), window, "k settles left more distributed than the window");
        // Both sides are compared to the wei while the lock outlives the window: once it lapses, the
        // settle that normalises it hands the stale-weight excess back to the reserve and re-prices
        // the weight, and the two books stop being twins.
        if (len <= lockDays * 1 days) {
            assertEq(once.totalRewardDistributed(), window, "one settle did not keep the window distributed");
            assertEq(many.totalRewardDistributed(), window, "k settles released another amount than one");
            uint256 p1 = once.pendingRewards(alice);
            uint256 pk = many.pendingRewards(alice);
            assertLe(pk, p1, "splitting the window paid more");
            assertLe(p1 - pk, k * (weight / WAD + 1), "splitting the window lost more than one floor a settle");
        }
    }

    /// Three holders entering in one block: the order they entered in changes nobody's reward.
    function testFuzz_PermutingTheDepositOrder_ChangesNobodysReward(uint256 sa, uint256 sb, uint256 sc, uint256 len) public {
        sa  = bound(sa, 1e18, 30_000_000e18);
        sb  = bound(sb, 1e18, 30_000_000e18);
        sc  = bound(sc, 1e18, 30_000_000e18);
        len = bound(len, 1 days, 2 * PERIOD + 30 days);          // up to past the second turn
        BlazePhoenixStaking fwd = staking;
        BlazePhoenixStaking rev = _twin();
        vm.startPrank(admin);
        fwd.fundEmission(ALL);
        rev.fundEmission(ALL);
        vm.stopPrank();
        vm.warp(start + PERIOD - 15 days);
        vm.prank(alice); fwd.deposit(sa, 1825);
        vm.prank(bob);   fwd.deposit(sb, 730);
        vm.prank(carol); fwd.deposit(sc, 90);
        vm.prank(carol); rev.deposit(sc, 90);
        vm.prank(bob);   rev.deposit(sb, 730);
        vm.prank(alice); rev.deposit(sa, 1825);
        assertEq(fwd.totalBoostedEffective(), rev.totalBoostedEffective(), "fixture: the two books weigh differently");
        vm.warp(vm.getBlockTimestamp() + len);
        vm.roll(vm.getBlockNumber() + 20);
        assertEq(fwd.pendingRewards(alice), rev.pendingRewards(alice), "order changed the first holder's reward");
        assertEq(fwd.pendingRewards(bob),   rev.pendingRewards(bob),   "order changed the second holder's reward");
        assertEq(fwd.pendingRewards(carol), rev.pendingRewards(carol), "order changed the third holder's reward");
        assertGt(fwd.pendingRewards(alice), 0, "fixture: nothing accrued");
    }

    // ══ 6. the weight vector, on a window that straddles the first turn ═══════════════════════
    /// Opens the book with (stakeA at 2.00x) + (stakeB at 1.10x), runs 30 days across the first
    /// turn and returns (weight, released, scheduled).
    function _straddle(uint256 stakeA, uint256 stakeB) internal returns (uint256 weight, uint256 released, uint256 window) {
        vm.prank(admin);
        staking.fundEmission(ALL);
        uint256 a = start + PERIOD - 15 days;
        vm.warp(a);
        if (stakeA != 0) { vm.prank(alice); staking.deposit(stakeA, 1825); }
        if (stakeB != 0) { vm.prank(bob);   staking.deposit(stakeB, 365); }
        weight = staking.totalBoostedEffective();
        uint256 reserve = staking.rewardReserve();
        assertEq(staking.totalRewardDistributed(), 0, "fixture: something was released before the window");
        vm.warp(a + 30 days);
        vm.roll(vm.getBlockNumber() + 20);
        _poke(staking);
        released = staking.totalRewardDistributed();
        window = _oracle(a + 30 days) - _oracle(a);
        assertEq(reserve - staking.rewardReserve(), released, "the reserve did not fall by what was released");
        assertGt(window, 30 days * (RB + (R0 >> 1)), "fixture: the window is not across the turn");
        assertLt(window, 30 days * (RB + R0), "fixture: the window is not across the turn");
    }

    function test_WeightOneWei_IsDampedByWeightOverTheMark_TheRestStaysInReserve() public {
        (uint256 w, uint256 released, uint256 window) = _straddle(0, 1);
        assertEq(w, 1, "fixture: weight is not one wei");
        assertEq(released, window / MIN_W, "dust weight was not damped by weight / MIN_EMISSION_WEIGHT");
        assertEq(released, 1_109, "one wei of weight over these 30 days");
    }

    function test_WeightOneWeiUnderTheMark_IsDamped() public {
        (uint256 w, uint256 released, uint256 window) = _straddle(500e18 - 1, 1);
        assertEq(w, MIN_W - 1, "fixture: weight is not MIN_EMISSION_WEIGHT - 1");
        assertEq(released, window * (MIN_W - 1) / MIN_W, "one wei under the mark was not damped");
        assertLt(released, window, "one wei under the mark released the whole window");
    }

    function test_WeightAtTheMark_ReleasesTheWholeWindow() public {
        (uint256 w, uint256 released, uint256 window) = _straddle(500e18, 0);
        assertEq(w, MIN_W, "fixture: weight is not MIN_EMISSION_WEIGHT");
        assertEq(released, window, "the mark itself was damped");
    }

    function test_WeightOneWeiOverTheMark_ReleasesTheWholeWindow() public {
        (uint256 w, uint256 released, uint256 window) = _straddle(500e18, 1);
        assertEq(w, MIN_W + 1, "fixture: weight is not MIN_EMISSION_WEIGHT + 1");
        assertEq(released, window, "one wei over the mark was damped");
    }

    function test_TheLargestWalletWeight_ReleasesTheWholeWindow_AndNotAWeiMore() public {
        (uint256 w, uint256 released, uint256 window) = _straddle(30_000_000e18, 30_000_000e18);
        assertEq(w, 93_000_000e18, "fixture: two full wallets at 2.00x and 1.10x");
        assertEq(released, window, "a large book released something else than the schedule");
    }

    // ══ 7. the whole programme ════════════════════════════════════════════════════════════════
    /// Funded in full and staked from the first second: at every turn, one second either side
    /// and every year mark the book has released exactly what the schedule says, the reserve
    /// holds exactly the rest, and the close leaves nothing to sweep.
    function test_FullyFundedProgramme_ReleasesTheScheduleAtEveryTurn_AndNinetyMillionToTheWei() public {
        vm.prank(admin);
        staking.fundEmission(ALL);
        vm.prank(alice);
        staking.deposit(30_000_000e18, 2555);
        for (uint256 h = 1; h <= 16; ++h) {                      // every half year: year marks and turns
            uint256 mark = start + h * (YEAR / 2);
            for (uint256 o; o < 3; ++o) {
                uint256 t = mark + o - 1;
                vm.warp(t);
                vm.roll(vm.getBlockNumber() + 20);
                _poke(staking);
                assertEq(staking.totalRewardDistributed(), _oracle(t), "released is not the schedule");
                assertEq(staking.rewardReserve(), ALL - _oracle(t), "the reserve is not the unreleased schedule");
                assertEq(staking.totalRewardDistributed(), staking.emittedAt(t), "released is not the curve the contract publishes");
            }
        }
        assertEq(staking.totalRewardDistributed(), ALL, "the programme did not release 90M to the wei");
        assertEq(staking.rewardReserve(), 0, "the schedule left a tail in the reserve");
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAmount.selector);
        staking.sweepUndistributedEmission();
    }

    /// Funded with the first period only: the book pays what it holds, stops there, and no later
    /// settle reverts or releases a wei the reserve does not have.
    function test_ShortFundedProgramme_StopsAtTheReserve_AndKeepsSettling() public {
        uint256 funded = 31_000_000e18;
        vm.prank(admin);
        staking.fundEmission(funded);
        vm.prank(alice);
        staking.deposit(30_000_000e18, 2555);
        for (uint256 h = 1; h <= 17; ++h) {
            uint256 t = start + h * (YEAR / 2);
            vm.warp(t);
            vm.roll(vm.getBlockNumber() + 20);
            _poke(staking);
            uint256 want = _oracle(t) < funded ? _oracle(t) : funded;
            assertEq(staking.totalRewardDistributed(), want, "released is not min(schedule, funded)");
            assertEq(staking.rewardReserve(), funded - want, "the reserve is not what is left of the funding");
        }
        assertEq(staking.totalRewardDistributed(), funded, "a short-funded book released something else than its funding");
    }

    /// A window that ran over an empty reserve is gone. Funding again pays from the second it
    /// lands, never the backlog: here the dry stretch runs across the first turn, and
    /// `fundEmission` alone has to slide the clock.
    function test_EmptyReserve_TheClockSlides_ARefillPaysNoBacklog() public {
        uint256 first = 1_000_000e18;                      // lasts ~23.5 days at 15.5M a year
        vm.prank(admin);
        staking.fundEmission(first);
        vm.prank(alice);
        staking.deposit(30_000_000e18, 2555);
        vm.warp(start + PERIOD - 30 days);
        vm.roll(vm.getBlockNumber() + 20);
        _poke(staking);
        assertEq(staking.totalRewardDistributed(), first, "fixture: the first funding was not exhausted");
        assertEq(staking.rewardReserve(), 0, "fixture: the reserve is not empty");
        uint256 refill = start + PERIOD + 30 days;
        vm.warp(refill);
        vm.roll(vm.getBlockNumber() + 20);
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        assertEq(staking.totalRewardDistributed(), first, "funding released something by itself");
        vm.warp(refill + 1 days);
        vm.roll(vm.getBlockNumber() + 20);
        _poke(staking);
        uint256 day = _oracle(refill + 1 days) - _oracle(refill);
        assertEq(day, 1 days * (RB + (R0 >> 1)), "fixture: the day is not in the second period");
        assertEq(staking.totalRewardDistributed(), first + day, "the refill paid the dry stretch, not just its own day");
        assertEq(staking.rewardReserve(), 2_000_000e18 - day, "the reserve did not fall by one day of schedule");
    }

    /// The quote is the payment at every turn, one second either side: turns one to three fall
    /// inside the seven-year lock, the close after it has lapsed.
    function testFuzz_QuoteEqualsExecution_AtEveryTurnOneSecondEitherSide(uint256 k, uint256 o, uint256 stake) public {
        k     = bound(k, 1, 4);
        o     = bound(o, 0, 2);
        stake = bound(stake, 1e18, 30_000_000e18);
        vm.prank(admin);
        staking.fundEmission(ALL);
        vm.prank(alice);
        staking.deposit(stake, 2555);
        vm.prank(bob);
        staking.deposit(5_000e18, 90);
        vm.warp(start + k * PERIOD + o - 1);
        vm.roll(vm.getBlockNumber() + 20);
        uint256 quote = staking.pendingRewards(alice);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards();
        assertGt(quote, 0, "fixture: nothing accrued");
        assertEq(token.balanceOf(alice) - before, quote, "the quote was not the payment");
    }

    /// The published rate is what one second releases, in each of the four periods.
    function test_RateViewIsWhatOneSecondReleases_InEachPeriod() public {
        vm.prank(admin);
        staking.fundEmission(ALL);
        vm.prank(alice);
        staking.deposit(30_000_000e18, 2555);
        for (uint256 p; p < 4; ++p) {
            vm.warp(start + p * PERIOD + PERIOD / 3);
            vm.roll(vm.getBlockNumber() + 20);
            _poke(staking);
            uint256 before = staking.totalRewardDistributed();
            uint256 rate = staking.currentRewardPerSec();
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.roll(vm.getBlockNumber() + 1);
            _poke(staking);
            assertEq(staking.totalRewardDistributed() - before, rate, "one second released another amount than the published rate");
            assertEq(rate, RB + (R0 >> p), "the published rate is not base + bonus");
        }
    }

    /// Eight years against a seven-year lock cap: the countdown starts to bite one year in.
    function test_LockCountdown_StartsToBiteOneYearIntoTheEightYearProgramme() public {
        assertEq(staking.maxLockDaysAvailable(), 2555, "the start");
        vm.warp(start + 365 days);
        assertEq(staking.maxLockDaysAvailable(), 2555, "seven years left: the cap still fits");
        vm.prank(alice);
        staking.deposit(1e18, 2555);
        vm.warp(start + 365 days + 1);
        assertEq(staking.maxLockDaysAvailable(), 2554, "one second later the countdown bites");
        vm.prank(bob);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
        staking.deposit(1e18, 2555);
        vm.prank(bob);
        staking.deposit(1e18, 2554);
    }
}
