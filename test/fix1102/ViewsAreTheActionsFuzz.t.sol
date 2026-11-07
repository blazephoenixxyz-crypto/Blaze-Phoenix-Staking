// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice The three published limits are the actions they describe, on fuzzed books.
///         maxBorrowOf is the largest amount borrow accepts (one wei more is refused);
///         daysToLiquidation and healthFactor say when liquidate starts to accept; and
///         maxLockDaysAvailable is the longest lock that still ends inside the emission
///         programme. The book: alice is a debt-free locker, carol the only borrower, at a
///         fuzzed fraction of her LTV, so interest moves her stake between the borrow and the
///         reading. With one borrower the LTV side of maxBorrowOf always binds: the utilisation
///         room (0.75 of the book minus the debt) exceeds the LTV room (half the net stake
///         minus the debt) by more than a quarter of her stake.
///         Green on 82febb5 and here. Red with the mutants registered in mutants.py.
contract ViewsAreTheActionsFuzzTest is Base {
    /// The health reading at the liquidation threshold: (stake - debt) / stake = 5%.
    uint256 internal constant LIQ_H = 5e16;

    function _book(uint256 a, uint256 lockA, uint256 c, uint256 borrowBps) internal returns (uint256 debt) {
        vm.prank(admin); staking.fundEmission(90_000_000e18);
        vm.prank(alice); staking.deposit(a, lockA);
        vm.prank(carol); staking.deposit(c, 90);
        debt = (c * 50 / 100) * borrowBps / 10_000;
        if (debt > 0) { vm.prank(carol); staking.borrow(debt); }
    }

    function _debtOf(address who) internal view returns (uint256 d) {
        (, d, , , , , , , , , , , , ) = staking.getUserInfo(who);
    }

    /// maxBorrowOf is the room borrow enforces, after the interest the borrow itself accrues:
    /// borrowing the quote settles and leaves no room, one wei more is refused at the LTV check.
    function testFuzz_MaxBorrowOfIsWhatBorrowAccepts_OneWeiMoreIsRefused(
        uint256 a, uint256 lockA, uint256 c, uint256 borrowBps, uint256 dt
    ) public {
        a         = bound(a, 1_000e18, 20_000_000e18);
        lockA     = bound(lockA, 90, 2555);
        c         = bound(c, 1_000e18, 20_000_000e18);
        borrowBps = bound(borrowBps, 0, 10_000);
        dt        = bound(dt, 0, 30 * 365 days);
        uint256 t0 = this.clockTs();
        _book(a, lockA, c, borrowBps);
        vm.warp(t0 + dt); vm.roll(block.number + 11);

        uint256 m  = staking.maxBorrowOf(carol);
        uint256 d0 = _debtOf(carol);
        uint256 snap = vm.snapshotState();
        if (m > 0) {
            vm.prank(carol); staking.borrow(m);
            assertEq(this.debtOf(carol), d0 + m, "borrow(maxBorrowOf) settled the quote");
            assertEq(this.maxBorrow(carol), 0, "the quote was the whole room");
            vm.revertToState(snap);
        }
        vm.prank(carol);
        vm.expectRevert(BlazePhoenixStaking.Staking__LTVExceeded.selector);
        staking.borrow(m + 1);
    }

    /// daysToLiquidation, read right after the borrow, is when liquidate starts to accept: two
    /// days before it liquidate refuses and the readings say one or two days at a health above
    /// the threshold; two days after it liquidate settles and the readings say zero days at a
    /// health at or below the threshold. Nobody touches the book in between, so the rate the
    /// estimate prices is the rate the index charges.
    function testFuzz_DaysToLiquidationIsWhenLiquidateStartsToAccept(
        uint256 a, uint256 lockA, uint256 c, uint256 borrowBps
    ) public {
        a         = bound(a, 1_000e18, 20_000_000e18);
        lockA     = bound(lockA, 90, 2555);
        c         = bound(c, 1_000e18, 20_000_000e18);
        borrowBps = bound(borrowBps, 2_000, 10_000);
        _book(a, lockA, c, borrowBps);
        uint256 dStar = staking.daysToLiquidation(carol);
        assertGt(dStar, 2, "fixture: the estimate is days away");
        assertLt(dStar, type(uint256).max, "fixture: the debt is charged");
        uint256 t1 = this.clockTs();
        uint256 n1 = this.clockBlock();
        uint256 snap = vm.snapshotState();

        vm.warp(t1 + (dStar - 2) * 1 days); vm.roll(n1 + 1);
        uint256 left = staking.daysToLiquidation(carol);
        assertGe(left, 1, "two days early: the estimate still reads at least a day");
        assertLe(left, 2, "two days early: the estimate reads at most two days");
        assertGe(staking.healthFactor(carol), LIQ_H, "two days early: the health is above the threshold");
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NotLiquidatable.selector);
        staking.liquidate(carol);
        vm.revertToState(snap);

        vm.warp(t1 + (dStar + 2) * 1 days); vm.roll(n1 + 1);
        assertEq(staking.daysToLiquidation(carol), 0, "two days late: the estimate reads zero");
        assertLe(staking.healthFactor(carol), LIQ_H, "two days late: the health is at or below the threshold");
        uint256 liq0 = staking.totalLiquidations();
        vm.prank(keeper); staking.liquidate(carol);
        assertEq(staking.totalLiquidations(), liq0 + 1, "two days late: liquidate settled");
    }

    /// maxLockDaysAvailable is the longest lock that ends inside the emission programme: a deposit
    /// that commits to it settles with an unlock no later than the close, and one day more is refused
    /// because it would outlast the close. After the close no lock opens.
    function testFuzz_MaxLockDaysIsTheLongestLockInsideTheProgramme(uint256 dt) public {
        uint256 end = staking.emissionEnd();
        uint256 t0 = this.clockTs();
        dt = bound(dt, 0, end - t0 + 30 days);
        vm.warp(t0 + dt); vm.roll(block.number + 1);
        uint256 nowTs = this.clockTs();
        uint256 maxD = staking.maxLockDaysAvailable();

        if (nowTs >= end) {
            assertEq(maxD, 0, "after the close no lock is available");
            vm.prank(bob);
            vm.expectRevert(BlazePhoenixStaking.Staking__EmissionEnded.selector);
            staking.deposit(1_000e18, 90);
            return;
        }
        assertLe(nowTs + maxD * 1 days, end, "the longest lock ends inside the programme");
        if (maxD < 2555) assertGt(nowTs + (maxD + 1) * 1 days, end, "one day more would outlast the close");

        if (maxD >= 90) {
            uint256 snap = vm.snapshotState();
            vm.prank(bob); staking.deposit(1_000e18, maxD);
            assertLe(this.unlockOf(bob), end, "the deposit at the longest lock unlocks by the close");
            vm.revertToState(snap);
        }
        if (maxD < 2555 && maxD + 1 >= 90) {
            vm.prank(bob);
            vm.expectRevert(BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
            staking.deposit(1_000e18, maxD + 1);
        }
    }

    // Second reads go through external helpers: via_ir may re-read TIMESTAMP/NUMBER for a local
    // after vm.warp/vm.roll, and an external call's result cannot be rematerialised.
    function debtOf(address who) external view returns (uint256) { return _debtOf(who); }
    function maxBorrow(address who) external view returns (uint256) { return staking.maxBorrowOf(who); }
    function unlockOf(address who) external view returns (uint256 t) {
        (, , , , , , , , , , t, , , ) = staking.getUserInfo(who);
    }
    function clockTs() external view returns (uint256) { return block.timestamp; }
    function clockBlock() external view returns (uint256) { return block.number; }
}
