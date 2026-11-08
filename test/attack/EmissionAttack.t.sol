// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Adversarial emission tests: an attacker with capital, time and transaction order of
///         their choice. The curve oracle is an independent re-implementation of the documented
///         closed form from literals (120M series, 5-year periods), never `emittedAt` itself.
contract EmissionAttackTest is Base {
    uint256 internal constant S = 120_000_000e18;
    uint256 internal constant P = 5 * 365 days;
    uint256 internal constant R0 = (S / 2) / P;
    uint256 internal constant CAP = 90_000_000e18;
    uint256 internal constant B90 = 10199; // boostByDays(90), pinned in test_BoostCurve

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
        if (dt >= 2 * P) return S - (S >> 2);
        uint256 p = dt / P;
        return (S - (S >> p)) + (R0 >> p) * (dt - p * P);
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
        assertEq(e, t0 + 2 * P, "end is two periods after the start");
        uint256[9] memory xs = [t0, t0 + 1, t0 + P - 1, t0 + P, t0 + P + 1, e - 1, e, e + 1, type(uint256).max];
        for (uint256 i = 0; i < xs.length; i++) {
            assertEq(staking.emittedAt(xs[i]), _curve(xs[i]), "ATK-EMIS: emittedAt departs from the literal curve");
        }
        assertEq(staking.emittedAt(t0 + P), 60_000_000e18, "ATK-EMIS: period 0 closes at exactly 60M");
        assertEq(staking.emittedAt(e), CAP, "ATK-EMIS: the close reads exactly TOTAL_REWARDS");
        // The rollover jump folds the floored rate's remainder (8,160,000 wei) into the step up.
        assertEq(staking.emittedAt(t0 + P) - staking.emittedAt(t0 + P - 1), R0 + 8_160_000,
            "ATK-EMIS: rollover step is not R0 + remainder");
        assertEq(staking.emittedAt(e) - staking.emittedAt(e - 1), (R0 >> 1) + 4_080_000,
            "ATK-EMIS: close step is not R0/2 + remainder");
    }

    /// Monotone and Lipschitz: no second ever releases more than R0 + the period remainder.
    function testFuzz_ATK_EMIS_curveIsMonotoneAndRateBounded(uint256 a, uint256 d) public view {
        a = bound(a, t0 - 1, t0 + 3 * P);
        d = bound(d, 0, 3 * P);
        uint256 ea = staking.emittedAt(a);
        uint256 eb = staking.emittedAt(a + d);
        assertLe(ea, eb, "ATK-EMIS: curve decreased");
        assertLe(eb, CAP, "ATK-EMIS: curve above the cap");
        assertLe(eb - ea, d * R0 + 8_160_000, "ATK-EMIS: a window released more than the rate allows");
    }

    /// Drain above the funded amount: half the cap funded, one whale through the whole curve and
    /// 100 years past it. The reserve clamp is the only thing between the curve and an underflow.
    function test_ATK_EMIS_underfundedCurvePaysAtMostWhatWasFunded() public {
        _fund(CAP / 2);
        vm.prank(alice); staking.deposit(30_000_000e18, 90);
        uint256 e = staking.emissionEnd();
        uint256[6] memory ts = [t0 + 1, t0 + P - 1, t0 + P, e - 1, e, e + 100 * 365 days];
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
        uint256 xu = _curve(t0 + 90 days);
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
