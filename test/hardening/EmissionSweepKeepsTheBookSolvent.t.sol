// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice SWEEP-SOLVENT. Oracle: `sweepUndistributedEmission` sends the emission residue to the
///         treasury only when the book still reads solvent after it, the rule `withdrawReserve`
///         already follows for the other protocol-owned balance.
///         The book: the full programme funded (the 2^-8 tail, 703,125 BZPX, stays in
///         `rewardReserve` after `emissionEnd`), one pure staker, one borrower at the maximum
///         ratio left untouched for 32 years. Carol's interest has outgrown what `totalStaked`
///         holds, so `totalStaked + protocolReserve < totalDebt`; the residue is what still keeps
///         `_owed()` covered.
///         Red at d9b9b16: the sweep went through and left a 28,544e18 deficit on a book that read
///         solvent.
contract EmissionSweepKeepsTheBookSolventTest is Base {
    function _book() internal {
        vm.prank(admin);
        staking.fundEmission(180_000_000e18);
        vm.prank(alice);
        staking.deposit(10_000e18, 90);
        vm.prank(carol);
        staking.deposit(1_000_000e18, 90);
        vm.roll(block.number + 11);
        uint256 maxC = staking.maxBorrowOf(carol);
        vm.prank(carol);
        staking.borrow(maxC);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 32 * 365 days);
    }

    function test_SWEEP_residueThatCoversTheClaimsStaysInThePot() public {
        _book();
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before the sweep");
        uint256 t0 = token.balanceOf(treasury);
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.sweepUndistributedEmission();
        assertEq(token.balanceOf(treasury), t0, "the residue left while the pot needed it");
        assertTrue(staking.isSolvent(), "the book still reads solvent");
    }

    /// The healthy case is unchanged: with no hidden loss the residue is owed to nobody and leaves.
    function test_SWEEP_residueLeavesFromAHealthyBook() public {
        vm.prank(admin);
        staking.fundEmission(180_000_000e18);
        vm.prank(alice);
        staking.deposit(10_000e18, 90);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 17 * 365 days);
        uint256 t0 = token.balanceOf(treasury);
        vm.prank(admin);
        staking.sweepUndistributedEmission();
        assertGt(token.balanceOf(treasury) - t0, 0, "the residue reached the treasury");
        assertTrue(staking.isSolvent(), "the book reads solvent after it");
    }

    /// `withdrawReserve` reads the same post-state. The book: emission funded, a small pure stake,
    /// one borrower at the maximum ratio left untouched for 40 years; a paused lock poke runs the
    /// global accrual without attributing carol. The reserve now exceeds what keeps
    /// `totalStaked + rewardReserve + protocolReserve` above `totalDebt`, so taking all of it
    /// crosses the floor of `_owed()` and opens a breach on a book that read solvent.
    /// Red at 67ba48f: withdrawReserve(max) sent 628,946.65e18 to the treasury and left a
    /// 197,900e18 deficit.
    function test_SWEEP_reserveThatCoversTheClaimsStaysInThePot() public {
        vm.prank(admin);
        staking.fundEmission(50_000_000e18);
        vm.prank(alice);
        staking.deposit(100e18, 90);
        vm.prank(carol);
        staking.deposit(1_000_000e18, 90);
        vm.roll(block.number + 11);
        uint256 maxC = staking.maxBorrowOf(carol);
        vm.prank(carol);
        staking.borrow(maxC);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 40 * 365 days);
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(keeper);
        staking.pause();
        vm.prank(keeper);
        staking.pokeExpiredLock(alice);
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before the withdrawal");
        assertLt(
            staking.totalStaked() + staking.rewardReserve(), staking.totalDebt(),
            "setup: the reserve is what keeps the floor"
        );
        uint256 t0 = token.balanceOf(treasury);
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.withdrawReserve(type(uint256).max);
        assertEq(token.balanceOf(treasury), t0, "the reserve left while the pot needed it");
        assertTrue(staking.isSolvent(), "the book still reads solvent");
    }
}
