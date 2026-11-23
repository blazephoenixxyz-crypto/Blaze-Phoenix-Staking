// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice `maxBorrowOf` answers "the largest amount `borrow` would accept right now". `borrow`
///         is closed while paused, in an emergency and under a hard breach (`backing + DUST <
///         owed`), so in each of those regimes the published maximum is 0. Oracle: the borrow door
///         itself, read in the same block, never the view's own arithmetic.
///         Red at a24115c: the three regimes published the LTV room (`stake * MAX_LTV / 100`).
contract MaxBorrowOfIsZeroWhileBorrowIsClosedTest is Base {
    uint256 internal constant DUST = 1e10;
    address internal constant SINK = address(0x5114C);
    uint256 internal pot;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(carol);
        staking.deposit(1_000_000e18, 90);
    }

    function _position(uint256 stake) internal {
        vm.prank(alice);
        staking.deposit(stake, 90);
        vm.roll(block.number + 11);
    }

    /// An external loss of the pot reads the same to `_hardBreach()` as a recorded one.
    function _breach() internal {
        pot = token.balanceOf(address(staking));
        vm.prank(address(staking));
        token.transfer(SINK, pot);
        assertLt(staking.backing() + DUST, staking.owed(), "setup: hard breach");
    }

    function _restore() internal {
        vm.prank(SINK);
        token.transfer(address(staking), pot);
        assertTrue(staking.isSolvent(), "setup: the book is solvent again");
    }

    function _assertClosed(bytes4 sel) internal {
        assertEq(staking.maxBorrowOf(alice), 0, "maxBorrowOf publishes room borrow refuses");
        (, , , uint256 maxAvail, , , , , , , , , , ) = staking.getUserInfo(alice);
        assertEq(maxAvail, 0, "getUserInfo.maxBorrowAvailable publishes room borrow refuses");
        vm.prank(alice);
        vm.expectRevert(sel);
        staking.borrow(1);
    }

    function test_MaxBorrowOfIsZeroWhileBorrowIsClosed_HardBreach() public {
        _position(10_000e18);
        _breach();
        _assertClosed(BlazePhoenixStaking.Staking__InvariantBreached.selector);
    }

    function test_MaxBorrowOfIsZeroWhileBorrowIsClosed_Paused() public {
        _position(10_000e18);
        vm.prank(keeper);
        staking.pause();
        _assertClosed(Pausable.EnforcedPause.selector);
    }

    /// `declareEmergency` also pauses, and `unpause` is closed in an emergency, so the
    /// `whenNotPaused` modifier answers first and the emergency selector is not reachable on
    /// `borrow`; the regime is still closed and the view must say so.
    function test_MaxBorrowOfIsZeroWhileBorrowIsClosed_Emergency() public {
        _position(10_000e18);
        vm.prank(keeper);
        staking.declareEmergency();
        assertTrue(staking.emergencyMode(), "setup: emergency");
        _assertClosed(Pausable.EnforcedPause.selector);
    }

    /// Control: once the door reopens, the published maximum is positive and `borrow` settles it.
    function test_MaxBorrowOfReopensWithTheDoor() public {
        _position(10_000e18);
        _breach();
        assertEq(staking.maxBorrowOf(alice), 0, "closed under the breach");
        _restore();
        vm.prank(keeper);
        staking.pause();
        assertEq(staking.maxBorrowOf(alice), 0, "closed while paused");
        vm.prank(admin);
        staking.unpause();
        uint256 m = staking.maxBorrowOf(alice);
        assertGt(m, 0, "the door is open again");
        vm.prank(alice);
        staking.borrow(m);
        (, uint256 debt, , , , , , , , , , , , ) = staking.getUserInfo(alice);
        assertEq(debt, m, "borrow accepted the published maximum");
    }

    /// Bidirectional over the same block: m > 0 implies borrow(m) is accepted; a closed regime
    /// publishes 0 and refuses borrow(1) with the regime's own selector.
    function testFuzz_MaxBorrowOfIsPositiveOnlyWhereBorrowAcceptsIt(uint256 stake, uint8 regime) public {
        stake = bound(stake, 1e15, 3_000_000e18);
        regime = uint8(bound(regime, 0, 3));
        _position(stake);
        bytes4 sel;
        if (regime == 1) {
            vm.prank(keeper);
            staking.pause();
            sel = Pausable.EnforcedPause.selector;
        } else if (regime == 2) {
            vm.prank(keeper);
            staking.declareEmergency();
            sel = Pausable.EnforcedPause.selector;
        } else if (regime == 3) {
            _breach();
            sel = BlazePhoenixStaking.Staking__InvariantBreached.selector;
        }
        uint256 m = staking.maxBorrowOf(alice);
        if (regime == 0) {
            assertGt(m, 0, "open book, positive stake");
            vm.prank(alice);
            staking.borrow(m);
        } else {
            assertEq(m, 0, "closed regime publishes room");
            vm.prank(alice);
            vm.expectRevert(sel);
            staking.borrow(1);
        }
    }
}
