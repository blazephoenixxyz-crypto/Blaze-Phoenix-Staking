// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice B-92. The paged registry views take any `limit`; "everything from `offset`" is
///         `type(uint256).max`, and that must page, not overflow `offset + limit`.
contract RegistryViewsMaxLimitTest is Base {
    function _twoLockers() internal {
        vm.prank(alice);
        staking.deposit(1_000e18, 90);
        vm.prank(bob);
        staking.deposit(1_000e18, 90);
    }

    function test_B92_getLockersAcceptsMaxLimit() public {
        _twoLockers();
        (address[] memory all, uint256 total) = staking.getLockers(0, type(uint256).max);
        assertEq(total, 2, "registry size");
        assertEq(all.length, 2, "max limit returns the whole registry");
        (address[] memory tail,) = staking.getLockers(1, type(uint256).max);
        assertEq(tail.length, 1, "max limit from a non-zero offset returns the rest");
        assertEq(tail[0], all[1], "same entry");
    }

    function test_B92_expiredLockScanAcceptsMaxLimit() public {
        _twoLockers();
        vm.warp(block.timestamp + 91 days);
        (address[] memory users,,, uint256 total) = staking.expiredLockScan(0, type(uint256).max);
        assertEq(total, 2, "registry size");
        assertEq(users.length, 2, "both commitments have elapsed");
        (address[] memory tail,,,) = staking.expiredLockScan(1, type(uint256).max);
        assertEq(tail.length, 1, "max limit from a non-zero offset scans the rest");
    }
}
