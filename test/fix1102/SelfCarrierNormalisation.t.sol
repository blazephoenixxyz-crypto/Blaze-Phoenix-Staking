// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice BP-2026-008. The position that carries the maintenance traffic is normalised by that
///         traffic too: the lock window of the sweep does not skip its beneficiary, so a holder
///         cannot keep an expired boost alive by driving every transaction itself. No third-party
///         transaction appears in the fixture: the carrier's own pokes are the only traffic.
///         Red with the lock-window self-exclusion restored (the code before 0f27236; the
///         mutant registered in mutants.py). A borrowing carrier too: the lock window acts on a
///         borrower only once this transaction attributed it (its `interestIndex` at the current
///         index: LOSS-FIRST), and the carrier's own attribution comes first in its sweep. Red
///         with that attribution removed (registered in mutants.py).
contract SelfCarrierNormalisationTest is Base {
    function test_TheCarrierOfTheSweepIsNormalisedByItsOwnTraffic() public {
        _carrierDrivesItsOwnTraffic(false);
    }

    function test_TheBorrowingCarrierOfTheSweepIsNormalisedByItsOwnTraffic() public {
        _carrierDrivesItsOwnTraffic(true);
    }

    function _carrierDrivesItsOwnTraffic(bool borrows) internal {
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        address[5] memory o = [address(0x51), address(0x52), address(0x53), address(0x54), address(0x55)];
        for (uint256 i = 0; i < 5; i++) {
            token.mint(o[i], 10_000e18);
            vm.prank(o[i]); token.approve(address(staking), type(uint256).max);
            vm.prank(o[i]); staking.deposit(10_000e18, 730);
        }
        vm.roll(block.number + 11);
        if (borrows) { vm.prank(alice); staking.borrow(1_000e18); }
        vm.warp(block.timestamp + 731 days);
        assertTrue(staking.hasStaleBoost(alice), "fixture: the carrier's lock has lapsed");
        assertTrue(staking.isTrackedLocker(alice), "fixture: the carrier is registered");
        // Alice drives every transaction, always naming somebody else.
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(block.number + 1);
            if (staking.isTrackedLocker(o[i])) { vm.prank(alice); staking.pokeExpiredLock(o[i]); }
        }
        assertFalse(staking.hasStaleBoost(alice), "the carrier kept its lapsed boost through its own maintenance");
        assertFalse(staking.isTrackedLocker(alice), "the carrier is still registered");
    }
}
