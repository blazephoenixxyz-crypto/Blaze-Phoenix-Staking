// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice B-14. What the trip records. The breaker stores no ratio: the pro-rata haircut is
///         computed live in `emergencyWithdraw`. What it does store is pinned here, for both the
///         permissionless breaker and the guardian's halt: the flag, the trip time, the pause,
///         and the interest clock charged up to the trip and stopped there.
contract BreakerTripStateTest is Base {
    function _borrowBook() internal {
        vm.prank(alice);
        staking.deposit(1_000_000e18, 90);
        vm.prank(carol);
        staking.deposit(1_000_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(carol);
        staking.borrow(200_000e18);
        vm.warp(block.timestamp + 30 days);
    }

    function _assertTripped() internal view {
        assertTrue(staking.emergencyMode(), "flag");
        assertEq(staking.emergencyTrippedAt(), block.timestamp, "trip time");
        assertTrue(staking.paused(), "the trip also pauses");
        assertEq(staking.lastInterestTime(), block.timestamp, "interest charged up to the trip");
    }

    function test_B14_tripBreakerRecordsTheTrip() public {
        _borrowBook();
        uint256 idx0 = staking.accInterestPerDebt();
        deal(address(token), address(staking), token.balanceOf(address(staking)) - 1_000e18);
        staking.tripBreaker();
        _assertTripped();
        assertGt(staking.accInterestPerDebt(), idx0, "the elapsed slice was charged at the trip");
        uint256 idx1 = staking.accInterestPerDebt();
        vm.warp(block.timestamp + 30 days);
        vm.prank(admin);
        staking.fundEmission(1e18);
        assertEq(staking.accInterestPerDebt(), idx1, "no interest accrues during the emergency");
    }

    function test_B14_declareEmergencyRecordsTheTrip() public {
        _borrowBook();
        uint256 idx0 = staking.accInterestPerDebt();
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(keeper);
        staking.declareEmergency();
        _assertTripped();
        assertGt(staking.accInterestPerDebt(), idx0, "the elapsed slice was charged at the halt");
    }
}
