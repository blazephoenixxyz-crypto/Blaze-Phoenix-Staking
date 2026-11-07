// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice An emergency exit pays net equity and forfeits unpaid emission and pure yield
///         (docs/KNOWN_ISSUES.md). The forfeit does not move to a reserve: it stays in what the
///         contract has distributed and not paid (`totalRewardDistributed - totalRewardsPaid`, a
///         term of `owed()`) with no position left to claim it, and `sweepUndistributedEmission`
///         reaches only `rewardReserve`. The exit moves `backing()` and `owed()` by the same amount,
///         so the identity is untouched and `owed()` reads high by the forfeits, never low.
///         Green on 82febb5 and here. Red with the mutant registered in mutants.py (the exit
///         settles its emission before it closes).
contract EmergencyForfeitStaysOwedTest is Base {
    uint256 internal constant DUST = 1e10;      // CONSERVATION_DUST

    function _pd() internal view returns (uint256) {
        return staking.totalRewardDistributed() - staking.totalRewardsPaid();
    }

    function _gap() internal view returns (int256) {
        return int256(staking.backing()) - int256(staking.owed());
    }

    function _unpaid(address who) internal view returns (uint256) {
        return staking.pendingRewards(who) + staking.pendingPureYield(who);
    }

    /// Three debt-free positions at the halt, each with unpaid emission, two with unpaid pure
    /// yield (carol borrowed for 100 days, then repaid). Every one of them exits.
    function test_FORFEIT_documents_anEmergencyExitsForfeitStaysOwedWithNoHolder() public {
        vm.prank(admin); staking.fundEmission(90_000_000e18);
        vm.prank(alice); staking.deposit(1_000_000e18, 2555);
        vm.prank(bob);   staking.deposit(2_000_000e18, 365);
        vm.prank(carol); staking.deposit(4_000_000e18, 365);
        vm.roll(block.number + 20);
        vm.prank(carol); staking.borrow(1_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 100 days); vm.roll(block.number + 1);
        vm.prank(carol); staking.repay(type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 20 days); vm.roll(block.number + 1);

        uint256 forfeit = _unpaid(alice) + _unpaid(bob) + _unpaid(carol);
        assertGt(staking.pendingPureYield(alice), 0, "fixture: pure yield is unpaid too");
        assertEq(staking.totalDebt(), 0, "fixture: the book is debt-free at the halt");

        vm.prank(admin); staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(keeper); staking.declareEmergency();
        uint256 pd0 = _pd();
        int256 gap0 = _gap();

        (uint256 sa, , , , , , , , , , , , , ) = staking.getUserInfo(alice);
        uint256 a0 = token.balanceOf(alice);
        vm.prank(alice); staking.emergencyWithdraw();
        assertEq(token.balanceOf(alice) - a0, sa, "the exit pays the net equity and nothing else");
        assertEq(_pd(), pd0, "the forfeit stays counted as distributed and unpaid");
        assertEq(_gap(), gap0, "backing and owed move by the same amount");

        vm.prank(bob);   staking.emergencyWithdraw();
        vm.prank(carol); staking.emergencyWithdraw();
        assertEq(staking.totalBoostedEffective(), 0, "no position is left to claim it");
        assertEq(_gap(), gap0, "after every exit");
        assertApproxEqAbs(_pd(), forfeit, DUST, "what stays owed with no holder is the forfeits");
        emit log_named_decimal_uint("forfeit owed with no holder (BZPX)", _pd(), 18);
    }
}
