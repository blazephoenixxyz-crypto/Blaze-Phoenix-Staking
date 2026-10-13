// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  GUARD WATCHERS — the two refusal selectors that no other test names
//
//  A census over src/BlazePhoenixStaking.sol (25 refusal selectors, 62
//  `revert Staking__…` sites, measured at cedd80d) found exactly two selectors
//  that no test file mentioned: `Staking__ZeroAddress` (constructor) and
//  `Staking__InsufficientStake` (withdraw). A guard without a watcher is
//  decorative — a green suite does not show that a test can fail. Each test
//  below names its guard, and the paired mutant in .github/scripts/mutants.py
//  shows the test can go red: delete the guard and this test fails.
//
//  Clock reads go through external helpers, the BoundaryEquality idiom: a local
//  copy of block.timestamp taken before vm.warp can be re-read after it under
//  via_ir (commit d080649), which silently falsifies a fixture.
// =============================================================================

import {Base} from "./BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract GuardWatchersTest is Base {
    function clockTs() external view returns (uint256) { return block.timestamp; }
    function clockBlock() external view returns (uint256) { return block.number; }

    /// The constructor refuses a zero token or a zero treasury, with its own selector.
    function test_ConstructorRefusesZeroAddresses_WithItsSelector() public {
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAddress.selector);
        new BlazePhoenixStaking(address(0), treasury);

        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAddress.selector);
        new BlazePhoenixStaking(address(token), address(0));
    }

    /// A withdraw above the position's own stake is refused with its selector — not a panic.
    function test_WithdrawAboveTheStakeIsRefused_WithItsSelector() public {
        uint256 t0 = this.clockTs();
        uint256 n0 = this.clockBlock();
        vm.prank(alice); staking.deposit(1_000e18, 90);
        vm.warp(t0 + 90 days);      // the lock is over: the stake check is the one left
        vm.roll(n0 + 11);           // past depositBlock + MIN_DEPOSIT_BLOCKS (10)
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__InsufficientStake.selector);
        staking.withdraw(1_000e18 + 1);
    }
}
