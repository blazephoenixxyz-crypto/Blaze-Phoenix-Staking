// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice LOSS-FIRST. Oracle: within one transaction every loss is booked before anything leaves
///         at par, so the gate that lets a payment out reads the pot after them. The maintenance
///         sweep a transaction carries books OTHER positions' losses (attribution, seizure); it
///         runs before the caller's payments, not after them.
///         Red at c31b6c5: the sweep ran last. A pure staker's claim was paid 1,098,719.56e18 at
///         par and the same transaction's sweep then seized a borrower for 162.53e18 of bad debt,
///         leaving a hard breach on a book that had read solvent.
contract MaintenanceBeforePaymentTest is Base {
    uint256 internal constant DUST = 1e10;
    address internal dave = address(0xD4);

    // ── the breach: decades untouched, the sweep seizes a borrower whose loss the reserve cannot cover

    address internal erin = address(0xE5);

    function _untouchedBook() internal {
        _untouchedBook(false);
    }

    /// `withErin`: one more borrower holding a token's worth of debt, so she keeps LTV headroom.
    function _untouchedBook(bool withErin) internal {
        _fund(dave);
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        vm.prank(alice);
        staking.deposit(2_000e18, 90);
        vm.prank(carol);
        staking.deposit(1_000e18, 365);
        vm.prank(bob);
        staking.deposit(1_000e18, 90);
        vm.prank(dave);
        staking.deposit(1_000e18, 90);
        if (withErin) {
            _fund(erin);
            vm.prank(erin);
            staking.deposit(1_000e18, 90);
        }
        vm.roll(block.number + 11);
        if (withErin) {
            vm.prank(erin);
            staking.borrow(1e18);
        }
        vm.prank(carol);
        staking.borrow(400e18);
        vm.prank(bob);
        staking.borrow(500e18);
        vm.prank(dave);
        staking.borrow(500e18);
        vm.warp(block.timestamp + 100 days + 60 * 365 days);
        vm.roll(block.number + 30);
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before the transaction");
    }

    /// The reported case. Alice holds emission and pure yield; the sweep her claim carries seizes a
    /// borrower whose loss the reserve cannot cover. Read after that loss, the pot is short: pure
    /// yield refuses (PURE-UNCOLL) and the whole transaction, seizure included, reverts.
    function test_LOSSFIRST_pureClaimWhoseSweepBooksAThirdPartyLossPaysNothingAtPar() public {
        _untouchedBook();
        assertGt(staking.pendingRewards(alice), DUST, "setup: alice has earned emission");
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.claimRewards();
    }

    /// The door that must stay open: a borrower's repay. Its sweep books the third-party loss, and
    /// the settle that follows defers the emission instead of paying it out of the short pot.
    function test_LOSSFIRST_repayWhoseSweepBooksAThirdPartyLossDefersTheEmission() public {
        _untouchedBook();
        uint256 pend = staking.pendingRewards(carol);
        assertGt(pend, DUST, "setup: carol has earned emission");
        (uint256 b0, uint256 bad0, uint256 paid0) =
            (token.balanceOf(carol), staking.totalBadDebt(), staking.totalRewardsPaid());
        vm.prank(carol);
        staking.repay(1e18);
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the sweep booked a third-party loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        assertEq(token.balanceOf(carol), b0 - 1e18, "emission paid at par by the tx that left the pot short");
        assertEq(staking.totalRewardsPaid(), paid0, "no emission counted as paid");
        assertGe(staking.pendingRewards(carol), pend, "the earned emission stays credited");
    }

    /// Principal is a payment at par too: the exit reads the pot after the sweep's loss.
    function test_LOSSFIRST_withdrawWhoseSweepBooksAThirdPartyLossIsRefused() public {
        _untouchedBook();
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.withdraw(1e18);
    }

    /// The same exit with nothing pending: alice claims while paused (no sweep), so no settle of hers
    /// can refuse. The refusal is the withdraw's own breach read, after the sweep's loss.
    function test_LOSSFIRST_withdrawWithNothingPendingIsRefusedByItsOwnGate() public {
        _untouchedBook(true);
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), admin);
        vm.prank(admin);
        staking.pause();
        vm.prank(alice);
        staking.claimPureYield();
        vm.prank(admin);
        staking.unpause();
        assertEq(staking.pendingPureYield(alice), 0, "setup: no pure yield pending");
        assertEq(staking.pendingRewards(alice), 0, "setup: no emission pending");
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before the withdraw");
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.withdraw(1e18);
    }

    /// A loan is a payment at par: the borrow reads the pot after the sweep's loss. Erin borrows
    /// (no pure yield of her own), so the refusal is the borrow's own breach read.
    function test_LOSSFIRST_borrowWhoseSweepBooksAThirdPartyLossIsRefused() public {
        _untouchedBook(true);
        vm.prank(erin);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.borrow(1e18);
    }

    /// A keeper's lock poke: the poked owner is settled after the sweep's loss, so its emission is
    /// deferred, and the poke still goes through.
    function test_LOSSFIRST_lockPokeWhoseSweepBooksAThirdPartyLossDefersTheEmission() public {
        _untouchedBook();
        uint256 pend = staking.pendingRewards(carol);
        (uint256 b0, uint256 bad0) = (token.balanceOf(carol), staking.totalBadDebt());
        vm.prank(keeper);
        staking.pokeExpiredLock(carol);
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the sweep booked a third-party loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        assertEq(token.balanceOf(carol), b0, "emission paid at par by the tx that left the pot short");
        assertGe(staking.pendingRewards(carol), pend, "the earned emission stays credited");
    }

    // ── the order, on a healthy book: the sweep attributes a third party before the caller is paid
    // One year in: alice pure, bob and carol borrowing, every lock expired. Each entry's sweep
    // attributes the borrowers it is not carried by; the caller's first payment must come after
    // the last such attribution. This is the witness for the entries whose breach is out of reach
    // while emission runs (deposit, lock: closed after `emissionEnd`).

    function _healthyBook() internal {
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        vm.prank(alice);
        staking.deposit(2_000e18, 90);
        vm.prank(bob);
        staking.deposit(1_000e18, 90);
        vm.prank(carol);
        staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(bob);
        staking.borrow(500e18);
        vm.prank(carol);
        staking.borrow(400e18);
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 30);
        vm.recordLogs();
    }

    function _assertSweptBeforePaid(address payee, address carrier) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 accrued = keccak256("InterestAccrued(address,uint256,uint256)");
        bytes32 reward = keccak256("RewardClaimed(address,uint256)");
        bytes32 pure_ = keccak256("PureYieldClaimed(address,uint256)");
        bytes32 exit_ = keccak256("Withdrawn(address,uint256,uint256,uint256,uint256)");
        uint256 lastThirdParty;
        bool swept;
        uint256 firstPaid = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            address who = logs[i].topics.length > 1 ? address(uint160(uint256(logs[i].topics[1]))) : address(0);
            if (t0 == accrued && who != payee && who != carrier) { lastThirdParty = i; swept = true; }
            if ((t0 == reward || t0 == pure_ || t0 == exit_) && who == payee && firstPaid == type(uint256).max) {
                firstPaid = i;
            }
        }
        assertTrue(swept, "setup: the sweep attributed a third party");
        assertTrue(firstPaid != type(uint256).max, "setup: the payee was paid");
        assertLt(lastThirdParty, firstPaid, "a third party was attributed after the payment went out");
    }

    function test_LOSSFIRST_order_deposit() public {
        _healthyBook();
        vm.prank(alice);
        staking.deposit(1e18, 90);
        _assertSweptBeforePaid(alice, alice);
    }

    function test_LOSSFIRST_order_borrow() public {
        _healthyBook();
        vm.prank(alice);
        staking.borrow(1e18);
        _assertSweptBeforePaid(alice, alice);
    }

    function test_LOSSFIRST_order_repay() public {
        _healthyBook();
        vm.prank(carol);
        staking.repay(1e18);
        _assertSweptBeforePaid(carol, carol);
    }

    function test_LOSSFIRST_order_withdraw() public {
        _healthyBook();
        vm.prank(alice);
        staking.withdraw(1e18);
        _assertSweptBeforePaid(alice, alice);
    }

    function test_LOSSFIRST_order_claimRewards() public {
        _healthyBook();
        vm.prank(alice);
        staking.claimRewards();
        _assertSweptBeforePaid(alice, alice);
    }

    function test_LOSSFIRST_order_claimPureYield() public {
        _healthyBook();
        vm.prank(alice);
        staking.claimPureYield();
        _assertSweptBeforePaid(alice, alice);
    }

    function test_LOSSFIRST_order_lock() public {
        _healthyBook();
        vm.prank(alice);
        staking.lock(365);
        _assertSweptBeforePaid(alice, alice);
    }

    function test_LOSSFIRST_order_pokeExpiredLock() public {
        _healthyBook();
        vm.prank(keeper);
        staking.pokeExpiredLock(alice);
        _assertSweptBeforePaid(alice, keeper);
    }

    function test_LOSSFIRST_order_pokeExpiredLocks() public {
        _healthyBook();
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(keeper);
        staking.pokeExpiredLocks(users);
        _assertSweptBeforePaid(alice, keeper);
    }
}
