// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  METAMORPHIC RELATIONS AND CANONICAL ORACLES over the staking's three curves
//  (boost, interest rate, emission) and its reward channel.
//
//  A metamorphic relation is a second judge: instead of "f(x) == literal" it
//  asks how the output must MOVE when the input moves, which an oracle computed
//  from the same formula cannot fake. A canonical oracle is the specification
//  written independently of the code (the real-valued curve, the geometric
//  series), compared with a derived tolerance. Method of bp-dex
//  test/CoreMetamorphicRelations.t.sol and test/regime/CanonicalOracles.t.sol.
//
//    MR-B1  boost is monotone non-decreasing in lockDays and clamps at MAX_LOCK_DAYS
//    MR-B2  one day more moves the boost by at most 13 bps            [derived below]
//    CO-B   boost == floor of the real curve 1 + 0.075y + 0.025y^2, within 2 bps
//    MR-R1  the interest rate is monotone in utilisation and clamps at 100 %
//    MR-R2  the rate is continuous at the kink and Lipschitz with the steep slope
//    MR-E1  cumulative emission is monotone, never exceeds TOTAL_REWARDS
//    MR-E2  inside one 2-year period the emission is exactly linear at the
//           base rate plus the bonus rate halved p times, RB + (RX >> p)
//    CO-E   at every period anchor the emission is the linear base (60M over
//           8 years, less its per-second floor) plus the geometric bonus series
//           S * (1 - 2^-k), S = 32M (0, 16M, 24M, 28M, 30M); the close is 90M to
//           the wei; anywhere, the closed form sits above the sum of the floored
//           rates by exactly the bonus floor residues of the completed periods
//    MR-D1  the reward channel is linear: twice the stake (same lock, same
//           block) earns twice the reward, within 2 wei             [derived below]
//    MR-D2  the reward channel is additive: one deposit of a + b and two
//           deposits a, b in the same block earn the same reward, exactly
//
//  forge test --match-contract MetamorphicRelations -vv
// =============================================================================

