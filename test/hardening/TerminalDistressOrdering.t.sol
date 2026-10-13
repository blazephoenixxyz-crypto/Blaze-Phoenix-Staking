// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice TERMINAL-DISTRESS ORDERING (documents). Left for an owner decision; see the pull
///         request.
///
///         Regime: the book went untouched long enough that the interest slice exceeds
///         `totalStaked`, so `_interestSlice` clamps the index and the eager global debit takes
///         the whole `totalStaked`. Two borrowers at different loan-to-value ratios: the uniform
///         index charges carol (max ratio) more than her stake and bob (lower ratio) less than
///         his. Carol's uncollectible excess goes back into `totalStaked` only when carol is
///         accrued (`_accrueInterestFor`, uncollectible branch).
///
///         If bob is seized FIRST, `totalStaked` (still near zero) is below the collateral
///         seized; the saturating subtraction in `_executeLiquidation` drops the difference, the
///         per-transaction identity no longer balances, and `conserves` reverts the whole
///         transaction. A neutral touch whose maintenance window reaches bob first therefore
///         reverts. Liquidating carol first restores her excess and every later call succeeds.
///         Oracle: the same state, two orders.
contract TerminalDistressOrderingTest is Base {
    uint256 internal constant STAKE = 1_000_000e18;

    function _book(uint256 yearsAhead) internal {
        vm.prank(bob);
        staking.deposit(STAKE, 90);
        vm.prank(carol);
        staking.deposit(STAKE, 90);
        vm.roll(block.number + 11);
        uint256 bobBorrow = staking.maxBorrowOf(bob) * 6_139 / 10_000;
        vm.prank(bob);
        staking.borrow(bobBorrow);
        uint256 maxC = staking.maxBorrowOf(carol);
        vm.prank(carol);
        staking.borrow(maxC);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + yearsAhead * 365 days);
    }

    function test_TERMDISTRESS_documents_neutralTouchRevertsWhenTheUnderWaterSideIsSeizedFirst() public {
        _book(100);
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.claimRewards();
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.liquidate(bob);
    }

    function test_TERMDISTRESS_liquidatingTheOverWaterPositionFirstRestoresLiveness() public {
        _book(100);
        vm.prank(keeper);
        staking.liquidate(carol);
        assertGt(staking.totalUncollectedInterest(), 0, "setup: carol's excess must be restored");
        vm.prank(keeper);
        staking.claimRewards();
        assertFalse(staking.isTrackedBorrower(carol), "carol closed");
    }

    /// The healthy horizon of the same book does not enter the regime.
    function test_TERMDISTRESS_tenYearHorizonIsUnaffected() public {
        _book(10);
        vm.prank(keeper);
        staking.claimRewards();
    }

    /// Smallest whole-year horizon (scan 10..100) at which the neutral touch reverts, logged so
    /// the regime's distance from normal operation is on record.
    function test_TERMDISTRESS_logsFirstFailingHorizon() public {
        _book(0);
        uint256 t0 = block.timestamp;
        uint256 first;
        for (uint256 y = 10; y <= 100; y += 1) {
            uint256 snap = vm.snapshotState();
            vm.warp(t0 + y * 365 days);
            vm.prank(keeper);
            try staking.claimRewards() {} catch { first = y; }
            vm.revertToState(snap);
            if (first != 0) break;
        }
        emit log_named_uint("first failing horizon (years)", first);
        assertGt(first, 10, "regime must lie beyond the ten-year horizon");
    }
}
