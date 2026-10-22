// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice EMIS-DEFER. Oracle: while the pot cannot cover every claim (`isSolvent() == false`), no
///         transaction pays emission at par, whichever door reaches the settlement (the owner's
///         repay, a third-party lock poke, a liquidation). The doors stay open: the earned amount
///         stays credited to the position, the published quote keeps showing it, and it is paid
///         by the first settlement after the loss is covered.
///         The book: emission funded, one pure staker, two borrowers left untouched for decades;
///         the liquidation of one books an uncovered loss, so the contract reads a hard breach.
///         Red at cc614f9: repay and pokeExpiredLock paid the whole pending emission at par.
contract EmissionDeferredUnderBreachTest is Base {
    uint256 internal constant DUST = 1e10;
    address internal dave = address(0xD4);

    function _breachedBook() internal {
        _fund(dave);
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        vm.prank(alice);
        staking.deposit(2_000e18, 90);
        vm.prank(carol);
        staking.deposit(1_000e18, 365);
        vm.prank(bob);
        staking.deposit(1_000e18, 90);
        vm.prank(dave);
        staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(carol);
        staking.borrow(400e18);
        vm.prank(bob);
        staking.borrow(500e18);
        vm.prank(dave);
        staking.borrow(500e18);
        vm.warp(block.timestamp + 100 days + 60 * 365 days);
        vm.roll(block.number + 30);
        vm.prank(keeper);
        staking.liquidate(bob);
        assertFalse(staking.isSolvent(), "setup: hard breach");
        assertGt(staking.totalBadDebt(), DUST, "setup: an uncovered loss is recorded");
    }

    function test_EMISDEFER_repayUnderBreachPaysNoEmissionAndKeepsTheCredit() public {
        _breachedBook();
        uint256 pend = staking.pendingRewards(carol);
        assertGt(pend, DUST, "setup: carol has earned emission");
        uint256 paidBefore = staking.totalRewardsPaid();
        uint256 b0 = token.balanceOf(carol);
        vm.prank(carol);
        staking.repay(1e18);
        assertEq(token.balanceOf(carol), b0 - 1e18, "repay under breach moved only the repayment");
        assertEq(staking.totalRewardsPaid(), paidBefore, "no emission counted as paid");
        assertGe(staking.pendingRewards(carol), pend, "the earned emission stays credited");
    }

    function test_EMISDEFER_thirdPartyPokeUnderBreachPaysNoEmission() public {
        _breachedBook();
        uint256 pend = staking.pendingRewards(carol);
        uint256 b0 = token.balanceOf(carol);
        vm.prank(keeper);
        staking.pokeExpiredLock(carol);
        assertEq(token.balanceOf(carol), b0, "a third-party poke paid emission under breach");
        assertGe(staking.pendingRewards(carol), pend, "the earned emission stays credited");
    }

    /// A position closed by liquidation under breach keeps its credit, even when the
    /// liquidation leaves nothing and deletes the position.
    function test_EMISDEFER_liquidationUnderBreachPaysNoEmissionAndKeepsTheCredit() public {
        _breachedBook();
        uint256 pend = staking.pendingRewards(dave);
        assertGt(pend, DUST, "setup: dave has earned emission");
        uint256 b0 = token.balanceOf(dave);
        vm.prank(keeper);
        staking.liquidate(dave);
        assertFalse(staking.isTrackedBorrower(dave), "setup: dave was liquidated");
        assertEq(token.balanceOf(dave), b0, "liquidation under breach paid emission");
        assertGe(staking.pendingRewards(dave), pend, "the earned emission stays credited");
        // The closed position still claims it once the loss is covered.
        vm.prank(keeper);
        staking.absorbBadDebt(type(uint256).max);
        assertTrue(staking.isSolvent(), "setup: the loss is covered");
        uint256 quote = staking.pendingRewards(dave);
        uint256 b1 = token.balanceOf(dave);
        vm.prank(dave);
        staking.claimRewards();
        assertEq(token.balanceOf(dave) - b1, quote, "the closed position is paid its credit");
    }

    /// The credit is paid, quote == execution, by the first settlement once the loss is covered.
    function test_EMISDEFER_deferredCreditIsPaidOnceSolvent() public {
        _breachedBook();
        uint256 pend = staking.pendingRewards(carol);
        vm.prank(carol);
        staking.repay(1e18);
        vm.prank(keeper);
        staking.absorbBadDebt(type(uint256).max);
        assertTrue(staking.isSolvent(), "setup: the loss is covered");
        uint256 quote = staking.pendingRewards(carol);
        assertGe(quote, pend, "quote still carries the credit");
        uint256 b0 = token.balanceOf(carol);
        vm.prank(carol);
        staking.claimRewards();
        assertEq(token.balanceOf(carol) - b0, quote, "claim pays exactly the published quote");
        assertEq(staking.pendingRewards(carol), 0, "nothing left credited");
    }

    /// The emergency exit forfeits unpaid emission, and a deferred credit is unpaid emission.
    function test_EMISDEFER_emergencyExitForfeitsTheDeferredCredit() public {
        _breachedBook();
        vm.prank(carol);
        staking.repay(1e18);
        assertGt(staking.pendingRewards(carol), DUST, "setup: a credit was deferred");
        vm.prank(keeper);
        staking.tripBreaker();
        vm.prank(carol);
        staking.emergencyWithdraw();
        assertEq(staking.pendingRewards(carol), 0, "the exited position keeps no emission credit");
    }
}
