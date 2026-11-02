// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice `totalRewardsPaid` counts what left the contract to a holder, in the transaction that
///         paid it. A withdraw carries the lock sweep (`_autoMaintain`), and the sweep settles every
///         lapsed lock it normalises before it reprices it (`lockStep`), so its payments to other
///         holders land in the same transaction and in the same counter. A withdraw whose counter
///         moves by more than its caller received (1e25 against 5e24 in the report) is that sweep
///         payment: every unit counted as paid is a unit transferred, and each holder receives
///         exactly the quote it read. Green on 82febb5. Red with the settles of `lockStep` deleted:
///         the lapsed windows are repriced unpaid (the mutant registered in mutants.py).
contract RewardsPaidAreTransfersTest is Base {
    uint256 internal constant S = 1_000_000e18;

    function test_EveryRewardCountedAsPaidLeftTheContractInThatTransaction() public {
        vm.prank(admin); staking.fundEmission(10_000_000e18);
        vm.prank(carol); staking.deposit(S, 90);
        vm.prank(alice); staking.deposit(S, 90);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 200 days);   // both locks lapsed 110 days ago, nobody touched them

        uint256 qa = staking.pendingRewards(alice) + staking.pendingPureYield(alice);
        uint256 qc = staking.pendingRewards(carol) + staking.pendingPureYield(carol);
        assertGt(qa, 0, "fixture: alice has a window to settle");
        assertGt(qc, 0, "fixture: carol has a window to settle");
        uint256 paid0 = staking.totalRewardsPaid();
        uint256 pot0  = staking.backing();
        uint256 a0    = token.balanceOf(alice);
        uint256 c0    = token.balanceOf(carol);

        uint256 piece = S / 8;
        vm.prank(carol); staking.withdraw(piece);

        uint256 toAlice = token.balanceOf(alice) - a0;
        uint256 toCarol = token.balanceOf(carol) - c0 - piece;
        assertGt(toAlice, 0, "the sweep in carol's withdraw paid alice");
        assertEq(staking.totalRewardsPaid() - paid0, toAlice + toCarol, "counted as paid == paid to holders");
        assertEq(pot0 - staking.backing(), toAlice + toCarol + piece, "the pot moved by exactly the transfers");
        assertEq(toAlice, qa, "alice received the quote she read");
        assertEq(toCarol, qc, "carol received the quote she read");
    }
}
