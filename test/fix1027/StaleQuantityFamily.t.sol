// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

interface IEquitySync {
    function syncEquity(address user_) external;
}

/// @notice Wave 3, family 1: a stale quantity in a denominator or a weight (3236 + 3324/3349/
///         3248-R1-03, 3326, 3328, 3256-W2-R1, 3248-R1-02). A weight or denominator may fix a
///         payment only when it is derivable at that moment; when it is not, the book freezes or
///         credits instead of paying at par. Every test here was red on eb9b9cd.
contract StaleQuantityFamilyTest is Base {
    uint256 constant S = 10_000_000e18;
    uint256 constant WAD = 1e18;
    uint256 constant USERS_SLOT = 36;
    uint256 constant ATTRIBUTED_SLOT = 38;      // _interestAttributed
    uint256 constant DIST_AT_TRIP_SLOT = 39;    // _distributedAtTrip
    uint256 constant LAST_MAINT_SLOT = 32;      // lastMaintTime
    uint256 constant DUST = 1e10;               // CONSERVATION_DUST
    bytes4 constant STALE = bytes4(keccak256("Staking__StaleEquity()"));
    bytes4 constant BREACHED = bytes4(keccak256("Staking__InvariantBreached()"));
    bytes4 constant NOT_ACTIVE = bytes4(keccak256("Staking__EmergencyNotActive()"));

    // ── helpers ─────────────────────────────────────────────────────────────────────────
    function _guardian() internal {
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
    }

    function _stake(address u, uint256 amount, uint256 days_) internal {
        vm.prank(u);
        staking.deposit(amount, days_);
    }

    function _steal(uint256 x) internal {
        deal(address(token), address(staking), token.balanceOf(address(staking)) - x);
    }

    function _emgExit(address u) internal returns (uint256 got) {
        uint256 b0 = token.balanceOf(u);
        vm.prank(u);
        staking.emergencyWithdraw();
        got = token.balanceOf(u) - b0;
    }

    function _ld(address u, uint256 off) internal view returns (uint256) {
        return uint256(vm.load(address(staking), bytes32(uint256(keccak256(abi.encode(u, USERS_SLOT))) + off)));
    }

    /// @dev True equity at the frozen index: staked − min(owed interest, staked) − debt, floored at 0.
    function _trueEq(address u) internal view returns (uint256) {
        uint256 staked = _ld(u, 0);
        uint256 debt = _ld(u, 1);
        if (debt != 0) {
            uint256 i = debt * (staking.accInterestPerDebt() - _ld(u, 5)) / WAD;
            staked -= i > staked ? staked : i;
        }
        return staked > debt ? staked - debt : 0;
    }

    function _trySync() internal returns (bool ok) {
        address[3] memory w = [alice, bob, carol];
        ok = true;
        for (uint256 i; i < 3; ++i) {
            try IEquitySync(address(staking)).syncEquity(w[i]) {} catch { ok = false; }
        }
    }

    /// @dev Two borrowers (alice, carol) and one pure staker (bob); the borrowers go stale for `dt`.
    function _staleBook(uint256 dt, uint256 aPct, uint256 cPct) internal {
        _stake(alice, S, 90);
        _stake(bob, S, 90);
        _stake(carol, S / 2, 90);
        vm.roll(block.number + 11);
        uint256 a = staking.maxBorrowOf(alice) * aPct / 100;
        vm.prank(alice);
        staking.borrow(a);
        uint256 c = staking.maxBorrowOf(carol) * cPct / 100;
        if (c > 0) { vm.prank(carol); staking.borrow(c); }
        vm.warp(block.timestamp + dt);
    }

    // ── 3236 (+3324, 3349, 3248-R1-03): the haircut denominator is fresh or the exit waits ──
    function testFuzz_P1_EMG_exit_order_never_changes_a_payout(uint256 dt, uint256 stealPct, uint256 aPct, uint256 cPct, uint8 perm)
        public
    {
        dt = bound(dt, 30 days, 4 * 365 days);
        stealPct = bound(stealPct, 20, 70);
        aPct = bound(aPct, 10, 100);
        cPct = bound(cPct, 10, 100);
        _staleBook(dt, aPct, cPct);
        _steal(token.balanceOf(address(staking)) * stealPct / 100);
        vm.prank(keeper);
        staking.tripBreaker();
        _trySync();

        address[3] memory who = [alice, bob, carol];
        uint256[3] memory eq;
        uint256 sum;
        for (uint256 i; i < 3; ++i) { eq[i] = _trueEq(who[i]); sum += eq[i]; }
        uint256 pot = token.balanceOf(address(staking));
        assertLt(pot, sum, "the haircut must engage");

        uint8[3][6] memory orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
        uint8[3] memory o = orders[perm % 6];
        uint256 paid;
        for (uint256 k; k < 3; ++k) {
            uint256 i = o[k];
            uint256 got = _emgExit(who[i]);
            assertApproxEqAbs(got, eq[i] * pot / sum, 1e11, "payout depends on the exit order");
            paid += got;
        }
        assertLe(paid, pot, "over-drain");
    }

    function test_P1_EMG_haircut_waits_for_a_fresh_book() public {
        _staleBook(3 * 365 days, 100, 60);
        _steal(token.balanceOf(address(staking)) / 2);
        vm.prank(keeper);
        staking.tripBreaker();

        vm.prank(bob);
        vm.expectRevert(STALE);
        staking.emergencyWithdraw();

        assertTrue(_trySync(), "the sync door must exist");
        uint256 pot = token.balanceOf(address(staking));
        uint256 sum = _trueEq(alice) + _trueEq(bob) + _trueEq(carol);
        uint256 eqB = _trueEq(bob);
        assertApproxEqAbs(_emgExit(bob), eqB * pot / sum, 1e11, "bob after the sync");
    }

    /// @dev The guard's threshold is the dust, not a looser bound: ONE small borrower left unsynced
    ///      (U between 1e11 and 1e13 wei) already makes the haircut wait.
    function test_P1_EMG_haircut_threshold_is_the_dust() public {
        _stake(alice, S, 90);
        _stake(bob, S, 90);
        _stake(carol, 10e18, 90);
        vm.roll(block.number + 11);
        vm.prank(carol);
        staking.borrow(1e18);
        vm.warp(block.timestamp + 1 hours);
        _steal(token.balanceOf(address(staking)) / 2);
        vm.prank(keeper);
        staking.tripBreaker();
        uint256 u = uint256(vm.load(address(staking), bytes32(uint256(18))))
            - uint256(vm.load(address(staking), bytes32(ATTRIBUTED_SLOT)));
        assertGt(u, 1e11, "setup: U above 1e11");
        assertLt(u, 1e13, "setup: U below 1e13");

        vm.prank(bob);
        vm.expectRevert(STALE);
        staking.emergencyWithdraw();

        IEquitySync(address(staking)).syncEquity(carol);
        uint256 pot = token.balanceOf(address(staking));
        uint256 sum = _trueEq(alice) + _trueEq(bob) + _trueEq(carol);
        uint256 eqB = _trueEq(bob);
        assertApproxEqAbs(_emgExit(bob), eqB * pot / sum, 1e11, "bob after the sync");
    }

    function test_P1_EMG_solvent_exit_needs_no_sync() public {
        _staleBook(365 days, 100, 60);
        _guardian();
        vm.prank(keeper);
        staking.declareEmergency();
        assertEq(_emgExit(bob), S, "a solvent exit pays the full net equity");
    }

    function test_P1_META_attribution_overshoot_refuses_the_haircut() public {
        _staleBook(0, 100, 60);   // nothing accrued: U == 0
        _steal(token.balanceOf(address(staking)) / 2);
        vm.prank(keeper);
        staking.tripBreaker();
        uint256 g = uint256(vm.load(address(staking), bytes32(uint256(18))));   // totalInterestAccruedGlobal
        vm.store(address(staking), bytes32(ATTRIBUTED_SLOT), bytes32(g + 2 * DUST));
        vm.prank(bob);
        vm.expectRevert(STALE);
        staking.emergencyWithdraw();
    }

    function test_P1_SYNC_reverts_outside_an_emergency() public {
        _staleBook(30 days, 100, 60);
        vm.expectRevert(NOT_ACTIVE);
        IEquitySync(address(staking)).syncEquity(alice);
    }

    function test_P1_SYNC_refreshes_equity_and_leaves_the_weights() public {
        _staleBook(365 days, 100, 60);
        _steal(token.balanceOf(address(staking)) / 2);
        vm.prank(keeper);
        staking.tripBreaker();
        uint256 eqA = _trueEq(alice);
        uint256 eqC = _trueEq(carol);
        uint256 tbe = staking.totalBoostedEffective();
        uint256 tbp = staking.totalBoostedPure();
        assertTrue(_trySync(), "the sync door must exist");
        assertEq(_ld(alice, 8), eqA, "alice trackedEquity");
        assertEq(_ld(carol, 8), eqC, "carol trackedEquity");
        assertEq(staking.totalPositiveEquity(), eqA + eqC + _trueEq(bob), "totalPositiveEquity");
        assertEq(staking.totalBoostedEffective(), tbe, "emission weight repriced");
        assertEq(staking.totalBoostedPure(), tbp, "pure weight repriced");
    }

    // ── 3326: emission freezes for the emergency, like interest ─────────────────────────
    function test_3326_emission_is_frozen_for_the_emergency() public {
        vm.prank(admin);
        staking.fundEmission(100_000_000e18);
        _stake(alice, S, 90);
        uint256 t = block.timestamp + 80 days;
        vm.warp(t);
        _guardian();
        vm.prank(keeper);
        staking.declareEmergency();
        uint256 p0 = staking.pendingRewards(alice);
        assertGt(p0, 0, "something earned before the halt");
        t += 30 days;   // the lock expires inside the emergency
        vm.warp(t);
        assertEq(staking.pendingRewards(alice), p0, "the quote grows during the emergency");
        vm.prank(admin);
        staking.cancelEmergency();
        uint256 b0 = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards();
        assertEq(token.balanceOf(alice) - b0, p0, "the emergency window was paid");
    }

    function test_3326_META_cancel_refuses_emission_moved_in_the_emergency() public {
        vm.prank(admin);
        staking.fundEmission(100_000_000e18);
        _stake(alice, S, 90);
        vm.warp(block.timestamp + 10 days);
        _guardian();
        vm.prank(keeper);
        staking.declareEmergency();
        vm.store(address(staking), bytes32(DIST_AT_TRIP_SLOT), bytes32(staking.totalRewardDistributed() + 1));
        vm.prank(admin);
        vm.expectRevert(BREACHED);
        staking.cancelEmergency();
    }

    // ── 3328: the batch poke does not write the lock window's clock ─────────────────────
    function test_3328_batch_poke_leaves_the_lock_window_clock_alone() public {
        _stake(alice, S, 700);
        _stake(carol, S, 700);
        _stake(keeper, S, 700);
        _stake(admin, S, 700);
        _stake(bob, S, 90);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 120 days);
        uint256 clock = uint256(vm.load(address(staking), bytes32(LAST_MAINT_SLOT)));
        address[] memory l = new address[](1);
        l[0] = bob;
        staking.pokeExpiredLocks(l);
        assertEq(uint256(vm.load(address(staking), bytes32(LAST_MAINT_SLOT))), clock, "batch poke reset the lock clock");
        assertEq(staking.lockSweepBudget(), staking.activeLockerCount(), "lock window starved");
    }

    // ── P6 under a hard breach: open doors pay nothing at par (W2-R1, R1-02) ────────────
    // W2-R1: the pure yield is credited to `_rewardDeferred`; R1-02: `keeperBonus` stays in the reserve.
    /// @dev bob: pure, 90-day lock expired, pure yield pending. alice: liquidatable with surplus.
    function _breachedBook() internal {
        _stake(alice, S, 90);
        _stake(bob, S, 90);
        vm.roll(block.number + 11);
        uint256 a = staking.maxBorrowOf(alice);
        vm.prank(alice);
        staking.borrow(a);
        uint256 t = block.timestamp;
        for (uint256 i; i < 80 && staking.daysToLiquidation(alice) != 0; ++i) {
            t += 365 days;
            vm.warp(t);
        }
        assertEq(staking.daysToLiquidation(alice), 0, "alice never became liquidatable");
        _steal(1_000e18);
        assertFalse(staking.isSolvent(), "breach must be real");
    }

    function test_R1_02_liquidation_bonus_stays_in_reserve_under_breach() public {
        _breachedBook();
        uint256 k0 = token.balanceOf(keeper);
        uint256 pr0 = staking.protocolReserve();
        vm.prank(keeper);
        staking.liquidate(alice);
        assertEq(token.balanceOf(keeper), k0, "keeper paid at par into a breach");
        assertGt(staking.protocolReserve(), pr0, "bonus not kept in the reserve");
    }

    /// @dev bob: pure, 90-day lock expired, pure yield pending; alice borrows; hard breach. Short
    ///      enough that the emission has not ended (a relock is still possible).
    function _pureBreachedBook() internal {
        _stake(alice, S, 90);
        _stake(bob, S, 90);
        vm.roll(block.number + 11);
        uint256 a = staking.maxBorrowOf(alice);
        vm.prank(alice);
        staking.borrow(a);
        vm.warp(block.timestamp + 120 days);
        _steal(1_000e18);
        assertFalse(staking.isSolvent(), "breach must be real");
    }

    function _pokeKeepsBobsClaim(uint256 door) internal {
        _pureBreachedBook();
        uint256 owed0 = staking.pendingRewards(bob) + staking.pendingPureYield(bob);
        assertGt(owed0, 0, "bob has nothing pending");
        uint256 b0 = token.balanceOf(bob);
        if (door == 0) {
            staking.pokeExpiredLock(bob);
        } else if (door == 1) {
            address[] memory l = new address[](1);
            l[0] = bob;
            staking.pokeExpiredLocks(l);
        } else {
            vm.prank(bob);
            staking.lock(90);
        }
        assertEq(token.balanceOf(bob), b0, "paid at par into a breach");
        assertApproxEqAbs(staking.pendingRewards(bob) + staking.pendingPureYield(bob), owed0, 1e9, "claim lost");
    }

    function test_W2_R1_poke_under_breach_credits_the_pure_yield() public { _pokeKeepsBobsClaim(0); }
    function test_W2_R1_batch_poke_under_breach_credits_the_pure_yield() public { _pokeKeepsBobsClaim(1); }
    function test_W2_R1_relock_under_breach_credits_the_pure_yield() public { _pokeKeepsBobsClaim(2); }

    function test_P6_claims_stay_closed_under_breach() public {
        _breachedBook();
        vm.prank(bob);
        vm.expectRevert(BREACHED);
        staking.claimPureYield();
        vm.prank(bob);
        vm.expectRevert(BREACHED);
        staking.claimRewards();
    }
}
