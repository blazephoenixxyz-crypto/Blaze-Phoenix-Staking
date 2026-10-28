// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {console} from "forge-std/Test.sol";

/// @notice Emergency-exit and normal-exit review items. Each `test_<KEY>_...` asserts the correct
///         behaviour and was red before its fix; a `test_<KEY>_documents_...` test pins the current
///         behaviour of an item left for an owner decision, with the measured figures logged.
contract EmergencyAndExitTest is Base {
    uint256 constant S = 10_000_000e18;

    function _guardian() internal {
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
    }

    function _stake(address u, uint256 amount) internal {
        vm.prank(u);
        staking.deposit(amount, 90);
    }

    /// @dev Simulates a theft: removes `x` BZPX from the contract so the hard breach is real.
    function _steal(uint256 x) internal {
        deal(address(token), address(staking), token.balanceOf(address(staking)) - x);
    }

    function _emgExit(address u) internal returns (uint256 got) {
        uint256 b0 = token.balanceOf(u);
        vm.prank(u);
        staking.emergencyWithdraw();
        got = token.balanceOf(u) - b0;
    }

    // ──────────────────────────────────────────────────────────────────────────────────────
    // EMG-HAIRCUT (3236). The haircut denominator eCorr = totalPositiveEquity − own tracked + own
    // payout carried the OTHER positions' stale-high trackedEquity (interest accrued since their
    // last touch), so the first exiter was scaled by pot / (stale-high E) and the slack flowed to
    // whoever exited last: the payout depended on the exit order.
    // Oracle: payout_i = eq_i · pot / Σ eq_true, with eq_true = staked − accrued interest − debt.
    // Fix: the breached haircut runs only on a fresh book (global − attributed interest ≤ dust);
    // otherwise it reverts Staking__StaleEquity until `syncEquity` refreshes the borrowers.
    // Single borrower, so after the trip totalStaked − totalDebt − bob.staked is alice's exact
    // true equity (global slice == her per-user interest).
    // ──────────────────────────────────────────────────────────────────────────────────────
    function test_EMG_HAIRCUT_payout_does_not_depend_on_exit_order() public {
        _stake(alice, S);
        _stake(bob, S);
        vm.roll(block.number + 11);
        vm.prank(alice);
        staking.borrow(S / 2);                       // at the LTV cap: 50% of effective stake

        vm.warp(block.timestamp + 3 * 365 days);     // no touches: alice's trackedEquity goes stale
        _steal(5_000_000e18);
        assertFalse(staking.isSolvent(), "shortfall must be real");
        vm.prank(carol);
        staking.tripBreaker();

        // Stale book: the haircut waits instead of scaling bob against alice's stale term.
        vm.prank(bob);
        vm.expectRevert(BlazePhoenixStaking.Staking__StaleEquity.selector);
        staking.emergencyWithdraw();
        staking.syncEquity(alice);

        uint256 pot = token.balanceOf(address(staking));
        uint256 eqB = S;
        uint256 eqA = staking.totalStaked() - staking.totalDebt() - eqB;   // alice's true equity
        uint256 oracleA = eqA * pot / (eqA + eqB);
        uint256 oracleB = eqB * pot / (eqA + eqB);

        uint256 snap = vm.snapshotState();
        // Order A: bob (pure) first, then alice.
        uint256 bobA = _emgExit(bob);
        uint256 aliceA = _emgExit(alice);
        vm.revertToState(snap);
        // Order B: alice first, then bob.
        uint256 aliceB = _emgExit(alice);
        uint256 bobB = _emgExit(bob);

        assertApproxEqAbs(bobA, oracleB, 1e12, "order A bob vs oracle");
        assertApproxEqAbs(aliceA, oracleA, 1e12, "order A alice vs oracle");
        assertApproxEqAbs(aliceB, oracleA, 1e12, "order B alice vs oracle");
        assertApproxEqAbs(bobB, oracleB, 1e12, "order B bob vs oracle");
        assertLe(bobA + aliceA, pot, "never over-drains the pot");
    }

    // ──────────────────────────────────────────────────────────────────────────────────────
    // EMG-EMIT. emergencyWithdraw removes the exiter's boosted weight without _updateGlobal,
    // so the emission window since lastRewardTime is later credited only to those who stay.
    // Oracle: two equal positions (same amount, same lock) over the window [t0, t1] each earn
    // half of emittedAt(t1) − emittedAt(t0); bob claims at t1, so he must receive half.
    // ──────────────────────────────────────────────────────────────────────────────────────
    function test_EMG_EMIT_exit_does_not_hand_window_to_stayers() public {
        vm.prank(admin);
        staking.fundEmission(50_000_000e18);
        _guardian();
        _stake(alice, S);
        _stake(bob, S);
        // Read t0 from storage: via-IR rematerialises block.timestamp after vm.warp.
        uint256 t0 = staking.lastRewardTime();

        uint256 t1 = t0 + 30 days;
        vm.warp(t1);
        uint256 window = staking.emittedAt(t1) - staking.emittedAt(t0);

        vm.prank(keeper);
        staking.declareEmergency();
        _emgExit(alice);
        vm.startPrank(admin);
        staking.cancelEmergency();
        staking.unpause();
        vm.stopPrank();

        uint256 b0 = token.balanceOf(bob);
        vm.prank(bob);
        staking.claimRewards();
        uint256 got = token.balanceOf(bob) - b0;
        console.log("window emission", window);
        console.log("bob received   ", got);
        assertApproxEqRel(got, window / 2, 1e15, "bob received the exiter's share of the window");
    }

    // ──────────────────────────────────────────────────────────────────────────────────────
    // SELF-LIQ. liquidate(user_) pays the 5% surplus to msg.sender even when msg.sender == user_,
    // so an underwater borrower collects the keeper bonus on its own position (the sweep excludes
    // itself for exactly this reason). Oracle: self-liquidation pays the caller nothing; alice's
    // BZPX balance must not increase. No emission is funded and alice holds no pure weight, so
    // the bonus is the only transfer the call could make to her.
    // ──────────────────────────────────────────────────────────────────────────────────────
    function test_SELF_LIQ_self_liquidation_pays_no_bonus() public {
        _stake(alice, S);
        vm.roll(block.number + 11);
        uint256 d = S / 2;
        vm.prank(alice);
        staking.borrow(d);

        // Land the stake at ~1.025·debt: liquidatable (debt·100 >= stake·95) with a positive surplus.
        uint256 rate = staking.currentInterestRateBps();
        uint256 interest = S - (d * 1025) / 1000;
        uint256 elapsed = interest * 10_000 * 365 days / (d * rate);
        vm.warp(block.timestamp + elapsed);

        uint256 b0 = token.balanceOf(alice);
        vm.prank(alice);
        staking.liquidate(alice);
        uint256 gained = token.balanceOf(alice) - b0;
        console.log("rate bps", rate);
        console.log("alice gained from self-liquidation", gained);
        assertEq(gained, 0, "self-liquidation paid the bonus to the liquidated user");
    }

    // ──────────────────────────────────────────────────────────────────────────────────────
    // WD-BREACH. withdraw does not check _hardBreach(): with a real shortfall the first debt-free
    // staker exits whole (first come, first served) and the loss lands on whoever is left.
    // Oracle: under a hard breach the normal exit must revert (exits go through the haircut).
    // ──────────────────────────────────────────────────────────────────────────────────────
    function test_WD_BREACH_withdraw_reverts_under_hard_breach() public {
        _stake(alice, S);
        _stake(bob, S);
        vm.warp(block.timestamp + 91 days);
        vm.roll(block.number + 11);
        _steal(1_000_000e18);
        assertFalse(staking.isSolvent(), "shortfall must be real");

        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.withdraw(S);
    }
}
