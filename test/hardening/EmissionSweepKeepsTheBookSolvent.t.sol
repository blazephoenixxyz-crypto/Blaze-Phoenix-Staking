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
        _book(32);
    }

    function _book(uint256 years_) internal {
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
        vm.warp(block.timestamp + years_ * 365 days);
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

    /// A paused lock poke runs the global accrual without attributing anyone (the sweep is off).
    function _freshReadPaused() internal {
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(keeper);
        staking.pause();
        vm.prank(keeper);
        staking.pokeExpiredLock(alice);
    }

    /// The residue alone crosses the floor: the same block's poke has already run the global
    /// accrual, so the book read before the sweep is the fresh one and it is solvent; only the
    /// transfer of the residue opens the breach. A read taken before the residue leaves passes.
    function test_SWEEP_residueIsReadAfterItLeaves() public {
        _book(31);   // the first year in which the residue holds the floor
        _freshReadPaused();
        assertTrue(staking.isSolvent(), "setup: the fresh book reads solvent before the sweep");
        assertLt(
            staking.totalStaked() + staking.protocolReserve(), staking.totalDebt(),
            "setup: the residue is what keeps the floor"
        );
        uint256 t0 = token.balanceOf(treasury);
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.sweepUndistributedEmission();
        assertEq(token.balanceOf(treasury), t0, "the residue left while the pot needed it");
    }

    /// The book: emission funded, a small pure stake, one borrower at the maximum ratio left
    /// untouched for 40 years, then a fresh paused read.
    function _reserveBook() internal {
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
        _freshReadPaused();
    }

    /// `withdrawReserve` reads the same post-state. The reserve now exceeds what keeps
    /// `totalStaked + rewardReserve + protocolReserve` above `totalDebt`, so taking all of it
    /// crosses the floor of `_owed()` and opens a breach on a book that read solvent.
    /// Red at 67ba48f: withdrawReserve(max) sent 628,946.65e18 to the treasury and left a
    /// 197,900e18 deficit.
    function test_SWEEP_reserveThatCoversTheClaimsStaysInThePot() public {
        _reserveBook();
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

    /// The cap is read on the book as of now. 30 days after the last touch, the stale reserve lets
    /// 431,046.65e18 out where the fresh read allows 425,067.20e18; the next touch then books the
    /// elapsed slice and reads a breach. Red at c31b6c5: withdrawReserve(431,046e18) went through
    /// and the next touch left owed − backing = 5,979.45e18.
    function test_SWEEP_reserveIsReadOnTheBookAsOfNow() public {
        _reserveBook();
        vm.warp(block.timestamp + 30 days);
        uint256 t0 = token.balanceOf(treasury);
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.withdrawReserve(431_046e18);
        assertEq(token.balanceOf(treasury), t0, "the stale cap let the reserve out");
        vm.prank(admin);
        staking.withdrawReserve(425_000e18);
        vm.prank(carol);
        staking.repay(1);
        assertTrue(staking.isSolvent(), "the next touch reads the book solvent");
    }
}
