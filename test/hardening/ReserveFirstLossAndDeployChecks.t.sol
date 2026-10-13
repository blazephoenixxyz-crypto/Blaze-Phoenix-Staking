// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice Loss ordering when a borrower's interest outgrows its stake, and the constructor's
///         token check.
///
///         Property (one rule for every path that realises a loss): the protocol reserve is
///         consumed before anything is booked as `totalBadDebt`. `_executeLiquidation` and
///         `emergencyWithdraw` already did this; the lazy interest attribution
///         (`_accrueInterestFor`, the uncollectible-interest branch) booked the whole shortfall
///         as bad debt and left the reserve untouched. Oracle: right after the loss is realised,
///         `totalBadDebt == 0 || protocolReserve == 0`.
contract ReserveFirstLossTest is Base {
    uint256 internal constant STAKE = 1_000_000e18;

    function _borrowMax(address who) internal returns (uint256 b) {
        b = staking.maxBorrowOf(who);
        vm.prank(who);
        staking.borrow(b);
    }

    /// Only borrowers: with no pure-staker weight the whole interest slice lands in the
    /// protocol reserve. Different loan-to-value ratios make the index clamp charge carol more
    /// than her stake (bob, at half her ratio, less than his), so the uncollectible branch runs
    /// with a reserve that holds the entire clamped slice. Nothing may be booked as bad debt.
    function test_reserveAbsorbsUncollectibleInterestBeforeBadDebt() public {
        vm.prank(bob);
        staking.deposit(STAKE, 90);
        vm.prank(carol);
        staking.deposit(STAKE, 90);
        vm.roll(block.number + 11);
        uint256 half = staking.maxBorrowOf(bob) / 2;
        vm.prank(bob);
        staking.borrow(half);
        _borrowMax(carol);
        vm.roll(block.number + 11);

        vm.warp(block.timestamp + 1000 * 365 days);
        vm.prank(keeper);
        staking.claimRewards();   // neutral touch: the borrower window reaches the positions

        emit log_named_decimal_uint("totalUncollectedInterest", staking.totalUncollectedInterest(), 18);
        emit log_named_decimal_uint("protocolReserve         ", staking.protocolReserve(), 18);
        emit log_named_decimal_uint("totalBadDebt            ", staking.totalBadDebt(), 18);
        assertGt(staking.totalUncollectedInterest(), 0, "setup: the uncollectible branch must run");
        assertEq(staking.totalBadDebt(), 0, "the reserve covers the shortfall before bad debt is booked");
    }

    /// Mixed book (pure stakers take most of the slice): the reserve may not cover the whole
    /// shortfall, but it must be exhausted before any bad debt exists. Regression guard only:
    /// here the maintenance liquidation that follows in the same transaction also drains the
    /// reserve, so this ordering held before the fix too (the red proof is the test above).
    function test_badDebtOnlyOnceReserveIsExhausted() public {
        vm.prank(alice);
        staking.deposit(STAKE, 90);
        vm.prank(bob);
        staking.deposit(STAKE, 90);
        vm.prank(carol);
        staking.deposit(STAKE, 90);
        vm.roll(block.number + 11);
        _borrowMax(carol);
        vm.roll(block.number + 11);

        vm.warp(block.timestamp + 1000 * 365 days);
        vm.prank(keeper);
        staking.claimRewards();

        uint256 bad = staking.totalBadDebt();
        uint256 pr = staking.protocolReserve();
        emit log_named_decimal_uint("totalBadDebt   ", bad, 18);
        emit log_named_decimal_uint("protocolReserve", pr, 18);
        assertGt(staking.totalUncollectedInterest(), 0, "setup: the uncollectible branch must run");
        assertTrue(bad == 0 || pr == 0, "bad debt booked while the protocol reserve still holds funds");
    }

    /// Fuzzed horizon and bob's ratio: the ordering holds whenever the uncollectible branch
    /// runs, and with no pure staker (the whole slice in the reserve) no bad debt is booked.
    /// The touch is a direct liquidation of the over-water position: a neutral touch can seize
    /// bob before carol's shortfall is restored, which reverts in the clamp regime
    /// (test/hardening/TerminalDistressOrdering.t.sol documents that separately).
    function testFuzz_reserveFirstOrdering(uint32 yearsAhead, uint16 bobBps, bool withPure) public {
        uint256 y = bound(uint256(yearsAhead), 50, 2000);
        uint256 bps = bound(uint256(bobBps), 1, 9_000);
        if (withPure) {
            vm.prank(alice);
            staking.deposit(STAKE, 90);
        }
        vm.prank(bob);
        staking.deposit(STAKE, 90);
        vm.prank(carol);
        staking.deposit(STAKE, 90);
        vm.roll(block.number + 11);
        uint256 bobBorrow = staking.maxBorrowOf(bob) * bps / 10_000;
        if (!withPure && bobBorrow > 0) {
            vm.prank(bob);
            staking.borrow(bobBorrow);
        }
        _borrowMax(carol);
        vm.roll(block.number + 11);

        vm.warp(block.timestamp + y * 365 days);
        vm.prank(keeper);
        try staking.liquidate(carol) {} catch (bytes memory err) {
            // only "not liquidatable" is an acceptable refusal here
            assertEq(bytes4(err), BlazePhoenixStaking.Staking__NotLiquidatable.selector, "unexpected revert");
            return;
        }

        if (staking.totalUncollectedInterest() == 0) return;
        if (!withPure) assertEq(staking.totalBadDebt(), 0, "reserve held the whole slice");
        assertTrue(
            staking.totalBadDebt() == 0 || staking.protocolReserve() == 0,
            "bad debt booked while the protocol reserve still holds funds"
        );
    }
}

contract ConstructorTokenCheckTest is Base {
    function test_rejectsTokenWithoutCode() public {
        vm.expectRevert(BlazePhoenixStaking.Staking__TokenHasNoCode.selector);
        new BlazePhoenixStaking(address(0xB0B0), treasury);
    }

    function test_zeroAddressStillRejectedFirst() public {
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAddress.selector);
        new BlazePhoenixStaking(address(0), treasury);
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAddress.selector);
        new BlazePhoenixStaking(address(token), address(0));
    }

    function test_acceptsTokenWithCode() public {
        BlazePhoenixStaking s = new BlazePhoenixStaking(address(token), treasury);
        assertEq(s.bzpx(), address(token));
    }
}
