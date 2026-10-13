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

    /// RESIDUAL, documented and not fixed. Below the clamp the pre-discovery book still reads
    /// solvent: the slice moved from `totalStaked` to the reserve and the pure-yield pot, so
    /// `_owed()` is unchanged until carol is touched. A lone pure staker whose own claim is the
    /// first transaction after a ~200-year gap is paid her share of the whole slice, including
    /// the 830,000 BZPX carol cannot pay. Closing it needs collectibility per borrower at credit
    /// time, which is not O(1); see the RETIFICA notes. At the clamp the pre-discovery book
    /// already reads insolvent and the claim is closed (test above).
    function test_PUREUNCOLL_documents_firstMoverBelowTheClampIsStillPaid() public {
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
        uint256 a0 = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimPureYield();
        uint256 paid = token.balanceOf(alice) - a0;
        emit log_named_decimal_uint("lone first mover paid           ", paid, 18);
        emit log_named_decimal_uint("pool share of collected interest", _poolShareOfCollected(), 18);
        emit log_named_decimal_uint("uncollected interest            ", staking.totalUncollectedInterest(), 18);
        assertGt(staking.totalUncollectedInterest(), 0, "setup: the claim's own sweep finds the loss");
        assertGt(paid, _poolShareOfCollected() + DUST, "documents: paid before the loss was known");
        assertFalse(staking.isSolvent(), "documents: and the book reads insolvent right after");
    }
}
