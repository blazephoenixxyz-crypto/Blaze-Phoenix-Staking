// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice `maxLockDaysAvailable` answers "the longest lock an action accepts right now". `lock`
///         refuses anything under MIN_LOCK_DAYS and anything that outlasts the emission close, so
///         with fewer than MIN_LOCK_DAYS whole days left no lock is accepted and the view reads 0.
///         Oracle: the lock door in the same block.
///         Red at a24115c: one second inside the final 90 days the view published 89.
contract MaxLockDaysIsZeroInsideTheFinalFloorTest is Base {
    function setUp() public override {
        super.setUp();
        vm.prank(alice);
        staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
    }

    function _lockRefuses(uint256 d, bytes4 sel) internal {
        vm.prank(alice);
        vm.expectRevert(sel);
        staking.lock(d);
    }

    function _assertClosedAt(uint256 t) internal {
        vm.warp(t);
        assertEq(staking.maxLockDaysAvailable(), 0, "a positive maximum no lock can reach");
        _lockRefuses(89, BlazePhoenixStaking.Staking__LockTooShort.selector);
        _lockRefuses(90, BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
    }

    function test_MaxLockDaysIsZeroWhenFewerThanMinLockDaysRemain() public {
        uint256 end = staking.emissionEnd();
        uint256 snap = vm.snapshotState();
        vm.warp(end - 90 days);
        assertEq(staking.maxLockDaysAvailable(), 90, "control: exactly 90 days left");
        vm.prank(alice);
        staking.lock(90);
        vm.revertToState(snap);
        _assertClosedAt(end - 90 days + 1);
        _assertClosedAt(end - 1 days);
        _assertClosedAt(end - 1);
    }

    /// Over the programme's life: m > 0 is a lock the door accepts and m + 1 is refused; m == 0
    /// means the shortest lock the door accepts no longer fits.
    function testFuzz_MaxLockDaysIsALockTheDoorAccepts(uint256 dt) public {
        uint256 end = staking.emissionEnd();
        dt = bound(dt, 0, end - block.timestamp - 1);
        vm.warp(block.timestamp + dt);
        uint256 m = staking.maxLockDaysAvailable();
        if (m == 0) {
            _lockRefuses(89, BlazePhoenixStaking.Staking__LockTooShort.selector);
            _lockRefuses(90, BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
            return;
        }
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        staking.lock(m);
        vm.revertToState(snap);
        _lockRefuses(m + 1, m == staking.MAX_LOCK_DAYS()
            ? BlazePhoenixStaking.Staking__LockTooLong.selector
            : BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
    }
}
