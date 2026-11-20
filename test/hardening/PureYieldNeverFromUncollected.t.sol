// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice PURE-UNCOLL. Oracle: pure stakers are never paid more than the pool share
///         (1 - reserve factor) of the interest that was actually collected from borrowers,
///         `totalInterestAccruedGlobal - totalUncollectedInterest`.
///         The book: two equal pure stakers and one borrower whose interest, left untouched for
///         a very long time, outgrows her collateral. `_updateInterestIndex` credits the whole
///         slice to the pure-yield accumulator before `_accrueInterestFor` learns that part of
///         it cannot be collected, so the loss is only known once the borrower is touched.
contract PureYieldNeverFromUncollectedTest is Base {
    uint256 internal constant STAKE = 1_000_000e18;
    uint256 internal constant DUST = 1e10;

    function _openBook() internal {
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
    }

    function _pureHolders() internal view returns (uint256) {
        return token.balanceOf(alice) + token.balanceOf(bob);
    }

    function _poolShareOfCollected() internal view returns (uint256) {
        uint256 collected = staking.totalInterestAccruedGlobal() - staking.totalUncollectedInterest();
        return collected * 9_700 / 10_000;
    }

    /// The transaction that books the loss must not go on to pay pure yield out of it. Today the
    /// keeper's touch credits the slice, books carol's shortfall in `maintStep`, and then the
    /// lock window's `lockStep(alice)` pays alice 1,455,000 BZPX at par.
    function test_PUREUNCOLL_bookingTxPaysNoUncollectedPureYield() public {
        _openBook();
        uint256 before = _pureHolders();
        vm.prank(keeper);
        staking.claimRewards();
        uint256 paid = _pureHolders() - before;
        assertGt(staking.totalUncollectedInterest(), 0, "setup: the booking tx found uncollectible interest");
        emit log_named_decimal_uint("pure yield paid in the booking tx", paid, 18);
        emit log_named_decimal_uint("pool share of collected interest ", _poolShareOfCollected(), 18);
        assertLe(paid, _poolShareOfCollected() + DUST, "booking tx pays pure yield from uncollected interest");
    }

    /// Once the loss is booked, no later transaction pays pure yield at par while the loss stays
    /// uncovered. The loss is booked by a keeper's liquidation of carol, which carries no lock
    /// window, so alice's and bob's elapsed locks are still on record afterwards: each poke below
    /// has a commitment to normalise, and its `lockStep` settles the pure yield into the breach.
    /// The staker's own claim is closed under a breach and is pinned as such.
    function test_PUREUNCOLL_noLaterTxPaysPureYieldOnceTheLossIsBooked() public {
        _openBook();
        vm.prank(keeper);
        staking.liquidate(carol);
        // Give the pot enough cash to pay the pure stakers at par, but not enough to cover the
        // booked loss: what is measured is the rule, not an empty balance.
        deal(address(token), address(staking), token.balanceOf(address(staking)) + 1_500_000e18);
        assertFalse(staking.isSolvent(), "setup: the loss must still be uncovered");
        assertGt(_lockDays(alice), 0, "setup: alice's elapsed lock is still on record");
        assertGt(_lockDays(bob), 0, "setup: bob's elapsed lock is still on record");
        uint256 before = _pureHolders();
        uint256 aliceOwed = _entitlement(alice);
        uint256 bobOwed = _entitlement(bob);
        assertGt(aliceOwed, 0, "setup: alice is owed something to withhold");
        assertGt(bobOwed, 0, "setup: bob is owed something to withhold");

        vm.prank(bob);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.claimPureYield();

        // A third-party batch normalises alice by name; it reverts if it normalised nothing.
        address[] memory onlyAlice = new address[](1);
        onlyAlice[0] = alice;
        vm.prank(keeper);
        staking.pokeExpiredLocks(onlyAlice);
        assertEq(_lockDays(alice), 0, "the batch did not normalise alice");
        assertGt(_lockDays(bob), 0, "the batch reached past its list");
        assertEq(_entitlement(alice) + _pureHolders() - before, aliceOwed, "the batch did not credit alice");

        // A keeper's single poke normalises bob.
        vm.prank(keeper);
        staking.pokeExpiredLock(bob);
        assertEq(_lockDays(bob), 0, "the poke did not normalise bob");

        uint256 paid = _pureHolders() - before;
        emit log_named_decimal_uint("pure yield paid after the booking", paid, 18);
        // The breach has not cleared, so each settle credits all of `due` and pays nothing: a
        // one-wei payment passes the DUST bound below and keeps the credit equality, but not this.
        assertEq(paid, 0, "a later tx paid pure yield while the breach is open");
        assertLe(paid, _poolShareOfCollected() + DUST, "a later tx paid pure yield from uncollected interest");
        // Withheld is not forfeited: what was not paid is still owed, as a credit.
        assertEq(_entitlement(alice) + _entitlement(bob) + paid, aliceOwed + bobOwed, "the withheld pure yield was not credited");
    }

    function _lockDays(address user_) internal view returns (uint256 lockDays) {
        (,,,,,,,,, lockDays,,,,) = staking.getUserInfo(user_);
    }

    /// What `user_` is owed and a claim in this block would settle: the pure-yield quote plus the
    /// reward quote, which carries the credit deferred under a breach.
    function _entitlement(address user_) internal view returns (uint256) {
        return staking.pendingPureYield(user_) + staking.pendingRewards(user_);
    }

    /// The first transaction after the gap is a pure staker's own claim: the slice is credited
    /// before its own maintenance window reaches carol and books the loss. At the clamp the
    /// credited pot already exceeds backing, so the settle-time check closes the payment.
    function test_PUREUNCOLL_firstMoverAtTheClampIsClosed() public {
        _openBook();
        uint256 before = _pureHolders();
        uint256 owed = _entitlement(alice);
        assertGt(owed, 0, "setup: the first mover is owed something to withhold");
        // The claim must SUCCEED and credit: closing the payment is not closing the door.
        vm.prank(alice);
        staking.claimPureYield();
        uint256 paid = _pureHolders() - before;
        emit log_named_decimal_uint("pure yield paid to the first mover", paid, 18);
        emit log_named_decimal_uint("pool share of collected interest  ", _poolShareOfCollected(), 18);
        assertLe(paid, _poolShareOfCollected() + DUST, "first mover paid pure yield from uncollected interest");
        assertEq(_entitlement(alice) + paid, owed, "the withheld pure yield was not credited");
    }

    /// Below the clamp the pre-discovery book still reads solvent: the slice moved from
    /// `totalStaked` to the reserve and the pure-yield pot, so `_owed()` is unchanged until carol
    /// is touched. A lone pure staker whose own claim is the first transaction after a ~200-year
    /// gap used to be paid her share of the whole slice, including the 830,000 BZPX carol cannot
    /// pay, because her claim's maintenance window booked carol's loss AFTER paying her. LOSS-FIRST
    /// runs that window before the settle, so the claim reads the pot after the loss and is closed.
    /// RESIDUAL, still documented: a loss on a borrower that this transaction's window does not
    /// reach is read only as a lower bound (`_owed`); closing it needs collectibility per borrower
    /// at credit time, which is not O(1); see the RETIFICA notes.
    /// Red at c31b6c5 (the window ran last): alice was paid and the book read insolvent after.
    function test_PUREUNCOLL_firstMoverBelowTheClampIsCreditedByItsOwnSweep() public {
        vm.prank(alice);
        staking.deposit(2 * STAKE, 90);
        vm.prank(carol);
        staking.deposit(STAKE, 90);
        vm.roll(block.number + 11);
        uint256 maxB = staking.maxBorrowOf(carol);
        vm.prank(carol);
        staking.borrow(maxB);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 200 * 365 days);
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before carol is touched");
        (uint256 a0, uint256 c0, uint256 paid0) =
            (token.balanceOf(alice), token.balanceOf(address(staking)), staking.totalRewardsPaid());
        // W2-R1: the claim's own sweep books carol's loss; the pure yield is then credited to
        // `_rewardDeferred`, not
        // paid at par and not reverted.
        vm.prank(alice);
        staking.claimPureYield();
        assertFalse(staking.isSolvent(), "setup: the sweep booked the loss");
        assertEq(token.balanceOf(alice), a0, "pure yield paid at par into the breach");
        assertEq(token.balanceOf(address(staking)), c0, "the pot moved");
        assertEq(staking.totalRewardsPaid(), paid0, "nothing counted as paid");
        assertGt(staking.pendingRewards(alice), 0, "the pure yield stays credited");
    }
}
