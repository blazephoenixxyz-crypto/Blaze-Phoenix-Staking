// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Adversarial emission tests: an attacker with capital, time and transaction order of
///         their choice. The curve oracle is an independent re-implementation of the documented
///         closed form from literals (8-year emission: a 60M linear base plus a bonus that halves
///         every two years, 16M + 8M + 4M + 2M), never `emittedAt` itself.
contract EmissionAttackTest is Base {
    uint256 internal constant BASE = 60_000_000e18;
    uint256 internal constant S = 32_000_000e18; // halving series: S - (S >> 4) = 30M bonus
    uint256 internal constant P = 2 * 365 days;
    uint256 internal constant L = 4 * P;
    uint256 internal constant RB = BASE / L; // base wei/s
    uint256 internal constant RX = (S / 2) / P; // bonus wei/s in the first period
    uint256 internal constant CAP = 90_000_000e18;
    uint256 internal constant B90 = 10199; // boostByDays(90), pinned in test_BoostCurve
    // Per-period rate (base + (bonus >> p)), written as literals and cross-checked against RB/RX.
    uint256 internal constant R0 = 491_501_775_748_351_090;
    uint256 internal constant R1 = 364_662_607_813_292_744;
    uint256 internal constant R2 = 301_243_023_845_763_571;
    uint256 internal constant R3 = 269_533_231_861_998_984;
    // Floor remainders folded into the step that closes each period [derived: (S >> (p+1)) - (RX >> p) * P
    // for the bonus; BASE - RB * L for the base, which falls at the close].
    uint256 internal constant REM0 = 2_176_000;
    uint256 internal constant REM1 = 1_088_000;
    uint256 internal constant REM2 = 544_000;
    uint256 internal constant REM_CLOSE = 197_376_000 + 31_808_000;

    uint256 internal t0;
    uint256 internal bn;

    function setUp() public override {
        super.setUp();
        t0 = staking.emissionStart();
        bn = block.number;
    }

    /// Oracle: the documented curve, from literals.
    function _curve(uint256 x) internal view returns (uint256) {
        if (x <= t0) return 0;
        uint256 dt = x - t0;
        if (dt >= L) return BASE + S - (S >> 4);
        uint256 p = dt / P;
        return RB * dt + (S - (S >> p)) + (RX >> p) * (dt - p * P);
    }

    /// Per-period cap on one window: the rate of the period the window starts in, plus the remainder
    /// of the one turn that can lift a step above it [derived: every later step R_q + REM_q is below
    /// R_p for q > p, the gaps R_p - R_{p+1} being ~3e16 wei against remainders below 3e8].
    function _windowCap(uint256 a, uint256 d) internal view returns (uint256) {
        uint256 p = a <= t0 ? 0 : (a - t0) / P;
        if (p >= 4) return 0;
        uint256[4] memory r = [R0, R1, R2, R3];
        uint256[4] memory rem = [REM0, REM1, REM2, REM_CLOSE];
        return d * r[p] + rem[p];
    }

    function _go(uint256 t) internal {
        bn += 30;
        vm.warp(t);
        vm.roll(bn);
    }

    function _fund(uint256 amount) internal {
        vm.prank(admin);
        staking.fundEmission(amount);
    }

    function _claim(address u) internal returns (uint256 got) {
        uint256 b = token.balanceOf(u);
        vm.prank(u);
        staking.claimRewards();
        got = token.balanceOf(u) - b;
    }

    // ── vector 1: emission ───────────────────────────────────────────────────────────────

    /// Halving and close boundaries: t = start, start+1, each period's last second, rollover, +1,
    /// emissionEnd −1 / 0 / +1 and the far future, each against the literal oracle.
    function test_ATK_EMIS_halvingBoundariesMatchTheLiteralCurve() public view {
        uint256 e = staking.emissionEnd();
        assertEq(e, t0 + L, "end is four periods after the start");
        uint256[4] memory r = [R0, R1, R2, R3];
        for (uint256 p = 0; p < 4; p++) {
            assertEq(RB + (RX >> p), r[p], "oracle: the literal period rate is not base + (bonus >> p)");
        }
        uint256[15] memory xs = [t0, t0 + 1, t0 + P - 1, t0 + P, t0 + P + 1, t0 + 2 * P - 1, t0 + 2 * P,
            t0 + 2 * P + 1, t0 + 3 * P - 1, t0 + 3 * P, t0 + 3 * P + 1, e - 1, e, e + 1, type(uint256).max];
        for (uint256 i = 0; i < xs.length; i++) {
            assertEq(staking.emittedAt(xs[i]), _curve(xs[i]), "ATK-EMIS: emittedAt departs from the literal curve");
        }
        // Each two-year period closes on its exact wei: 31M, 23M, 19M less the base's floored share
        // (49,344,000 wei a period), then exactly 90M at the close.
        assertEq(staking.emittedAt(t0 + P), 31_000_000e18 - 49_344_000, "ATK-EMIS: period 0 closes off 31M");
        assertEq(staking.emittedAt(t0 + 2 * P), 54_000_000e18 - 98_688_000, "ATK-EMIS: period 1 closes off 54M");
        assertEq(staking.emittedAt(t0 + 3 * P), 73_000_000e18 - 148_032_000, "ATK-EMIS: period 2 closes off 73M");
        assertEq(staking.emittedAt(e), CAP, "ATK-EMIS: the close reads exactly TOTAL_REWARDS");
        // Each turn folds its period's floored-rate remainder into the step that closes it.
        assertEq(staking.emittedAt(t0 + P) - staking.emittedAt(t0 + P - 1), R0 + REM0,
            "ATK-EMIS: first turn step is not R0 + remainder");
        assertEq(staking.emittedAt(t0 + 2 * P) - staking.emittedAt(t0 + 2 * P - 1), R1 + REM1,
            "ATK-EMIS: second turn step is not R1 + remainder");
        assertEq(staking.emittedAt(t0 + 3 * P) - staking.emittedAt(t0 + 3 * P - 1), R2 + REM2,
            "ATK-EMIS: third turn step is not R2 + remainder");
        assertEq(staking.emittedAt(e) - staking.emittedAt(e - 1), R3 + REM_CLOSE,
            "ATK-EMIS: close step is not R3 + base and bonus remainders");
    }

    /// Monotone and Lipschitz: no window releases more than its period's rate per second plus the
    /// remainder of the one turn it may cross (_windowCap).
    function testFuzz_ATK_EMIS_curveIsMonotoneAndRateBounded(uint256 a, uint256 d) public view {
        a = bound(a, t0 - 1, t0 + L + P);
        d = bound(d, 0, L + P);
        uint256 ea = staking.emittedAt(a);
        uint256 eb = staking.emittedAt(a + d);
        assertLe(ea, eb, "ATK-EMIS: curve decreased");
        assertLe(eb, CAP, "ATK-EMIS: curve above the cap");
        assertLe(eb - ea, _windowCap(a, d), "ATK-EMIS: a window released more than the rate allows");
    }

    /// Drain above the funded amount: half the cap funded, one whale through the whole curve and
    /// 100 years past it. The reserve clamp is the only thing between the curve and an underflow.
    function test_ATK_EMIS_underfundedCurvePaysAtMostWhatWasFunded() public {
        _fund(CAP / 2);
        vm.prank(alice); staking.deposit(30_000_000e18, 90);
        uint256 e = staking.emissionEnd();
        // 45M funded: the curve passes it in the second period (54M at its close), so the clamp bites there.
        uint256[8] memory ts = [t0 + 1, t0 + P - 1, t0 + P, t0 + 2 * P, t0 + 3 * P, e - 1, e, e + 100 * 365 days];
        uint256 paid;
        for (uint256 i = 0; i < ts.length; i++) {
            _go(ts[i]);
            paid += _claim(alice);
            assertLe(paid, CAP / 2, "ATK-EMIS: paid above the funded amount");
            assertLe(paid, _curve(ts[i]), "ATK-EMIS: paid above the curve");
        }
        assertEq(staking.rewardReserve() + paid + staking.totalRewardDistributed() - staking.totalRewardsPaid(),
            CAP / 2, "ATK-EMIS: the funded amount is not conserved");
    }

    /// Rounding over many windows: three odd-sized stakers claim every hour for 600 windows.
    /// Floors only ever round DOWN the payout, and the dust stays in pendingDistribution:
    /// below tbe/WAD + 1 wei per window plus one wei per staker [derived: the accumulator floor
    /// loses < tbe/WAD of each window's reward; each position's floor loses < 1 wei].
    function test_ATK_EMIS_manyWindowsRoundingNeverOverpays() public {
        _fund(CAP);
        address[3] memory us = [alice, bob, carol];
        uint256[3] memory amt = [uint256(1_000e18 + 1), 7_777e18 + 3, 1_234_567e18 + 7];
        for (uint256 i = 0; i < 3; i++) { vm.prank(us[i]); staking.deposit(amt[i], 90); }
        uint256 t = block.timestamp;
        uint256 got;
        for (uint256 k = 0; k < 600; k++) {
            t += 1 hours;
            _go(t);
            for (uint256 i = 0; i < 3; i++) got += _claim(us[i]);
        }
        uint256 dist = staking.totalRewardDistributed();
        assertLe(got, dist, "ATK-EMIS: rounding paid more than was distributed");
        uint256 bound = 600 * (staking.totalBoostedEffective() / 1e18 + 1) + 3;
        assertLe(dist - got, bound, "ATK-EMIS: rounding dust above its derived bound");
        assertEq(got, staking.totalRewardsPaid(), "paid counter equals tokens received");
        console2.log("rounding dust (wei), bound:", dist - got, bound);
    }

    // ── vector 2: reward accounting ──────────────────────────────────────────────────────

    /// A deposit and a withdraw in the same block, and up to MIN_DEPOSIT_BLOCKS later, are refused.
    function test_ATK_ACCT_sameBlockRoundTripRefused() public {
        _fund(CAP);
        vm.prank(alice); staking.deposit(1_000_000e18, 90);
        uint256 b0 = block.number;
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__FlashLoanProtection.selector);
        staking.withdraw(1);
        vm.roll(b0 + 10);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__FlashLoanProtection.selector);
        staking.withdraw(1);
        vm.roll(b0 + 11);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__StillLocked.selector);
        staking.withdraw(1);
    }

    /// Sandwich of the funding transaction: a staker exposed to an unfunded window gains nothing
    /// when the reserve is topped up afterwards (the window is settled against the old reserve).
    function test_ATK_ACCT_fundingSandwichHarvestsNoBacklog() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 90);
        _go(t0 + 10 days);
        _fund(CAP);
        assertEq(staking.pendingRewards(alice), 0, "ATK-ACCT: funding paid an unfunded window retroactively");
        _go(t0 + 10 days + 1);
        // one second in the first period: at most R0 (base + full bonus rate)
        assertLe(staking.pendingRewards(alice), R0, "ATK-ACCT: more than one second of emission after funding");
    }

    /// Empty pool, then a late first depositor: the 30-day backlog is not claimable by anyone;
    /// it stays in rewardReserve [the residue's first source].
    function test_ATK_ACCT_lateFirstDepositorGetsNoBacklog() public {
        _fund(CAP);
        _go(t0 + 30 days);
        vm.prank(alice); staking.deposit(1_000_000e18, 90);
        _go(t0 + 30 days + 1);
        uint256 got = _claim(alice);
        assertLe(got, R0, "ATK-ACCT: the first depositor harvested the empty window");
        // only the 1 s window was emitted: the 30-day backlog _curve(t0 + 30 days) is still there
        assertEq(staking.rewardReserve(), CAP - (_curve(t0 + 30 days + 1) - _curve(t0 + 30 days)),
            "ATK-ACCT: the empty window did not stay in the reserve");
    }

    /// 1 wei staked alone for 30 days (first depositor with dust): throttled to dust; then a real
    /// staker joins and earns at the full rate. No share price to inflate.
    function test_ATK_ACCT_oneWeiAloneEarnsDust() public {
        _fund(CAP);
        vm.prank(alice); staking.deposit(1, 90);
        _go(t0 + 30 days);
        uint256 dust = staking.pendingRewards(alice);
        assertLe(dust, _curve(t0 + 30 days) / 1_000e18 + 1, "ATK-ACCT: one wei earned above the throttle");
        vm.prank(bob); staking.deposit(1_000_000e18, 90);
        uint256 s = t0 + 30 days; // via_ir caches block.timestamp: the clock is carried
        _go(s + 1 days);
        uint256 want = _curve(s + 1 days) - _curve(s);
        assertApproxEqRel(staking.pendingRewards(bob), want, 1e12, "ATK-ACCT: the real staker is diluted by dust");
    }

    // ── vector 3: order and time ─────────────────────────────────────────────────────────

    /// Claims repeated in the same block pay nothing after the first.
    function test_ATK_TIME_repeatedClaimSameBlockPaysOnce() public {
        _fund(CAP);
        vm.prank(alice); staking.deposit(1_000_000e18, 90);
        _go(t0 + 7 days);
        assertGt(_claim(alice), 0, "setup: first claim pays");
        assertEq(_claim(alice), 0, "ATK-TIME: a second claim in the same block paid again");
        assertEq(_claim(alice), 0, "ATK-TIME: a third claim in the same block paid again");
    }

    /// One 100-year jump, one claim: exactly the curve minus the LOCK-STALE residue, which is
    /// the post-unlock part of the window at weight (B90 − 1)/B90 [derived from _postUnlockAtBase].
    /// Then re-stake after the close is refused, at the close second exactly.
    function test_ATK_TIME_centuryJumpPaysTheCurveAndRestakeIsClosed() public {
        _fund(CAP);
        vm.prank(alice); staking.deposit(1_000_000e18, 90);
        uint256 e = staking.emissionEnd();
        _go(e);
        vm.prank(bob);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmissionEnded.selector);
        staking.deposit(1_000e18, 90);
        _go(t0 + 100 * 365 days);
        uint256 got = _claim(alice);
        // Alice is the only staker from t0 to the close; her 90-day lock ends at t0 + 90 days, still in
        // the first period, so xu = R0 * 7,776,000 s = 3,821,917.808219178075840000 BZPX. After it the
        // window pays her at base weight 10000 while tbe still carries B90: LOCK-STALE =
        // (90M - xu) * 199 / 10199 = 1,681,482.337107989367870167 BZPX, payout 88,318,517.66289... BZPX.
        uint256 xu = _curve(t0 + 90 days);
        assertEq(xu, R0 * 90 days, "oracle: the unlock falls in the first period");
        uint256 lockStale = (CAP - xu) * (B90 - 10000) / B90;
        assertLe(got, CAP, "ATK-TIME: paid above the cap");
        assertApproxEqAbs(got, CAP - lockStale, 1e9, "ATK-TIME: payout departs from curve minus LOCK-STALE");
        assertApproxEqAbs(staking.rewardReserve(), lockStale, 1e9, "ATK-TIME: residue is not the LOCK-STALE part");
        console2.log("residue 1 staker, 1 claim after 100y (wei):", staking.rewardReserve());
    }

    // ── vector 5: privileges ─────────────────────────────────────────────────────────────

    /// Every admin/guardian door refuses a stranger by selector and role; after the admin
    /// renounces, the residue can never leave (sweep is admin-only) while users still exit.
    function test_ATK_PRIV_strangerRefusedAndRenounceStrandsTheResidue() public {
        _fund(CAP);
        vm.prank(alice); staking.deposit(1_000_000e18, 90);
        bytes32 ra = keccak256("ADMIN_ROLE");
        bytes32 rg = keccak256("GUARDIAN_ROLE");
        bytes memory na = abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, ra);
        bytes memory ng = abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, rg);
        vm.startPrank(bob);
        vm.expectRevert(na); staking.fundEmission(1);
        vm.expectRevert(na); staking.withdrawReserve(1);
        vm.expectRevert(na); staking.sweepUndistributedEmission();
        vm.expectRevert(na); staking.unpause();
        vm.expectRevert(na); staking.cancelEmergency();
        vm.expectRevert(ng); staking.pause();
        vm.expectRevert(ng); staking.declareEmergency();
        vm.stopPrank();
        // the admin renounces both roles
        vm.startPrank(admin);
        staking.renounceRole(ra, admin);
        staking.renounceRole(staking.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();
        _go(staking.emissionEnd() + 1);
        uint256 got = _claim(alice);
        vm.prank(alice); staking.withdraw(1_000_000e18);
        assertGt(got, 0, "users still claim after the renounce");
        uint256 r = staking.rewardReserve();
        assertGt(r, 0, "setup: a LOCK-STALE residue exists");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", admin, ra));
        staking.sweepUndistributedEmission();
        assertEq(staking.rewardReserve(), r, "ATK-PRIV: the residue moved without an admin");
        console2.log("residue stranded after renounce (wei):", r);
    }
}
