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

    /// Once the loss is booked, no later transaction (own claim, lock, third-party pokes)
    /// pays pure yield at par while the loss stays uncovered.
    function test_PUREUNCOLL_noLaterTxPaysPureYieldOnceTheLossIsBooked() public {
        _openBook();
        vm.prank(keeper);
        staking.claimRewards();
        // Give the pot enough cash to pay bob at par, but not enough to cover the booked loss:
        // what is measured is the rule, not an empty balance.
        deal(address(token), address(staking), token.balanceOf(address(staking)) + 1_500_000e18);
        assertFalse(staking.isSolvent(), "setup: the loss must still be uncovered");
        uint256 before = _pureHolders();

        vm.prank(keeper);
        try staking.pokeExpiredLock(bob) {} catch {}
        address[] memory both = new address[](2);
        both[0] = alice;
        both[1] = bob;
        vm.prank(keeper);
        try staking.pokeExpiredLocks(both) {} catch {}
        vm.prank(alice);
        try staking.lock(30) {} catch {}
        vm.prank(bob);
        try staking.claimPureYield() {} catch {}

        uint256 paid = _pureHolders() - before;
        emit log_named_decimal_uint("pure yield paid after the booking", paid, 18);
        assertLe(paid, _poolShareOfCollected() + DUST, "a later tx paid pure yield from uncollected interest");
    }

    /// The first transaction after the gap is a pure staker's own claim: the slice is credited
    /// before its own maintenance window reaches carol and books the loss. At the clamp the
    /// credited pot already exceeds backing, so the settle-time check closes the payment.
    function test_PUREUNCOLL_firstMoverAtTheClampIsClosed() public {
        _openBook();
        uint256 before = _pureHolders();
        vm.prank(alice);
        try staking.claimPureYield() {} catch {}
        uint256 paid = _pureHolders() - before;
        emit log_named_decimal_uint("pure yield paid to the first mover", paid, 18);
        emit log_named_decimal_uint("pool share of collected interest  ", _poolShareOfCollected(), 18);
        assertLe(paid, _poolShareOfCollected() + DUST, "first mover paid pure yield from uncollected interest");
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
