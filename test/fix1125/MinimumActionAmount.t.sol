// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice `deposit` and `borrow` refuse an amount below 1,000 BZPX (`MIN_ACTION_AMOUNT`), for a
///         new position and for an addition to an existing one alike; `repay` and `withdraw`
///         carry no minimum, because they close positions. `maxBorrowOf` publishes 0 while the
///         room is below the minimum, so the published maximum stays an amount `borrow` accepts.
///         Every bound is written here as the literal `1_000e18`, never read from the contract:
///         a test that reads the constant moves with it.
///         Red at 9958d5f: deposits and borrows of 999 BZPX and of `1_000e18 - 1` settled, and
///         `maxBorrowOf` published a room of 999.5 BZPX. The refusal selector and the getter are
///         spelled out below (not taken from the contract type) so that this file compiles, and
///         fails by assertion, on the tree without the guard.
contract MinimumActionAmountTest is Base {
    uint256 internal constant MIN = 1_000e18;
    bytes4  internal constant BELOW_MINIMUM = bytes4(keccak256("Staking__BelowMinimum()"));

    function _stakeOf(address who) internal view returns (uint256 s) {
        (s, , , , , , , , , , , , , ) = staking.getUserInfo(who);
    }

    function _debtOf(address who) internal view returns (uint256 d) {
        (, d, , , , , , , , , , , , ) = staking.getUserInfo(who);
    }

    function _maxAvail(address who) internal view returns (uint256 m) {
        (, , , m, , , , , , , , , , ) = staking.getUserInfo(who);
    }

    // ── the constant ────────────────────────────────────────────────────────────────────────

    /// The published minimum, as a literal. A low-level read, so the test is red (not a compile
    /// error) on a tree that has no such getter.
    function test_MinimumActionAmountIsOneThousandTokens() public view {
        (bool ok, bytes memory ret) = address(staking).staticcall(abi.encodeWithSignature("MIN_ACTION_AMOUNT()"));
        assertTrue(ok, "MIN_ACTION_AMOUNT() is a public getter");
        assertEq(abi.decode(ret, (uint256)), 1_000e18, "the minimum is 1,000 tokens of 18 decimals");
    }

    // ── deposit: a new stake ────────────────────────────────────────────────────────────────

    function test_NewStakeOf999TokensIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(BELOW_MINIMUM);
        staking.deposit(999e18, 90);
        assertEq(_stakeOf(alice), 0, "nothing was staked");
    }

    function test_NewStakeOneWeiBelowTheMinimumIsRefused_TheMinimumSettles_OneWeiMoreSettles() public {
        vm.prank(alice);
        vm.expectRevert(BELOW_MINIMUM);
        staking.deposit(1_000e18 - 1, 90);

        vm.prank(alice);
        staking.deposit(1_000e18, 90);
        assertEq(_stakeOf(alice), 1_000e18, "exactly the minimum was staked");

        vm.prank(bob);
        staking.deposit(1_000e18 + 1, 90);
        assertEq(_stakeOf(bob), 1_000e18 + 1, "one wei above the minimum was staked");
    }

    // ── deposit: adding to an existing stake ────────────────────────────────────────────────

    /// The minimum is on the amount of the call, not on the resulting balance: a wallet already
    /// far above 1,000 BZPX is still refused a smaller addition.
    function test_TopUpBelowTheMinimumIsRefused_TopUpOfTheMinimumSettles_OneWeiMoreSettles() public {
        vm.startPrank(alice);
        staking.deposit(5_000e18, 90);

        vm.expectRevert(BELOW_MINIMUM);
        staking.deposit(999e18, 90);
        vm.expectRevert(BELOW_MINIMUM);
        staking.deposit(1_000e18 - 1, 90);
        assertEq(_stakeOf(alice), 5_000e18, "the refused additions left the stake alone");

        staking.deposit(1_000e18, 90);
        assertEq(_stakeOf(alice), 6_000e18, "an addition of exactly the minimum settled");
        staking.deposit(1_000e18 + 1, 90);
        assertEq(_stakeOf(alice), 7_000e18 + 1, "an addition one wei above the minimum settled");
        vm.stopPrank();
    }

    /// Every amount below the minimum is refused and every amount from it up settles, on an
    /// empty wallet and on a funded one.
    function testFuzz_DepositSettlesExactlyFromTheMinimumUp(uint256 amount, bool topUp) public {
        amount = bound(amount, 1, 3_000e18);
        uint256 before = 0;
        if (topUp) {
            before = 25_000e18;
            vm.prank(alice);
            staking.deposit(before, 365);
        }
        vm.prank(alice);
        if (amount < 1_000e18) {
            vm.expectRevert(BELOW_MINIMUM);
            staking.deposit(amount, 90);
            assertEq(_stakeOf(alice), before, "a refused deposit moved the stake");
        } else {
            staking.deposit(amount, 90);
            assertEq(_stakeOf(alice), before + amount, "an accepted deposit was not booked whole");
        }
    }

    // ── deposit: the minimum against the per-wallet cap ─────────────────────────────────────

    /// A wallet whose distance to MAX_STAKE_PER_WALLET (30,000,000 BZPX) is below the minimum
    /// cannot add to its stake at all: the remainder is refused as below the minimum, and the
    /// minimum is refused as above the cap. `remainingStakeCapacity` still reads the distance.
    function test_AWalletLessThanTheMinimumBelowItsCapCannotTopUp() public {
        uint256 slack = 1_000e18 - 1;
        vm.startPrank(alice);
        staking.deposit(30_000_000e18 - slack, 90);
        assertEq(staking.remainingStakeCapacity(alice), slack, "setup: the distance to the cap");

        vm.expectRevert(BELOW_MINIMUM);
        staking.deposit(slack, 90);
        vm.expectRevert(BlazePhoenixStaking.Staking__CapExceeded.selector);
        staking.deposit(1_000e18, 90);
        vm.stopPrank();
        assertEq(_stakeOf(alice), 30_000_000e18 - slack, "the stake did not move");
    }

    /// Control: with exactly the minimum left under the cap, the last addition settles and the
    /// wallet holds the cap.
    function test_AWalletExactlyTheMinimumBelowItsCapTopsUpToTheCap() public {
        vm.startPrank(alice);
        staking.deposit(30_000_000e18 - 1_000e18, 90);
        staking.deposit(1_000e18, 90);
        vm.stopPrank();
        assertEq(_stakeOf(alice), 30_000_000e18, "the wallet holds the cap");
        assertEq(staking.remainingStakeCapacity(alice), 0, "no distance left");
    }

    // ── borrow: the first borrow ────────────────────────────────────────────────────────────

    /// The stake leaves an LTV room of 5,000 BZPX and the book sits below the utilisation cap,
    /// so the minimum is the only guard that can answer.
    function test_FirstBorrowOneWeiBelowTheMinimumIsRefused_TheMinimumSettles() public {
        vm.startPrank(alice);
        staking.deposit(10_000e18, 90);

        vm.expectRevert(BELOW_MINIMUM);
        staking.borrow(999e18);
        vm.expectRevert(BELOW_MINIMUM);
        staking.borrow(1_000e18 - 1);
        assertEq(_debtOf(alice), 0, "the refused borrows opened no debt");

        uint256 balBefore = token.balanceOf(alice);
        staking.borrow(1_000e18);
        vm.stopPrank();
        assertEq(_debtOf(alice), 1_000e18, "exactly the minimum was borrowed");
        assertEq(token.balanceOf(alice) - balBefore, 1_000e18, "and paid out");
    }

    function test_FirstBorrowOneWeiAboveTheMinimumSettles() public {
        vm.startPrank(alice);
        staking.deposit(10_000e18, 90);
        staking.borrow(1_000e18 + 1);
        vm.stopPrank();
        assertEq(_debtOf(alice), 1_000e18 + 1, "one wei above the minimum was borrowed");
    }

    // ── borrow: adding to an open debt ──────────────────────────────────────────────────────

    /// The minimum is on the amount of the call, not on the resulting debt: a position that
    /// already owes more than 1,000 BZPX is still refused a smaller addition. After the first
    /// borrow the net stake is 9,000 BZPX, so the LTV room is 4,500 in total and 3,500 remain.
    function test_AdditionalBorrowBelowTheMinimumIsRefused_TheMinimumSettles_OneWeiMoreSettles() public {
        vm.startPrank(alice);
        staking.deposit(10_000e18, 90);
        staking.borrow(1_000e18);

        vm.expectRevert(BELOW_MINIMUM);
        staking.borrow(999e18);
        vm.expectRevert(BELOW_MINIMUM);
        staking.borrow(1_000e18 - 1);
        assertEq(_debtOf(alice), 1_000e18, "the refused additions left the debt alone");

        staking.borrow(1_000e18);
        assertEq(_debtOf(alice), 2_000e18, "an addition of exactly the minimum settled");
        staking.borrow(1_000e18 + 1);
        assertEq(_debtOf(alice), 3_000e18 + 1, "an addition one wei above the minimum settled");
        vm.stopPrank();
    }

    /// Every amount below the minimum is refused and every amount from it up to the room
    /// settles, as a first borrow (room 5,000 BZPX) and as an addition (room 3,500 BZPX).
    function testFuzz_BorrowSettlesExactlyFromTheMinimumUp(uint256 amount, bool additional) public {
        uint256 debtBefore = 0;
        vm.startPrank(alice);
        staking.deposit(10_000e18, 90);
        if (additional) {
            debtBefore = 1_000e18;
            staking.borrow(debtBefore);
        }
        amount = bound(amount, 1, additional ? 3_500e18 : 5_000e18);
        if (amount < 1_000e18) {
            vm.expectRevert(BELOW_MINIMUM);
            staking.borrow(amount);
            assertEq(_debtOf(alice), debtBefore, "a refused borrow moved the debt");
        } else {
            staking.borrow(amount);
            assertEq(_debtOf(alice), debtBefore + amount, "an accepted borrow was not booked whole");
        }
        vm.stopPrank();
    }

    // ── the published maximum against the minimum ───────────────────────────────────────────

    /// A net stake of 2,000 BZPX minus two wei leaves an LTV room of `1_000e18 - 1`: `borrow`
    /// accepts no amount there (the room is refused as below the minimum, the minimum as above
    /// the LTV cap), so both views publish 0.
    function test_MaxBorrowOfIsZeroWhileTheRoomIsOneWeiBelowTheMinimum() public {
        vm.startPrank(alice);
        staking.deposit(2_000e18 - 2, 90);
        assertEq(staking.maxBorrowOf(alice), 0, "maxBorrowOf publishes room borrow refuses");
        assertEq(_maxAvail(alice), 0, "getUserInfo.maxBorrowAvailable publishes room borrow refuses");

        vm.expectRevert(BELOW_MINIMUM);
        staking.borrow(1_000e18 - 1);
        vm.expectRevert(BlazePhoenixStaking.Staking__LTVExceeded.selector);
        staking.borrow(1_000e18);
        vm.stopPrank();
    }

    /// With a room of exactly the minimum the views publish it and `borrow` settles it.
    function test_MaxBorrowOfPublishesARoomOfExactlyTheMinimum_AndBorrowSettlesIt() public {
        vm.startPrank(alice);
        staking.deposit(2_000e18, 90);
        assertEq(staking.maxBorrowOf(alice), 1_000e18, "a room of exactly the minimum is published");
        assertEq(_maxAvail(alice), 1_000e18, "getUserInfo.maxBorrowAvailable agrees");
        staking.borrow(1_000e18);
        vm.stopPrank();
        assertEq(_debtOf(alice), 1_000e18, "borrow accepted the published maximum");
        assertEq(staking.maxBorrowOf(alice), 0, "no room left");
    }

    /// Over stakes either side of 2,000 BZPX: a positive published maximum is at least the
    /// minimum and `borrow` settles it; a published 0 means `borrow` refuses the minimum itself.
    function testFuzz_MaxBorrowOfIsZeroOrAnAmountBorrowAccepts(uint256 stake) public {
        stake = bound(stake, 1_000e18, 4_000e18);
        vm.startPrank(alice);
        staking.deposit(stake, 90);
        uint256 m = staking.maxBorrowOf(alice);
        if (stake / 2 < 1_000e18) {
            assertEq(m, 0, "a room below the minimum was published");
            vm.expectRevert(BlazePhoenixStaking.Staking__LTVExceeded.selector);
            staking.borrow(1_000e18);
        } else {
            assertEq(m, stake / 2, "the LTV room was not published whole");
            staking.borrow(m);
            assertEq(_debtOf(alice), m, "borrow refused the published maximum");
        }
        vm.stopPrank();
    }

    // ── the exits carry no minimum ──────────────────────────────────────────────────────────

    /// Control, green before and after: `repay` and `withdraw` settle one wei. A minimum there
    /// would hold funds in a position that can no longer be reduced.
    function test_RepayAndWithdrawOfOneWeiStillSettle() public {
        vm.startPrank(alice);
        staking.deposit(10_000e18, 90);
        staking.borrow(1_000e18);

        staking.repay(1);
        assertEq(_debtOf(alice), 1_000e18 - 1, "repay of one wei settled");
        staking.repay(type(uint256).max);
        assertEq(_debtOf(alice), 0, "the debt is closed");

        vm.warp(block.timestamp + 91 days);
        vm.roll(block.number + 11);
        uint256 stakeBefore = _stakeOf(alice);
        staking.withdraw(1);
        assertEq(_stakeOf(alice), stakeBefore - 1, "withdraw of one wei settled");
        staking.withdraw(stakeBefore - 1);
        vm.stopPrank();
        assertEq(_stakeOf(alice), 0, "the position is closed");
    }
}