import {Base} from "./BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract MetamorphicRelationsTest is Base {
    uint256 constant WAD = 1e18;
    uint256 constant MAXD = 2555;
    uint256 constant YEAR2 = 365 * 365;

    // ── boost ────────────────────────────────────────────────────────────────

    function testFuzz_BoostIsMonotoneInLockDays(uint256 a, uint256 b) public view {
        a = bound(a, 0, 4000);
        b = bound(b, a, 4000);
        assertLe(staking.boostByDays(a), staking.boostByDays(b), "MR-B1: a longer lock never pays less");
    }

    function testFuzz_BoostClampsAtTheMaximumLock(uint256 d) public view {
        d = bound(d, MAXD, type(uint64).max);
        assertEq(staking.boostByDays(d), staking.boostByDays(MAXD), "MR-B1: past MAX_LOCK_DAYS the boost is flat");
    }

    /// MR-B2. boost(d) = 10000 + floor(750 d / 365) + floor(250 d^2 / 365^2). One day moves the
    /// linear real term by 750/365 < 2.06 and the quadratic one by 250 (2d + 1) / 365^2
    /// <= 250 * 5109 / 133225 < 9.59 for d < 2555. The floor of a real that moves by r moves by at
    /// most ceil(r): 3 + 10 = 13.
    function testFuzz_OneDayMovesTheBoostByAtMost13Bps(uint256 d) public view {
        d = bound(d, 0, MAXD - 1);
        uint256 lo = staking.boostByDays(d);
        uint256 hi = staking.boostByDays(d + 1);
        assertGe(hi, lo, "MR-B1");
        assertLe(hi - lo, 13, "MR-B2: a one-day step larger than the derived bound");
    }

    /// CO-B. The specification is the real curve 10000 * (1 + 0.075 y + 0.025 y^2), y = d / 365.
    /// Scaled by 365^2: R = 10000 * 365^2 + 750 * 365 d + 250 d^2. Two floors each lose < 1,
    /// so boost * 365^2 <= R < (boost + 2) * 365^2.
    function testFuzz_BoostIsTheFlooredRealCurve(uint256 d) public view {
        d = bound(d, 1, MAXD);
        uint256 b = staking.boostByDays(d);
        uint256 r = 10_000 * YEAR2 + 750 * 365 * d + 250 * d * d;
        assertLe(b * YEAR2, r, "CO-B: the boost is above the specified curve");
        assertLt(r, (b + 2) * YEAR2, "CO-B: the boost is 2 bps or more below the specified curve");
    }

    /// CO-B anchors: at whole years both floors are exact, so the curve is met to the bp.
    function test_BoostAtWholeYearsIsTheCurveExactly() public view {
        for (uint256 y = 1; y <= 7; y++) {
            assertEq(staking.boostByDays(365 * y), 10_000 + 750 * y + 250 * y * y, "CO-B: whole-year anchor");
        }
        assertEq(staking.boostByDays(0), 10_000, "no lock is 1.00x");
    }

    // ── interest rate ────────────────────────────────────────────────────────

    function testFuzz_RateIsMonotoneInUtilisation(uint256 u1, uint256 u2) public view {
        u1 = bound(u1, 0, 2 * WAD);
        u2 = bound(u2, u1, 2 * WAD);
        assertLe(staking.simulateRate(u1), staking.simulateRate(u2), "MR-R1: more utilisation never costs less");
    }

    function testFuzz_RateClampsAtFullUtilisation(uint256 u) public view {
        u = bound(u, WAD, type(uint128).max);
        assertEq(staking.simulateRate(u), staking.simulateRate(WAD), "MR-R1: utilisation is clamped at 100 %");
    }

    /// MR-R2. Both pieces are floor(u * slope / WAD) plus a constant; the steeper slope is 72500
    /// bps per WAD. A move of delta moves the real value by at most delta * 72500 / WAD, the floor
    /// by at most one more, and the two pieces meet at the kink (100 + 0.8 * 500 = 500 = RK).
    function testFuzz_RateIsLipschitzWithTheSteepSlope(uint256 u, uint256 delta) public view {
        u = bound(u, 0, WAD);
        delta = bound(delta, 0, WAD - u);
        uint256 lo = staking.simulateRate(u);
        uint256 hi = staking.simulateRate(u + delta);
        assertLe(hi - lo, (delta * 72_500) / WAD + 1, "MR-R2: the rate jumped");
    }

    function test_RateEndpointsAndKink() public view {
        assertEq(staking.simulateRate(0), 100, "1 % at zero utilisation");
        assertEq(staking.simulateRate(0.8e18), 500, "5 % at the kink, from the left piece");
        assertEq(staking.simulateRate(0.8e18 + 1), 500, "5 % just past the kink, from the right piece");
        assertEq(staking.simulateRate(WAD), 15_000, "150 % at full utilisation");
    }

    // ── emission ─────────────────────────────────────────────────────────────

    function testFuzz_EmissionIsMonotoneAndCapped(uint256 x, uint256 y) public view {
        uint256 s = staking.emissionStart();
        uint256 e = staking.emissionEnd();
        x = bound(x, s - 1000, e + 1000);
        y = bound(y, x, e + 1000);
        uint256 ex = staking.emittedAt(x);
        uint256 ey = staking.emittedAt(y);
        assertLe(ex, ey, "MR-E1: cumulative emission went down");
        assertLe(ey, staking.TOTAL_REWARDS(), "MR-E1: emission above the hard cap");
    }

    // The emission specification, pinned by literal (never read back from the contract):
    // a linear base of 60M over 8 years plus a bonus series S = 32M halved every 2 years.
    uint256 constant E_PERIOD = 63_072_000;                    // 2 * 365 days
    uint256 constant E_LENGTH = 252_288_000;                   // 4 periods, 2920 days
    uint256 constant E_BASE   = 60_000_000e18;
    uint256 constant E_SERIES = 32_000_000e18;
    uint256 constant E_RB     = 237_823_439_878_234_398;       // floor(60M / E_LENGTH)
    uint256 constant E_RX     = 253_678_335_870_116_692;       // floor(16M / E_PERIOD)

    /// MR-E2. Inside period p the closed form is RB * dt + const + (RX >> p) * (dt - p * P), so one
    /// second more adds exactly RB + (RX >> p): the base rate never halves, only the bonus does.
    function testFuzz_EmissionInsideAPeriodIsLinear(uint256 x, uint256 delta) public view {
        uint256 s = staking.emissionStart();
        x = bound(x, s, staking.emissionEnd() - 1);
        uint256 p = (x - s) / E_PERIOD;
        uint256 periodEnd = s + (p + 1) * E_PERIOD;        // first second of the next period
        delta = bound(delta, 0, periodEnd - 1 - x);
        uint256 r = E_RB + (E_RX >> p);
        assertEq(staking.emittedAt(x + delta) - staking.emittedAt(x), r * delta, "MR-E2: not linear at RB + (RX >> p)");
    }

    /// CO-E anchors. Both halves of the curve are pinned by literal, not read back.
    /// Bonus: S = 3.2e25 = 2^29 * 5^24, so S >> k == S / 2^k exactly for k <= 4 and the series
    /// S * (1 - 2^-k) is met to the wei: 0, 16M, 24M, 28M, 30M.
    /// Base: RB = floor(60M / L) loses 60M - RB * L = 197 376 000 wei over the whole length L, and
    /// L = 4P, so each period anchor sits 49 344 000 wei per completed period below the nominal
    /// 15M * k. The close returns the whole 60M, so the last anchor is the budget, 90M, exactly.
    /// Anchors: 31M, 54M, 73M less k * 49 344 000 wei (the table of the 8-year curve), then 90M.
    function test_EmissionAtEveryPeriodAnchorIsLinearBasePlusGeometricBonus() public view {
        uint256 s = staking.emissionStart();
        assertEq(E_SERIES % (2 ** 4), 0, "precondition of the exactness: S divisible by 2^4");
        assertEq(E_BASE - E_RB * E_LENGTH, 197_376_000, "precondition: the base floor residue over 8 years");
        assertEq(E_BASE / 4 - E_RB * E_PERIOD, 49_344_000, "precondition: the base floor residue per period");
        uint256[5] memory anchor = [
            uint256(0),
            30_999_999_999_999_999_950_656_000,                // 31M - 49 344 000
            53_999_999_999_999_999_901_312_000,                // 54M - 2 * 49 344 000
            72_999_999_999_999_999_851_968_000,                // 73M - 3 * 49 344 000
            90_000_000_000_000_000_000_000_000                 // the close, 90M to the wei
        ];
        for (uint256 k = 0; k <= 3; k++) {
            assertEq(anchor[k], E_BASE / 4 * k - 49_344_000 * k + (E_SERIES - E_SERIES / (2 ** k)), "precondition: anchor table");
            assertEq(staking.emittedAt(s + k * E_PERIOD), anchor[k], "CO-E: anchor off linear base + geometric bonus");
        }
        assertEq(E_BASE + E_SERIES - E_SERIES / 16, anchor[4], "precondition: base + series close on the published budget");
        assertEq(staking.emittedAt(s + 4 * E_PERIOD), anchor[4], "CO-E: the close is not 90M");
        assertEq(staking.emittedAt(s + 4 * E_PERIOD + 365 days), anchor[4], "CO-E: flat after the close");
    }

    /// CO-E differential. Oracle: integrate the floored rates,
    /// sum_{k<p} (RB + (RX >> k)) * P + (RB + (RX >> p)) * r. The base term RB * dt is the same on
    /// both sides. RX = floor(S / (2P)), so RX >> k = floor(S / (2^(k+1) P)) and (RX >> k) * P lies
    /// in (S / 2^(k+1) - P, S / 2^(k+1)]: the closed form, which books S (1 - 2^-p) exactly, is
    /// above the oracle by less than p * P wei. Exactly, the per-period bonus residues
    /// S / 2^(k+1) - (RX >> k) * P are 2 176 000, 1 088 000, 544 000 wei, so the gap at p = 0..3 is
    /// 0, 2 176 000, 3 264 000, 3 808 000.
    function testFuzz_ClosedFormEmissionVersusTheSumOfRates(uint256 x) public view {
        uint256 s = staking.emissionStart();
        x = bound(x, s, staking.emissionEnd() - 1);
        uint256 dt = x - s;
        uint256 p = dt / E_PERIOD;
        uint256 oracle;
        for (uint256 k = 0; k < p; k++) oracle += (E_RB + (E_RX >> k)) * E_PERIOD;
        oracle += (E_RB + (E_RX >> p)) * (dt - p * E_PERIOD);
        uint256 closed = staking.emittedAt(x);
        uint256[4] memory gap = [uint256(0), 2_176_000, 3_264_000, 3_808_000];
        assertGe(closed, oracle, "CO-E: the closed form fell below the integrated rates");
        assertLe(closed - oracle, p * E_PERIOD, "CO-E: the closed form ran ahead of the integrated rates");
        assertEq(closed - oracle, gap[p], "CO-E: the gap is not the bonus floor residues of the completed periods");
    }

    // ── reward channel ───────────────────────────────────────────────────────

    /// MR-D1. With A a whole number of tokens, A * boost / 10000 is an integer, so bob's tracked
    /// weight is exactly twice alice's. gross = floor(w * acc / WAD) and the reward debt are each
    /// floors, so 2 * floor(z) and floor(2z) differ by 0 or 1 in each: bob earns twice alice within
    /// 1 wei. A lock that lapsed inside the window is then paid floor(earned * N / D) once
    /// (`_postUnlockAtBase`), with bob's N and D exactly twice alice's and N <= D, which adds at
    /// most 1 more: |pending_b - 2 pending_a| <= 2.
    function testFuzz_TwiceTheStakeEarnsTwiceTheReward(uint256 tokens, uint256 lockDays, uint256 dt) public {
        tokens   = bound(tokens, 1_000, 15_000_000);
        lockDays = bound(lockDays, 90, MAXD);
        dt       = bound(dt, 1 hours, 4 * 365 days);
        uint256 A = tokens * 1e18;
        uint256 t0 = this.clockTs();
        uint256 n0 = this.clockBlock();

        vm.prank(admin); staking.fundEmission(90_000_000e18);
        vm.prank(alice); staking.deposit(A, lockDays);
        vm.prank(bob);   staking.deposit(2 * A, lockDays);
        vm.warp(t0 + dt);
        vm.roll(n0 + 11);

        uint256 pa = staking.pendingRewards(alice);
        uint256 pb = staking.pendingRewards(bob);
        assertGt(pa, 0, "non-vacuous: the channel paid something");
        uint256 diff = pb > 2 * pa ? pb - 2 * pa : 2 * pa - pb;
        assertLe(diff, 2, "MR-D1: the reward channel is not linear in the stake");
    }

    /// MR-D2. Two deposits a, b in one block re-key the same lock (newUnlock == unlockTime) and
    /// resync to the same weight as one deposit of a + b; the reward debt is taken at the same
    /// accumulator. Expected exactly equal.
    function testFuzz_SplitDepositEarnsWhatOneDepositEarns(uint256 a, uint256 b, uint256 lockDays, uint256 dt) public {
        a        = bound(a, 1, 10_000_000e18);
        b        = bound(b, 1_000e18, 10_000_000e18);
        lockDays = bound(lockDays, 90, MAXD);
        dt       = bound(dt, 1 hours, 4 * 365 days);
        uint256 t0 = this.clockTs();
        uint256 n0 = this.clockBlock();

        vm.prank(admin); staking.fundEmission(90_000_000e18);
        vm.prank(alice); staking.deposit(a + b, lockDays);
        vm.prank(bob);   staking.deposit(a, lockDays);
        vm.prank(bob);   staking.deposit(b, lockDays);
        assertEq(staking.effectiveBoostOf(alice), this.boostOf(bob), "same lock on both");
        vm.warp(t0 + dt);
        vm.roll(n0 + 11);

        uint256 pa = staking.pendingRewards(alice);
        uint256 pb = staking.pendingRewards(bob);
        assertGt(pa, 0, "non-vacuous: the channel paid something");
        assertEq(pb, pa, "MR-D2: splitting a deposit changed the reward");
    }

    function boostOf(address w) external view returns (uint256) { return staking.effectiveBoostOf(w); }
    // via_ir may re-read TIMESTAMP/NUMBER for a local after vm.warp/vm.roll; an external call's
    // result cannot be rematerialised, so the start of the clock is captured through these.
    function clockTs() external view returns (uint256) { return block.timestamp; }
    function clockBlock() external view returns (uint256) { return block.number; }
}
