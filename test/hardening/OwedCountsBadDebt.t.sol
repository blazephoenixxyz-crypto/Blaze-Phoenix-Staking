// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice OWED-FCFS. Uncovered bad debt is a claim the contract cannot pay, so `_owed()` counts it
///         instead of netting it out. Oracle: while `isSolvent()` reads true, every staker can exit
///         whole; once claims exceed backing, the normal exit closes, the permissionless breaker
///         opens the pro-rata exit, and anyone can recapitalise the loss with `absorbBadDebt`.
///         The book: two equal pure stakers and one borrower whose interest, left untouched for a
///         very long time, outgrows her collateral; one neutral touch books the loss.
contract OwedCountsBadDebtTest is Base {
    uint256 internal constant STAKE = 1_000_000e18;
    uint256 internal constant DUST = 1e10;

    function _badDebtBook() internal returns (uint256 bad) {
        vm.prank(alice);
        staking.deposit(STAKE, 90);
        vm.prank(bob);
        staking.deposit(STAKE, 90);
        vm.prank(carol);
        staking.deposit(STAKE, 90);
        vm.roll(block.number + 11);
        uint256 maxB = staking.maxBorrowOf(carol);
        vm.prank(carol);
        staking.borrow(maxB);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 1000 * 365 days);
        vm.prank(keeper);
        staking.claimRewards();   // the borrower window of `_autoMaintain` reaches carol
        bad = staking.totalBadDebt();
        assertGt(bad, DUST, "setup: an uncovered loss must be booked");
        assertEq(staking.protocolReserve(), 0, "setup: the reserve was consumed first");
    }

    function _absorb(uint256 amount) internal returns (bool ok) {
        // Low-level so the file compiles against a tree without the function (red-first).
        (ok,) = address(staking).call(abi.encodeWithSignature("absorbBadDebt(uint256)", amount));
    }

    function test_E3_uncoveredBadDebtReadsInsolvent() public {
        uint256 bad = _badDebtBook();
        assertFalse(staking.isSolvent(), "uncovered bad debt must read insolvent");
        assertGe(staking.owed(), staking.backing() + bad - DUST, "owed counts the uncovered loss");
    }

    function test_E3_normalExitClosesWhileInsolvent() public {
        _badDebtBook();
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.withdraw(STAKE);
    }

    function test_E3_breakerOpensEqualProRataExit() public {
        _badDebtBook();
        vm.prank(keeper);
        staking.tripBreaker();
        uint256 pot = staking.backing();
        uint256 a0 = token.balanceOf(alice);
        uint256 b0 = token.balanceOf(bob);
        vm.prank(alice);
        staking.emergencyWithdraw();
        vm.prank(bob);
        staking.emergencyWithdraw();
        uint256 pa = token.balanceOf(alice) - a0;
        uint256 pb = token.balanceOf(bob) - b0;
        emit log_named_decimal_uint("pot at trip ", pot, 18);
        emit log_named_decimal_uint("alice payout", pa, 18);
        emit log_named_decimal_uint("bob payout  ", pb, 18);
        assertApproxEqAbs(pa, pb, DUST, "equal stakes exit equal, whatever the order");
        assertLe(pa + pb, pot, "never pays out more than the pot");
    }

    function test_E3_absorbBadDebtRecapitalisesAndReopensExit() public {
        uint256 bad = _badDebtBook();
        token.mint(keeper, bad);
        vm.startPrank(keeper);
        token.approve(address(staking), bad);
        assertTrue(_absorb(bad), "anyone can absorb the uncovered loss");
        vm.stopPrank();
        assertEq(staking.totalBadDebt(), 0, "the loss is recapitalised");
        assertTrue(staking.isSolvent(), "solvent again");
        vm.prank(alice);
        staking.withdraw(STAKE);
    }

    function test_E3_absorbBadDebtLetsAdminCancelAfterTrip() public {
        uint256 bad = _badDebtBook();
        vm.prank(keeper);
        staking.tripBreaker();
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.cancelEmergency();
        token.mint(keeper, bad);
        vm.startPrank(keeper);
        token.approve(address(staking), bad);
        assertTrue(_absorb(bad), "absorb works during the emergency");
        vm.stopPrank();
        vm.prank(admin);
        staking.cancelEmergency();
    }

    function test_E3_absorbCapsAtTheLossAndRevertsWithoutOne() public {
        uint256 bad = _badDebtBook();
        token.mint(keeper, 2 * bad);
        vm.startPrank(keeper);
        token.approve(address(staking), 2 * bad);
        uint256 k0 = token.balanceOf(keeper);
        assertTrue(_absorb(2 * bad), "over-sized absorb is capped, not rejected");
        assertEq(k0 - token.balanceOf(keeper), bad, "pulls exactly the uncovered loss, no donation");
        assertFalse(_absorb(1), "nothing left to absorb");
        vm.stopPrank();
    }

    // ── the full-value channels close together under a breach (any cause) ───────────────────
    // A shortfall is simulated by lowering the contract's balance (an unrecorded loss); the gates
    // read `_hardBreach()` whatever the cause, so the same book watches every one of them.

    function _breachedBook() internal {
        vm.prank(alice);
        staking.deposit(STAKE, 90);
        vm.prank(bob);
        staking.deposit(STAKE, 90);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 1 days);
        deal(address(token), address(staking), token.balanceOf(address(staking)) - 1_000e18);
        assertFalse(staking.isSolvent(), "setup: the book must read insolvent");
    }

    function test_E3_depositClosesUnderBreach() public {
        _breachedBook();
        vm.prank(carol);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.deposit(STAKE, 90);
    }

    function test_E3_borrowClosesUnderBreach() public {
        _breachedBook();
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.borrow(1e18);
    }

    function test_E3_claimRewardsClosesUnderBreach() public {
        _breachedBook();
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.claimRewards();
    }

    function test_E3_claimPureYieldClosesUnderBreach() public {
        _breachedBook();
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.claimPureYield();
    }

    function test_E3_withdrawReserveClosesUnderBreach() public {
        _breachedBook();
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.withdrawReserve(1);
    }
}
