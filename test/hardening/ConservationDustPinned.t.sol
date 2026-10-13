// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice C-55. `CONSERVATION_DUST` (1e10 wei) is the only tolerance between the balance and
///         what the book owes. Raising it to 1e14 left every test green, so nothing watched it.
///         Pinned at the solvency edge in both directions: a gap of exactly the dust is solvent,
///         one wei more is a breach the permissionless breaker accepts.
contract ConservationDustPinnedTest is Base {
    uint256 internal constant DUST = 1e10;

    function _book() internal returns (uint256 owed) {
        vm.prank(alice);
        staking.deposit(1_000e18, 90);
        vm.prank(bob);
        staking.deposit(1_000e18, 90);
        owed = staking.owed();
        assertGe(token.balanceOf(address(staking)), owed, "setup: a healthy book");
    }

    function test_C55_aGapOfExactlyTheDustIsSolvent() public {
        uint256 owed = _book();
        deal(address(token), address(staking), owed - DUST);
        assertTrue(staking.isSolvent(), "balance + dust == owed is solvent");
        vm.expectRevert();
        staking.tripBreaker();
    }

    function test_C55_oneWeiPastTheDustIsABreach() public {
        uint256 owed = _book();
        deal(address(token), address(staking), owed - DUST - 1);
        assertFalse(staking.isSolvent(), "balance + dust < owed is a breach");
        staking.tripBreaker();
        assertTrue(staking.emergencyMode(), "the breaker accepts it");
    }
}
