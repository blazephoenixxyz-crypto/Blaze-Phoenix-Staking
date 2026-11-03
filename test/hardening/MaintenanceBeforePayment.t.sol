// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice LOSS-FIRST. Oracle: within one transaction every loss is booked before anything leaves
///         at par, so the gate that lets a payment out reads the pot after them. The maintenance
///         sweep a transaction carries books OTHER positions' losses (attribution, seizure); it
///         runs before the caller's payments, not after them. Inside it, the borrower window
///         credits the positions it settles instead of paying them, so a loss a later step of the
///         same window books comes first for them too. The caller's own loss, and that of every
///         position the transaction names, is booked before the sweep; the lock window acts only
///         where its settle books none.
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

    function _untouchedBook(bool withErin) internal {
        _openUntouchedBook(withErin);
        _ageUntouchedBook();
    }

    /// `withErin`: one more borrower holding a token's worth of debt, so she keeps LTV headroom.
    /// `order`: the order the loans are opened in, the order the borrower registry holds them in.
    function _openUntouchedBook(bool withErin, address[4] memory order) internal {
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
        for (uint256 i; i < 4; ++i) {
            address who = order[i];
            if (who == erin && !withErin) continue;
            vm.prank(who);
            staking.borrow(who == erin ? 1e18 : who == carol ? 400e18 : 500e18);
        }
    }

    /// The same book in the order the other tests open it in.
    function _openUntouchedBook(bool withErin) internal {
        _openUntouchedBook(withErin, [erin, carol, bob, dave]);
    }

    function _ageUntouchedBook() internal {
        vm.warp(block.timestamp + 100 days + 60 * 365 days);
        vm.roll(block.number + 30);
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before the transaction");
    }

    /// The reported case. Alice holds emission and pure yield; the sweep her claim carries seizes a
    /// borrower whose loss the reserve cannot cover. Read after that loss, the pot is short: pure
    /// yield refuses (PURE-UNCOLL) and the whole transaction, seizure included, reverts.
    function test_LOSSFIRST_pureClaimWhoseSweepBooksAThirdPartyLossPaysNothingAtPar() public {
        _untouchedBook();
        uint256 pend = staking.pendingRewards(alice);
        assertGt(pend, DUST, "setup: alice has earned emission");
        (uint256 b0, uint256 bad0, uint256 paid0) =
            (token.balanceOf(alice), staking.totalBadDebt(), staking.totalRewardsPaid());
        // W2-R1: the settles after the sweep credit instead of paying (or reverting).
        vm.prank(alice);
        staking.claimRewards();
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the sweep booked a third-party loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        assertEq(token.balanceOf(alice), b0, "paid at par by the tx that left the pot short");
        assertEq(staking.totalRewardsPaid(), paid0, "nothing counted as paid");
        assertGe(staking.pendingRewards(alice), pend, "the earned emission stays credited");
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

    /// Inside the sweep. One more poke before the decades pass moves the cursor, so the window
    /// opens at erin, a healthy borrower with emission earned, and reaches the borrowers whose
    /// losses it books after her. Read at her settle the pot is still whole; she must be credited
    /// (`_rewardDeferred`), not paid. Red at 35dc558: she was paid her whole pending at par and
    /// the same window then booked the bad debt that left the pot short.
    function test_LOSSFIRST_thirdPartySettledBeforeTheLossInTheSameWindowIsCreditedNotPaid() public {
        _openUntouchedBook(true);
        vm.prank(alice);
        staking.claimRewards();
        _ageUntouchedBook();
        uint256 pend = staking.pendingRewards(erin);
        assertGt(pend, DUST, "setup: erin has earned emission");
        (uint256 b0, uint256 bad0, uint256 paid0) =
            (token.balanceOf(erin), staking.totalBadDebt(), staking.totalRewardsPaid());
        vm.recordLogs();
        vm.prank(alice);
        staking.claimRewards();
        _assertWindowOpenedAt(erin);
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the window booked a third-party loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        assertEq(token.balanceOf(erin), b0, "paid at par ahead of a loss the same window booked");
        assertEq(staking.totalRewardsPaid(), paid0, "nothing counted as paid");
        assertGe(staking.pendingRewards(erin) + DUST, pend, "the earned emission stays credited");
    }

    /// The window attributed `first` before any other position, and went on past it.
    function _assertWindowOpenedAt(address first) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 accrued = keccak256("InterestAccrued(address,uint256,uint256)");
        bool seen;
        uint256 later;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != accrued) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) == first) seen = true;
            else { assertTrue(seen, "setup: the window opened at another position"); ++later; }
        }
        assertTrue(seen, "setup: the window reached the position");
        assertGt(later, 0, "setup: the window went on past it");
    }

    /// Every order of the registry. The same book opened with its four loans in each of the 24
    /// orders: the window that books the three losses scans the registry in that order, and each
    /// user is paid the same in all of them, each loss booked before anybody else is paid at par.
    /// Red at 35dc558: scanned before the first loss, erin was paid at par; after it, credited.
    function test_LOSSFIRST_everyOrderOfTheRegistryPaysEachUserTheSame() public {
        address[4] memory book = [erin, carol, bob, dave];
        uint256 snap = vm.snapshotState();
        uint256[6][] memory got = new uint256[6][](24);
        Vm.Log[][] memory logs = new Vm.Log[][](24);
        uint256 r;
        for (uint256 a; a < 4; ++a) {
            for (uint256 b; b < 4; ++b) {
                for (uint256 c; c < 4; ++c) {
                    if (a == b || a == c || b == c) continue;
                    vm.revertToState(snap);
                    (got[r], logs[r]) = _scanTheRegistryIn([book[a], book[b], book[c], book[6 - a - b - c]]);
                    ++r;
                }
            }
        }
        assertGt(got[0][0] + got[0][5], DUST, "setup: erin earned emission the window settles");
        for (uint256 k = 1; k < 24; ++k) {
            for (uint256 j; j < 5; ++j) assertEq(got[k][j], got[0][j], "the registry's order changed what a user was paid");
            assertEq(got[k][5], got[0][5], "the registry's order changed what erin holds as credit");
        }
        for (uint256 k; k < 24; ++k) _lossesBeforeThirdPartyPayments(logs[k], alice);
    }

    /// One order: what alice's claim paid erin, carol, bob, dave and alice, and erin's credit after it.
    function _scanTheRegistryIn(address[4] memory order) internal returns (uint256[6] memory got, Vm.Log[] memory logs) {
        _openUntouchedBook(true, order);
        _ageUntouchedBook();
        address[5] memory who = [erin, carol, bob, dave, alice];
        uint256[5] memory b0;
        for (uint256 j; j < 5; ++j) b0[j] = token.balanceOf(who[j]);
        uint256 bad0 = staking.totalBadDebt();
        vm.recordLogs();
        vm.prank(alice);
        staking.claimRewards();
        logs = vm.getRecordedLogs();
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the window booked a third-party loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        for (uint256 j; j < 5; ++j) got[j] = token.balanceOf(who[j]) - b0[j];
        got[5] = staking.pendingRewards(erin) + staking.pendingPureYield(erin);
    }

    // ── the seizure, inside the same window. Erin is seized with equity left and bob, scanned
    // after her, books a loss the reserve cannot cover; both read the pot before bob's loss.

    /// Alice pure; erin borrows 248 and bob 500 against 1,000 each, erin registered first. One more
    /// transaction moves the cursor to her. 155 years at the rate the book starts with carry erin's
    /// stake to 254.17, inside the seizure band with 6.17 of equity, and bob's interest past his.
    function _seizableBesideALoss() internal {
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        _fund(erin);
        vm.prank(alice);
        staking.deposit(2_000e18, 90);
        vm.prank(erin);
        staking.deposit(1_000e18, 90);
        vm.prank(bob);
        staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(erin);
        staking.borrow(248e18);
        vm.prank(bob);
        staking.borrow(500e18);
        vm.prank(alice);
        staking.claimRewards();
        assertEq(uint256(vm.load(address(staking), bytes32(MAINT_CURSOR_SLOT))) % 2, 0, "setup: the window opens at erin");
        vm.warp(block.timestamp + 155 * 365 days + 300 days);
        vm.roll(block.number + 30);
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before the transaction");
        (,,,, uint256 health, uint256 daysLeft,,,,,,,,) = staking.getUserInfo(erin);
        assertTrue(health > 0 && daysLeft == 0, "setup: erin is seizable with equity left");
    }

    /// The seized position is credited like the poked one: read at her seizure the pot is still
    /// whole, so she must be credited (`_rewardDeferred`), not paid. The credit outlives the
    /// position: seized in full, she is paid it once the loss is absorbed. Red at 35dc558: her
    /// seizure paid her emission at par ahead of bob's loss.
    function test_LOSSFIRST_seizedBeforeTheLossInTheSameWindowIsCreditedNotPaid() public {
        _seizableBesideALoss();
        uint256 pend = staking.pendingRewards(erin);
        assertGt(pend, DUST, "setup: erin has earned emission");
        (uint256 b0, uint256 bad0, uint256 paid0) =
            (token.balanceOf(erin), staking.totalBadDebt(), staking.totalRewardsPaid());
        vm.recordLogs();
        vm.prank(alice);
        staking.claimRewards();
        _assertWindowOpenedAt(erin);
        (uint256 st, uint256 debt,,,,,,,,,,,,) = staking.getUserInfo(erin);
        assertEq(st + debt, 0, "setup: erin was seized in full");
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the window booked bob's loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        assertEq(token.balanceOf(erin), b0, "seized and paid at par ahead of a loss the same window booked");
        assertEq(staking.totalRewardsPaid(), paid0, "nothing counted as paid");
        uint256 credit = staking.pendingRewards(erin);
        assertGe(credit + DUST, pend, "the earned emission stays credited");
        vm.prank(admin);
        staking.absorbBadDebt(type(uint256).max);
        assertTrue(staking.isSolvent(), "setup: the loss is absorbed");
        vm.prank(erin);
        staking.claimRewards();
        assertEq(token.balanceOf(erin), b0 + credit, "the credit is paid once the loss is absorbed");
    }

    /// The caller's own loss comes before the seizure's bonus. Bob carries the transaction: his
    /// interest, attributed before the sweep, books his loss, so when the window seizes erin the
    /// pot already reads as breached and the `keeperBonus` stays in the reserve. Red at 35dc558:
    /// bob was paid the bonus at par and his own settle then booked the loss.
    function test_LOSSFIRST_theCarriersOwnLossIsBookedBeforeTheSeizureBonus() public {
        _seizableBesideALoss();
        (uint256 b0, uint256 bad0) = (token.balanceOf(bob), staking.totalBadDebt());
        vm.prank(bob);
        staking.repay(1e18);
        (uint256 st,,,,,,,,,,,,,) = staking.getUserInfo(erin);
        assertEq(st, 0, "setup: the window seized erin");
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the transaction booked bob's loss");
        assertEq(token.balanceOf(bob), b0 - 1e18, "the bonus was paid at par ahead of the caller's own loss");
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

    // ── the same order for third parties: nobody the sweep settles is paid before its last
    // attribution. The window opens at carol and attributes bob after her; she is credited, not
    // paid, and the lock window that pays runs after it. Red at 35dc558: carol was paid at par
    // before bob was attributed. `repay` is carried by carol herself, so its window holds bob
    // alone and has no later attribution to order against; it runs the same window.

    function _assertNoThirdPartyPaidBeforeTheSweepEnds(address carrier) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 accrued = keccak256("InterestAccrued(address,uint256,uint256)");
        bytes32 reward = keccak256("RewardClaimed(address,uint256)");
        bytes32 pure_ = keccak256("PureYieldClaimed(address,uint256)");
        uint256 attributed;
        uint256 lastAttributed;
        uint256 firstPaid = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            address who = logs[i].topics.length > 1 ? address(uint160(uint256(logs[i].topics[1]))) : address(0);
            if (who == carrier) continue;
            if (t0 == accrued) { ++attributed; lastAttributed = i; }
            if ((t0 == reward || t0 == pure_) && firstPaid == type(uint256).max) firstPaid = i;
        }
        assertGt(attributed, 1, "setup: the sweep attributed two third parties");
        assertGt(firstPaid, lastAttributed, "a third party was paid at par before the sweep's last attribution");
    }

    function test_LOSSFIRST_thirdPartyOrder_deposit() public {
        _healthyBook();
        vm.prank(alice);
        staking.deposit(1e18, 90);
        _assertNoThirdPartyPaidBeforeTheSweepEnds(alice);
    }

    function test_LOSSFIRST_thirdPartyOrder_borrow() public {
        _healthyBook();
        vm.prank(alice);
        staking.borrow(1e18);
        _assertNoThirdPartyPaidBeforeTheSweepEnds(alice);
    }

    function test_LOSSFIRST_thirdPartyOrder_withdraw() public {
        _healthyBook();
        vm.prank(alice);
        staking.withdraw(1e18);
        _assertNoThirdPartyPaidBeforeTheSweepEnds(alice);
    }

    function test_LOSSFIRST_thirdPartyOrder_claimRewards() public {
        _healthyBook();
        vm.prank(alice);
        staking.claimRewards();
        _assertNoThirdPartyPaidBeforeTheSweepEnds(alice);
    }

    function test_LOSSFIRST_thirdPartyOrder_claimPureYield() public {
        _healthyBook();
        vm.prank(alice);
        staking.claimPureYield();
        _assertNoThirdPartyPaidBeforeTheSweepEnds(alice);
    }

    function test_LOSSFIRST_thirdPartyOrder_lock() public {
        _healthyBook();
        vm.prank(alice);
        staking.lock(365);
        _assertNoThirdPartyPaidBeforeTheSweepEnds(alice);
    }

    function test_LOSSFIRST_thirdPartyOrder_pokeExpiredLock() public {
        _healthyBook();
        vm.prank(keeper);
        staking.pokeExpiredLock(alice);
        _assertNoThirdPartyPaidBeforeTheSweepEnds(keeper);
    }

    function test_LOSSFIRST_thirdPartyOrder_pokeExpiredLocks() public {
        _healthyBook();
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(keeper);
        staking.pokeExpiredLocks(users);
        _assertNoThirdPartyPaidBeforeTheSweepEnds(keeper);
    }

    // ── the settles that can book the loss themselves: the caller's own, a lapsed borrower the
    // lock window meets, the position a poke names, every position a batch names. Each loss is
    // booked before anybody else in the transaction is paid at par.

    address internal xp = address(0xA1);   // pure staker, seven-year lock
    address internal yb = address(0xB2);   // borrower, seven-year lock, eroded by the decades
    uint256 internal constant MAINT_CURSOR_SLOT = 31;   // `_maintCursor`
    uint256 internal constant LOCK_CURSOR_SLOT = 35;    // `_lockCursor`

    /// Every attribution that empties a stake (the shape of a loss; the callers check on
    /// `totalBadDebt` that the reserve did not cover it) comes before the first payment at par to
    /// anybody but `carrier`.
    function _lossesBeforeThirdPartyPayments(Vm.Log[] memory logs, address carrier) internal pure {
        uint256 paid;
        bytes32 accrued = keccak256("InterestAccrued(address,uint256,uint256)");
        bytes32 reward = keccak256("RewardClaimed(address,uint256)");
        bytes32 pure_ = keccak256("PureYieldClaimed(address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            address who = logs[i].topics.length > 1 ? address(uint160(uint256(logs[i].topics[1]))) : address(0);
            if ((t0 == reward || t0 == pure_) && who != carrier) ++paid;
            if (t0 == accrued) {
                (, uint256 newStake) = abi.decode(logs[i].data, (uint256, uint256));
                if (newStake == 0) assertEq(paid, 0, "a third party was paid at par before a loss the same transaction booked");
            }
        }
    }

    /// The lock window's first action in the logs is on `first`, and no attribution of `notYet`
    /// precedes it. It acts at all: a debt-free lapsed position is still normalised.
    function _lockWindowOpenedAt(Vm.Log[] memory logs, address first, address notYet) internal pure {
        bytes32 swept = keccak256("LockSwept(address,address,uint256,uint256)");
        bytes32 accrued = keccak256("InterestAccrued(address,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == accrued) {
                assertTrue(address(uint160(uint256(logs[i].topics[1]))) != notYet, "setup: attributed before the lock window");
            }
            if (t0 == swept) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), first, "setup: the lock window opened elsewhere");
                return;
            }
        }
        revert("the lock window normalised nobody");
    }

    /// The caller's own loss. Bob borrows, the decades erode him, and he repays a token. His sweep
    /// opens its lock window at alice, a lapsed pure staker, and his own settle books his loss.
    /// Booked before the sweep, it is read by her settle: credited, not paid. Red at 35dc558: she
    /// was paid at par and bob's settle then booked the bad debt that left the pot short.
    function test_LOSSFIRST_theCarriersOwnLossIsBookedBeforeTheLockWindowPays() public {
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        vm.prank(alice);
        staking.deposit(2_000e18, 90);
        vm.prank(bob);
        staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(bob);
        staking.borrow(500e18);
        vm.warp(block.timestamp + 100 days + 120 * 365 days);
        vm.roll(block.number + 30);
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before the transaction");
        uint256 pend = staking.pendingRewards(alice);
        assertGt(pend, DUST, "setup: alice has earned emission");
        (uint256 b0, uint256 bad0) = (token.balanceOf(alice), staking.totalBadDebt());
        vm.recordLogs();
        vm.prank(bob);
        staking.repay(1e18);
        _lockWindowOpenedAt(vm.getRecordedLogs(), alice, address(0));
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the transaction booked bob's loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        assertEq(token.balanceOf(alice), b0, "the lock window paid at par ahead of the caller's own loss");
        assertGe(staking.pendingRewards(alice) + DUST, pend, "the earned emission stays credited");
    }

    function _tiny(uint256 i) internal pure returns (address) {
        return address(uint160(0x7100 + i));
    }

    /// Eleven borrowers, one more than a window scans: ten tiny ones, healthy for centuries, and
    /// yb, half her stake borrowed, registered last. Alice is a pure carrier and xp a small pure
    /// staker; xp's and yb's seven-year locks are the only ones left registered. Idle transactions
    /// at a zero gap move both cursors by one until the borrower window opens at the first tiny
    /// borrower (it stops one short of yb) and the lock window at xp. Then 150 years pass: both
    /// locks lapse and yb's interest outgrows her stake, a loss the reserve cannot cover. xp is
    /// small because her settle returns the lapsed part of her boosted pure yield to the reserve
    /// (LOCK-STALE); at 1,000 tokens that return covered all of yb's loss.
    function _lockWindowMeetsAnUnattributedBorrower() internal {
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        for (uint256 i; i < 10; ++i) {
            _fund(_tiny(i));
            vm.prank(_tiny(i));
            staking.deposit(10e18, 90);
        }
        vm.prank(alice);
        staking.deposit(2_000e18, 90);
        _fund(xp);
        vm.prank(xp);
        staking.deposit(10e18, 2555);
        _fund(yb);
        vm.prank(yb);
        staking.deposit(1_000e18, 2555);
        vm.roll(block.number + 11);
        for (uint256 i; i < 10; ++i) {
            vm.prank(_tiny(i));
            staking.borrow(1e18);
        }
        vm.prank(yb);
        staking.borrow(500e18);
        vm.warp(block.timestamp + 91 days);
        vm.roll(block.number + 1);
        for (uint256 i; i < 10; ++i) {
            vm.prank(_tiny(i));
            staking.claimRewards();
        }
        vm.prank(alice);
        staking.claimRewards();
        (address[] memory l,) = staking.getLockers(0, type(uint256).max);
        assertEq(l.length, 2, "setup: only the seven-year locks are registered");
        uint256 ix = l[0] == xp ? 0 : 1;
        for (uint256 k; k < 22; ++k) {
            uint256 m = uint256(vm.load(address(staking), bytes32(MAINT_CURSOR_SLOT)));
            uint256 c = uint256(vm.load(address(staking), bytes32(LOCK_CURSOR_SLOT)));
            if (m % 11 == 0 && c % 2 == ix) break;
            vm.prank(alice);
            staking.claimRewards();
        }
        assertEq(uint256(vm.load(address(staking), bytes32(MAINT_CURSOR_SLOT))) % 11, 0, "setup: borrower window aligned");
        assertEq(uint256(vm.load(address(staking), bytes32(LOCK_CURSOR_SLOT))) % 2, ix, "setup: lock window aligned");
        vm.warp(block.timestamp + 150 * 365 days);
        vm.roll(block.number + 30);
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before the transaction");
    }

    /// The lock window meets yb before anything attributes her: the borrower window scanned the
    /// ten tiny borrowers and stopped. It pays xp, and then must not book yb's loss: her
    /// `interestIndex` is behind the index this transaction reached, so it rotates past her and
    /// her own transaction books it first. Red at 35dc558: xp was paid at par and
    /// the same window then booked yb's bad debt.
    function test_LOSSFIRST_theLockWindowBooksNoLossAfterItPays() public {
        _lockWindowMeetsAnUnattributedBorrower();
        (uint256 b0, uint256 bad0) = (token.balanceOf(xp), staking.totalBadDebt());
        vm.recordLogs();
        vm.prank(alice);
        staking.claimRewards();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _lockWindowOpenedAt(logs, xp, yb);
        assertGt(token.balanceOf(xp), b0, "setup: the lock window paid xp at par");
        assertEq(staking.totalBadDebt(), bad0, "the lock window booked a loss after it paid at par");
        _lossesBeforeThirdPartyPayments(logs, alice);
        vm.prank(yb);
        staking.repay(1e18);
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: yb's loss is real");
    }

    /// The position a poke names. Booked before the sweep, yb's loss is read by xp's settle in
    /// the lock window: credited, not paid. Red at 35dc558: the lock window paid xp (and the
    /// borrower window the tiny borrowers) at par before yb's loss.
    function test_LOSSFIRST_thePokedPositionsLossIsBookedBeforeTheSweepPays() public {
        _lockWindowMeetsAnUnattributedBorrower();
        (uint256 b0, uint256 bad0) = (token.balanceOf(xp), staking.totalBadDebt());
        vm.recordLogs();
        vm.prank(keeper);
        staking.pokeExpiredLock(yb);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the poke booked yb's loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        assertEq(token.balanceOf(xp), b0, "xp was paid at par ahead of the poked position's loss");
        _lossesBeforeThirdPartyPayments(logs, keeper);
    }

    /// Every position a batch names. Paused, so the batch alone acts: xp first, then yb, then a
    /// name with no position, so yb's loss sits mid-batch. yb's loss is booked before either
    /// settle. Red at 35dc558: xp was paid at par and yb's settle then booked the bad debt.
    function test_LOSSFIRST_theBatchBooksEveryNamedLossBeforeItPays() public {
        _lockWindowMeetsAnUnattributedBorrower();
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), admin);
        vm.prank(admin);
        staking.pause();
        (uint256 b0, uint256 bad0) = (token.balanceOf(xp), staking.totalBadDebt());
        address[] memory users = new address[](3);
        (users[0], users[1], users[2]) = (xp, yb, address(0xBEEF));
        vm.recordLogs();
        vm.prank(keeper);
        staking.pokeExpiredLocks(users);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the batch booked yb's loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        assertEq(token.balanceOf(xp), b0, "xp was paid at par ahead of a loss the batch booked");
        _lossesBeforeThirdPartyPayments(logs, keeper);
    }

    /// Every order of the batch. The same three names in each of the six orders, paused so the
    /// batch alone acts: each user is paid the same in all of them, yb's loss booked before
    /// anybody else is paid at par. Red at 35dc558: named before yb, xp was paid at par; after
    /// her, credited.
    function test_LOSSFIRST_everyOrderOfTheBatchPaysEachUserTheSame() public {
        _lockWindowMeetsAnUnattributedBorrower();
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), admin);
        vm.prank(admin);
        staking.pause();
        address[3] memory names = [xp, yb, address(0xBEEF)];
        uint256 snap = vm.snapshotState();
        uint256[4][] memory got = new uint256[4][](6);
        Vm.Log[][] memory logs = new Vm.Log[][](6);
        uint256 r;
        for (uint256 a; a < 3; ++a) {
            for (uint256 b; b < 3; ++b) {
                if (a == b) continue;
                vm.revertToState(snap);
                (got[r], logs[r]) = _pokeTheBatchIn([names[a], names[b], names[3 - a - b]]);
                ++r;
            }
        }
        assertGt(got[0][0] + got[0][3], DUST, "setup: xp earned emission the batch settles");
        for (uint256 k = 1; k < 6; ++k) {
            for (uint256 j; j < 3; ++j) assertEq(got[k][j], got[0][j], "the batch's order changed what a user was paid");
            assertEq(got[k][3], got[0][3], "the batch's order changed what xp holds as credit");
        }
        for (uint256 k; k < 6; ++k) _lossesBeforeThirdPartyPayments(logs[k], keeper);
    }

    /// One order: what the batch paid xp, yb and the keeper, and xp's credit after it.
    function _pokeTheBatchIn(address[3] memory order) internal returns (uint256[4] memory got, Vm.Log[] memory logs) {
        address[] memory users = new address[](3);
        (users[0], users[1], users[2]) = (order[0], order[1], order[2]);
        (uint256 bx, uint256 by, uint256 bk) = (token.balanceOf(xp), token.balanceOf(yb), token.balanceOf(keeper));
        uint256 bad0 = staking.totalBadDebt();
        vm.recordLogs();
        vm.prank(keeper);
        staking.pokeExpiredLocks(users);
        logs = vm.getRecordedLogs();
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the batch booked yb's loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        got = [token.balanceOf(xp) - bx, token.balanceOf(yb) - by, token.balanceOf(keeper) - bk,
            staking.pendingRewards(xp) + staking.pendingPureYield(xp)];
    }
}
