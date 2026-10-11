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
//    MR-E2  inside one halving period the emission is exactly linear at R0 >> p
//    CO-E   at every period anchor the emission is the geometric series
//           TOTAL * (1 - 2^-k), exactly; anywhere, the closed form sits at or
//           above the sum of the floored rates and less than p * PERIOD wei over it
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

    function testFuzz_EmissionInsideAPeriodIsLinear(uint256 x, uint256 delta) public view {
        uint256 s = staking.emissionStart();
        uint256 P = staking.HALVING_PERIOD();
        x = bound(x, s, staking.emissionEnd() - 1);
        uint256 p = (x - s) / P;
        uint256 periodEnd = s + (p + 1) * P;               // first second of the next period
        delta = bound(delta, 0, periodEnd - 1 - x);
        uint256 r = staking.INITIAL_REWARD_PER_SEC() >> p;
        assertEq(staking.emittedAt(x + delta) - staking.emittedAt(x), r * delta, "MR-E2: not linear at R0 >> p");
    }

    /// CO-E anchors. TOTAL_REWARDS = 1.8e26 = 2^26 * 9 * 5^25, so TOTAL >> k == TOTAL / 2^k exactly
    /// for k <= 8, and the specified geometric series TOTAL * (1 - 2^-k) is met to the wei.
    function test_EmissionAtEveryPeriodAnchorIsTheGeometricSeries() public view {
        uint256 s = staking.emissionStart();
        uint256 P = staking.HALVING_PERIOD();
        uint256 T = staking.TOTAL_REWARDS();
        assertEq(T % (2 ** 8), 0, "precondition of the exactness: TOTAL divisible by 2^8");
        for (uint256 k = 0; k <= 8; k++) {
            assertEq(staking.emittedAt(s + k * P), T - T / (2 ** k), "CO-E: anchor off the geometric series");
        }
        assertEq(staking.emittedAt(staking.emissionEnd() + 365 days), T - T / 256, "CO-E: flat after the close");
    }

    /// CO-E differential. Oracle: integrate the floored rates, sum_{k<p} (R0 >> k) * P + (R0 >> p) * r.
    /// R0 = floor(T / (2P)), so R0 >> k = floor(T / (2^(k+1) P)) and (R0 >> k) * P lies in
    /// (T / 2^(k+1) - P, T / 2^(k+1)]. Summed over k < p against the exact T (1 - 2^-p): the
    /// closed form is >= the oracle and exceeds it by less than p * P wei.
    function testFuzz_ClosedFormEmissionVersusTheSumOfRates(uint256 x) public view {
        uint256 s = staking.emissionStart();
        uint256 P = staking.HALVING_PERIOD();
        uint256 R0 = staking.INITIAL_REWARD_PER_SEC();
        x = bound(x, s, staking.emissionEnd() - 1);
        uint256 dt = x - s;
        uint256 p = dt / P;
        uint256 oracle;
        for (uint256 k = 0; k < p; k++) oracle += (R0 >> k) * P;
        oracle += (R0 >> p) * (dt - p * P);
        uint256 closed = staking.emittedAt(x);
        assertGe(closed, oracle, "CO-E: the closed form fell below the integrated rates");
        assertLe(closed - oracle, p * P, "CO-E: the closed form ran ahead of the integrated rates");
    }

    // ── reward channel ───────────────────────────────────────────────────────

    /// MR-D1. With A a whole number of tokens, A * boost / 10000 is an integer, so bob's tracked
    /// weight is exactly twice alice's. gross = floor(w * acc / WAD) and the reward debt are each
    /// floors, so 2 * floor(z) and floor(2z) differ by 0 or 1 in each: |pending_b - 2 pending_a| <= 2.
    function testFuzz_TwiceTheStakeEarnsTwiceTheReward(uint256 tokens, uint256 lockDays, uint256 dt) public {
        tokens   = bound(tokens, 1_000, 15_000_000);
        lockDays = bound(lockDays, 90, MAXD);
        dt       = bound(dt, 1 hours, 4 * 365 days);
        uint256 A = tokens * 1e18;
        uint256 t0 = this.clockTs();
        uint256 n0 = this.clockBlock();

        vm.prank(admin); staking.fundEmission(100_000_000e18);
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

        vm.prank(admin); staking.fundEmission(100_000_000e18);
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
