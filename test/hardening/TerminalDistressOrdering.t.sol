// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice TERMINAL-DISTRESS ORDERING.
///
///         Regime: the book went untouched long enough that the interest slice exceeds
///         `totalStaked`, so `_interestSlice` clamps the index and the eager global debit takes
///         the whole `totalStaked`. Two borrowers at different loan-to-value ratios: the uniform
///         index charges carol (max ratio) more than her stake and bob (lower ratio) less than
///         his. Carol's uncollectible excess goes back into `totalStaked` only when carol is
///         accrued (`_accrueInterestFor`, uncollectible branch).
///
///         If bob is seized FIRST, `totalStaked` (still near zero) is below the collateral
///         seized. `_debitStaked` takes `totalStaked` to zero and carries the rest in
///         `stakedOverdraw`, a term of the conservation identity, so the transaction balances;
///         carol's later attribution settles the overdraw before adding anything back.
///         Oracle: the same state, two orders, both live, and the same end state.
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

    /// Every ledger term, every party's balance and both positions: the end state the orders share.
    function _endState() internal view returns (uint256[] memory e) {
        e = new uint256[](16);
        e[0] = staking.totalStaked();
        e[1] = staking.stakedOverdraw();
        e[2] = staking.totalBadDebt();
        e[3] = staking.protocolReserve();
        e[4] = staking.totalDebt();
        e[5] = staking.totalRewardsPaid();
        e[6] = staking.totalUncollectedInterest();
        e[7] = staking.backing();
        e[8] = staking.owed();
        e[9] = token.balanceOf(keeper);
        e[10] = token.balanceOf(bob);
        e[11] = token.balanceOf(carol);
        (e[12], e[13],,,,,,,,,,,,) = staking.getUserInfo(bob);
        (e[14], e[15],,,,,,,,,,,,) = staking.getUserInfo(carol);
    }

    /// The direct seizure, bob (the under-water side of the overdraw) first, then carol.
    function _bobFirst() internal returns (uint256[] memory) {
        vm.prank(keeper);
        staking.liquidate(bob);
        assertGt(staking.stakedOverdraw(), 0, "setup: seizing bob first overdrew totalStaked");
        vm.prank(keeper);
        staking.liquidate(carol);
        assertEq(staking.stakedOverdraw(), 0, "carol's attribution settled the overdraw");
        assertFalse(staking.isTrackedBorrower(bob), "bob closed");
        assertFalse(staking.isTrackedBorrower(carol), "carol closed");
        assertTrue(staking.isSolvent(), "the reserve covered the loss");
        return _endState();
    }

    function test_TERMDISTRESS_neutralTouchAndSeizureSucceedWhenTheUnderWaterSideIsSeizedFirst() public {
        _book(100);
        uint256 snap = vm.snapshotState();
        // A neutral touch whose maintenance window reaches bob first.
        vm.prank(keeper);
        staking.claimRewards();
        uint256[] memory touched = _endState();
        vm.revertToState(snap);
        assertEq(touched, _bobFirst(), "the neutral touch reaches the end state of the direct seizure");
    }

    function test_TERMDISTRESS_liquidatingTheOverWaterPositionFirstRestoresLiveness() public {
        _book(100);
        uint256 snap = vm.snapshotState();
        uint256[] memory bobFirst = _bobFirst();
        vm.revertToState(snap);
        vm.prank(keeper);
        staking.liquidate(carol);
        assertGt(staking.totalUncollectedInterest(), 0, "setup: carol's excess must be restored");
        vm.prank(keeper);
        staking.claimRewards();
        assertFalse(staking.isTrackedBorrower(carol), "carol closed");
        assertEq(_endState(), bobFirst, "carol first reaches the end state of bob first");
    }

    /// The withdraw site of `_debitStaked`. A pure staker's exit in the clamped regime: carol's
    /// interest has outgrown her stake and is not attributed yet, so `totalStaked` sits below
    /// alice's stake while the emission residue left after `emissionEnd` (the 2^-8 tail) keeps
    /// `totalStaked + rewardReserve + protocolReserve >= totalDebt`, i.e. the book reads solvent and
    /// the withdraw door is open. The debit crosses zero and the excess is carried in
    /// `stakedOverdraw`. Paused, so the maintenance window does not attribute carol in the same tx
    /// and the carried overdraw is observable. A saturating debit there drops the excess from the
    /// identity and `conserves` reverts the exit.
    function test_TERMDISTRESS_pureStakerWithdrawPastTotalStakedCarriesTheOverdraw() public {
        vm.prank(admin);
        staking.fundEmission(180_000_000e18);
        vm.prank(alice);
        staking.deposit(10_000e18, 90);
        vm.prank(carol);
        staking.deposit(STAKE, 90);
        vm.roll(block.number + 11);
        uint256 maxC = staking.maxBorrowOf(carol);
        vm.prank(carol);
        staking.borrow(maxC);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 58 * 365 days);
        vm.startPrank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), admin);
        staking.pause();
        vm.stopPrank();
        assertTrue(staking.isSolvent(), "setup: the book reads solvent, the withdraw door is open");
        uint256 b0 = token.balanceOf(alice);
        vm.prank(alice);
        staking.withdraw(10_000e18);
        assertGe(token.balanceOf(alice) - b0, 10_000e18, "alice exits with her stake");
        assertEq(staking.totalStaked(), 0, "setup: the debit crossed zero");
        assertGt(staking.stakedOverdraw(), 0, "the excess is carried, not dropped");
    }

    /// The healthy horizon of the same book does not enter the regime.
    function test_TERMDISTRESS_tenYearHorizonIsUnaffected() public {
        _book(10);
        vm.prank(keeper);
        staking.claimRewards();
    }

    /// No whole-year horizon (scan 10..100) makes the neutral touch revert.
    function test_TERMDISTRESS_noHorizonRevertsTheNeutralTouch() public {
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
        emit log_named_uint("first failing horizon (years, 0 = none)", first);
        assertEq(first, 0, "the neutral touch is live at every horizon");
    }
}
