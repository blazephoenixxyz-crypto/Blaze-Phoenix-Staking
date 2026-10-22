// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice ERODED-EXIT. Oracle: in an emergency every open position can be closed by its own
///         exit, and once every exit has run and the recorded loss is recapitalised through
///         `absorbBadDebt`, the contract reads solvent and `cancelEmergency` passes, with no raw
///         transfer into the contract.
///         The book: a pure staker and two borrowers left untouched for 80 years, so one
///         borrower's interest outgrows her whole collateral before anything attributes it;
///         the other borrower is liquidated directly, the breaker trips, the pure staker exits
///         first.
///         Red at cc614f9: the eroded borrower's exit reverted `Staking__NoStake` (attribution
///         zeroes her stake first), so her debt could never be booked and the latch stayed shut.
contract ErodedBorrowerEmergencyExitTest is Base {
    address internal dave = address(0xD4);

    function _erodedBook() internal {
        _fund(dave);
        vm.prank(alice);
        staking.deposit(1_000e18, 90);
        vm.prank(dave);
        staking.deposit(3_000e18, 90);
        vm.prank(carol);
        staking.deposit(600e18, 90);
        vm.roll(block.number + 11);
        vm.prank(dave);
        staking.borrow(1_500e18);
        vm.prank(carol);
        staking.borrow(300e18);
        vm.warp(block.timestamp + 80 * 365 days);
        vm.roll(block.number + 30);
        vm.prank(keeper);
        staking.liquidate(dave);
        assertFalse(staking.isSolvent(), "setup: hard breach");
        vm.prank(keeper);
        staking.tripBreaker();
        vm.prank(alice);
        staking.emergencyWithdraw();
    }

    function test_ERODED_emergencyExitClosesAnErodedBorrowerAndBooksItsDebt() public {
        _erodedBook();
        uint256 badBefore = staking.totalBadDebt();
        uint256 b0 = token.balanceOf(carol);
        vm.prank(carol);
        staking.emergencyWithdraw();
        assertEq(token.balanceOf(carol), b0, "an eroded position is paid nothing");
        assertFalse(staking.isTrackedBorrower(carol), "the position is closed");
        assertEq(staking.totalDebt(), 0, "its debt left the book");
        assertGt(staking.totalBadDebt(), badBefore, "and was booked as a loss");
    }

    function test_ERODED_latchOpensAfterEveryExitWithoutARawTransfer() public {
        _erodedBook();
        vm.prank(carol);
        staking.emergencyWithdraw();
        assertEq(staking.totalStaked(), 0, "no stake is left once every position has exited");
        vm.prank(keeper);
        staking.absorbBadDebt(type(uint256).max);
        assertTrue(staking.isSolvent(), "the recapitalised book reads solvent");
        vm.prank(admin);
        staking.cancelEmergency();
        assertFalse(staking.emergencyMode(), "the latch opened");
    }

    /// The part of an exit `totalStaked` could not absorb is carried, not dropped: once the book
    /// is recapitalised and the emergency cancelled before the eroded borrower exits, the
    /// attribution that finally books her (here, her liquidation) passes the conservation check
    /// and leaves no stake that nobody holds.
    function test_ERODED_stakedOverdrawIsSettledByTheLaterAttribution() public {
        _erodedBook();
        assertGt(staking.stakedOverdraw(), 0, "setup: the first exit overdrew totalStaked");
        // Recapitalise the read deficit and cancel, leaving carol unattributed.
        uint256 deficit = staking.solvency().deficit;
        vm.prank(keeper);
        token.transfer(address(staking), deficit + 1);
        vm.startPrank(admin);
        staking.cancelEmergency();
        staking.unpause();
        vm.stopPrank();
        vm.prank(keeper);
        staking.liquidate(carol);
        assertFalse(staking.isTrackedBorrower(carol), "setup: carol was liquidated");
        assertEq(staking.stakedOverdraw(), 0, "the attribution settled the overdraw");
        assertEq(staking.totalStaked(), 0, "no stake is left that nobody holds");
    }
}
