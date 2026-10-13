// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice A-18. `withdraw` requires zero debt and charges no penalty, so the real values of the
///         two middle fields of `Withdrawn` are 0 and the net equals the gross. The fields stay in
///         the signature so the event topic indexers already use does not change. Pinned here
///         with the position read back, so a future path that clears debt or charges a penalty
///         on withdraw cannot keep emitting zeros unnoticed.
contract WithdrawnEventValuesTest is Base {
    event Withdrawn(address indexed user, uint256 gross, uint256 debtCleared, uint256 penalty, uint256 net);

    function test_A18_withdrawnEmitsTheRealValues() public {
        vm.prank(alice);
        staking.deposit(1_000e18, 90);
        vm.warp(block.timestamp + 91 days);
        vm.roll(block.number + 11);
        (,uint256 debtBefore,,,,,,,,,,,,) = staking.getUserInfo(alice);
        assertEq(debtBefore, 0, "withdraw is only open to a debt-free position");
        uint256 b0 = token.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(staking));
        emit Withdrawn(alice, 400e18, 0, 0, 400e18);
        vm.prank(alice);
        staking.withdraw(400e18);
        assertGe(token.balanceOf(alice) - b0, 400e18, "the net leaves in full");
    }
}
