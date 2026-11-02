// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice Terminal depletion: interest has consumed the whole stake of the book while its debt
///         is still outstanding (totalStaked == 0, totalDebt > 0). The two doors that close a debt
///         stay open in that state and keep the floor-free identity: `repay` takes the debt back
///         whole, and `liquidate` books it as a loss the protocol reserve covers first. Pricing the
///         next slice reads the utilisation, and an empty stake with debt outstanding reads as
///         unbounded (`_utilization`), never as a division by zero. Green on 82febb5 (the fixture reaches
///         the state through interest alone, which a direct report of it did not). Red with the zero guard of
///         `_utilization` deleted: both doors revert (the mutants registered in mutants.py). The
///         views read the same state as maximum distress: utilisation `type(uint256).max` and the
///         ceiling rate of the curve, never the idle floor (red with the guard returning 0).
contract TerminalDepletionDoorsTest is Base {
    uint256 internal constant S = 1_000_000e18;
    uint256 internal constant DUST = 1e10;      // CONSERVATION_DUST

    function _lhs() internal view returns (uint256) {
        return staking.backing() + staking.totalDebt() + staking.totalBadDebt() + staking.stakedOverdraw();
    }

    function _rhs() internal view returns (uint256) {
        return staking.totalStaked() + staking.rewardReserve() + staking.protocolReserve()
             + (staking.totalRewardDistributed() - staking.totalRewardsPaid());
    }

    /// Alice is the whole book: S staked, S/2 borrowed, then nobody touches it for 60 years. At the
    /// 3.5% the curve reads at 50% utilisation the window's slice (1.05 S) exceeds the stake, so
    /// her own claim settles it through the clamp, which re-derives it to exactly S
    /// (S * WAD / (S/2) divides exactly), and her attribution takes her stake to zero. One second
    /// later the book still holds no stake and S/2 of debt, so the door prices a new slice.
    function _depleted() internal {
        vm.prank(alice); staking.deposit(S, 90);
        vm.roll(block.number + 11);
        vm.prank(alice); staking.borrow(S / 2);
        vm.warp(block.timestamp + 60 * 365 days);
        vm.roll(block.number + 11);
        vm.prank(alice); staking.claimRewards();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        assertEq(staking.totalStaked(), 0, "fixture: the interest consumed the whole stake");
        assertEq(staking.totalDebt(), S / 2, "fixture: the debt is still outstanding");
        assertEq(staking.auditInvariants() & 2, 2, "fixture: the solvency signal reads the terminal state");
        assertApproxEqAbs(_lhs(), _rhs(), DUST, "fixture: identity");
    }

    function test_RepayClosesTheDebtOfABookWithNoStakeLeft() public {
        _depleted();
        uint256 a0 = token.balanceOf(alice);
        vm.prank(alice); staking.repay(type(uint256).max);
        assertEq(a0 - token.balanceOf(alice), S / 2, "the debt came back whole");
        assertEq(staking.totalDebt(), 0, "repay closed the book's debt");
        assertFalse(staking.isTrackedBorrower(alice), "the borrower left the registry");
        assertEq(staking.totalBadDebt(), 0, "a repaid debt books no loss");
        assertApproxEqAbs(_lhs(), _rhs(), DUST, "identity after the repay");
        assertTrue(staking.isSolvent(), "solvent after the repay");
    }

    /// One producer, `_utilization()`, feeds the views and the rate: a book with debt and no stake
    /// reads as unbounded utilisation and is priced at the ceiling of the curve
    /// (`simulateRate` caps its input at 100%), the opposite end from an idle book.
    function test_ABookWithDebtAndNoStakeReadsAsMaximumDistress() public {
        _depleted();
        assertEq(staking.utilizationRate(), type(uint256).max, "utilisation reads unbounded");
        (, , , , uint256 uWad, uint256 rate, , , , , , , , , , ) = staking.getGlobalStats();
        assertEq(uWad, type(uint256).max, "the global stats read the same producer");
        uint256 ceiling = staking.simulateRate(1e18);
        assertEq(staking.currentInterestRateBps(), ceiling, "the rate reads the ceiling of the curve");
        assertEq(rate, ceiling, "in both views");
        assertGt(ceiling, staking.simulateRate(0), "the ceiling is not the idle floor");
    }

    function test_LiquidateBooksTheLossOfABookWithNoStakeLeft() public {
        _depleted();
        uint256 pr0 = staking.protocolReserve();
        uint256 k0 = token.balanceOf(keeper);
        vm.prank(keeper); staking.liquidate(alice);
        assertEq(staking.totalDebt(), 0, "the seizure closed the book's debt");
        assertEq(token.balanceOf(keeper), k0, "nothing was seized, so no bonus was paid");
        assertEq(staking.protocolReserve(), pr0 - S / 2, "the reserve covered the loss first");
        assertEq(staking.totalBadDebt(), 0, "nothing was left uncovered");
        assertFalse(staking.isTrackedBorrower(alice), "the position closed");
        assertApproxEqAbs(_lhs(), _rhs(), DUST, "identity after the seizure");
        assertTrue(staking.isSolvent(), "solvent after the seizure");
    }
}
