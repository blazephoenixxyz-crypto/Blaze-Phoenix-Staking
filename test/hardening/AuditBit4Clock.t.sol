// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

/// @notice BIT4-CLOCK. What `auditInvariants` bit 4 can and cannot say.
///
///         Derivation (single writer `_applyBoost`). A position's weights are written at its
///         resync: weight <= maxBoost x max(staked - debt, 0) read at that moment. Between resyncs
///         its debt is constant and its stake only falls (interest attribution), so the weights
///         stay bounded by the equity they were BUILT on, not by today's. Summed over the book:
///
///           totalBoostedEffective <= maxBoost x (totalStaked + totalInterestAccruedGlobal)
///           totalBoostedPure      <= totalBoostedEffective
///           totalBoostedPure      <= maxBoost x totalPositiveEquity
///
///         The first holds because totalStaked + interest accrued = stored stake + every interest
///         ever attributed >= the stake each weight was built on; the other two because a pure
///         weight exists only on a debt-free position, which no attribution touches. These three
///         hold on every clock: after a sweep, after an attribution that left the weights where
///         they were, during an emergency. Oracle: the public getters and raw storage.
///
///         Bit 4 compares the weights with `totalStaked` alone, which the global interest debit
///         lowers at once. It is exact on a book whose positions are all resynced, and reads set
///         on a correct book once the interest not yet followed by a resync exceeds the debt:
///         a SOFT signal, pinned as such here (report 4134; bits 16 / 18 at 9731e05 and b72ebe9
///         on a book whose accumulator equals the sum of its tracked weights).
contract AuditBit4ClockTest is Base {
    using stdStorage for StdStorage;

    uint256 internal constant USERS_SLOT = 36;   // `_users`; field 6 = trackedBoostedEffective
    uint8 internal constant BIT4 = 1 << 4;
    uint256 internal constant BASE = 10_000;

    address[] internal borrowers;

    function _tracked(address who) internal view returns (uint256) {
        return uint256(vm.load(address(staking), bytes32(uint256(keccak256(abi.encode(who, USERS_SLOT))) + 6)));
    }

    function _sumTracked() internal view returns (uint256 s) {
        for (uint256 i; i < borrowers.length; ++i) s += _tracked(borrowers[i]);
    }

    function _borrower(uint256 i, uint256 lockDays) internal returns (address who) {
        who = address(uint160(0x5000 + i));
        token.mint(who, 500_000_000e18);
        vm.prank(who); token.approve(address(staking), type(uint256).max);
        vm.prank(who); staking.deposit(1_000_000e18, lockDays);
        uint256 maxB = staking.maxBorrowOf(who);
        vm.prank(who); staking.borrow(maxB);
        borrowers.push(who);
    }

    function _guardian() internal {
        vm.prank(admin); staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
    }

    /// The three relations of the header, read off the public getters.
    function _assertSoundReading(string memory where) internal view {
        uint256 maxBoost = staking.boostByDays(2555);
        uint256 tbe = staking.totalBoostedEffective();
        uint256 tbp = staking.totalBoostedPure();
        assertLe(tbe * BASE, (staking.totalStaked() + staking.totalInterestAccruedGlobal()) * maxBoost,
            string.concat(where, ": effective weight above maxBoost x (totalStaked + interest accrued)"));
        assertLe(tbp, tbe, string.concat(where, ": pure weight above effective weight"));
        assertLe(tbp * BASE, staking.totalPositiveEquity() * maxBoost,
            string.concat(where, ": pure weight above maxBoost x positive equity"));
    }

    /// 60 max-boost borrowers, `yrs` idle years, one transaction: the global side debits the whole
    /// backlog, the sweep attributes at most 14 positions, the rest keep the weight of their build.
    function _idleBook(uint256 yrs) internal returns (uint8 bits) {
        for (uint256 i; i < 60; ++i) _borrower(i, 2555);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + yrs * 365 days);
        vm.roll(block.number + 12);
        vm.prank(keeper); staking.claimRewards();
        assertEq(staking.totalBoostedEffective(), _sumTracked(), "fixture: accumulator == sum of tracked weights");
        assertGt(staking.totalInterestAccruedGlobal(), staking.totalDebt(), "fixture: the backlog exceeds the debt");
        _assertSoundReading("idle book");
        bits = staking.auditInvariants();
    }

    // ── the SOFT reading of bit 4 ───────────────────────────────────────────────────────────

    function test_BIT4_readsSetOnACorrectBookWhileInterestIsUnattributed_30y() public {
        assertEq(_idleBook(30) & BIT4, BIT4, "SOFT pin: bit4 reads set on the idle book (30y)");
    }

    function test_BIT4_readsSetOnACorrectBookWhileInterestIsUnattributed_60y() public {
        uint8 bits = _idleBook(60);
        assertEq(bits & BIT4, BIT4, "SOFT pin: bit4 reads set on the idle book (60y)");
        assertEq(bits & (1 << 1), 1 << 1, "bit1 still reads the terminal state");
    }

    /// Once every position is resynced the two sides are on one clock and bit 4 reads the stored
    /// book. (At 30 years the 2555-day locks have lapsed, so the resync also brings the boost to 1.00x.)
    function test_BIT4_readsTheStoredBookOnceEveryPositionIsResynced() public {
        _idleBook(30);
        vm.roll(block.number + 1);
        vm.prank(keeper); staking.pokeExpiredLocks(borrowers);
        assertEq(staking.totalBoostedEffective(), _sumTracked(), "accumulator == sum after resync");
        _assertSoundReading("resynced book");
        assertEq(staking.auditInvariants() & BIT4, 0, "bit4 still set after every position was resynced");
    }

    // ── the guard can fire ──────────────────────────────────────────────────────────────────

    /// An accumulator one wei above stake x maxBoost sets the bit, one at the bound does not.
    /// Debt-free book: no interest, so the bound is exactly totalStaked x 2.75.
    function test_BIT4_firesOneWeiAboveTheBound_effective() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 2555);
        uint256 bound = staking.totalStaked() * staking.boostByDays(2555) / BASE;
        stdstore.target(address(staking)).sig("totalBoostedEffective()").checked_write(bound);
        assertEq(staking.auditInvariants() & BIT4, 0, "at the bound: clear");
        stdstore.target(address(staking)).sig("totalBoostedEffective()").checked_write(bound + 1);
        assertEq(staking.auditInvariants() & BIT4, BIT4, "one wei above: set");
    }

    function test_BIT4_firesOneWeiAboveTheBound_pure() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 2555);
        uint256 bound = staking.totalStaked() * staking.boostByDays(2555) / BASE;
        stdstore.target(address(staking)).sig("totalBoostedPure()").checked_write(bound);
        assertEq(staking.auditInvariants() & BIT4, 0, "at the bound: clear");
        stdstore.target(address(staking)).sig("totalBoostedPure()").checked_write(bound + 1);
        assertEq(staking.auditInvariants() & BIT4, BIT4, "one wei above: set");
    }

    // ── the sound reading on the clocks where equity and weight part ────────────────────────

    /// A borrower carries a poke batch: its own interest is attributed first and its equity
    /// refreshed, the borrower window skips the carrier, its weights stay where its last resync
    /// left them. `totalPositiveEquity` is then BELOW the equity the weights were built on.
    function _carrier(uint256 idleDays) internal {
        address a = _borrower(0, 2555);
        vm.prank(bob); staking.deposit(100e18, 90);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + idleDays * 1 days);
        vm.roll(block.number + 12);
        uint256 weight = _tracked(a);
        uint256 equity = staking.totalPositiveEquity();
        address[] memory l = new address[](1); l[0] = bob;
        vm.prank(a); staking.pokeExpiredLocks(l);
        assertEq(_tracked(a), weight, "fixture: the carrier's weight did not move");
        assertLt(staking.totalPositiveEquity(), equity, "fixture: the carrier's equity was refreshed");
        assertGt(staking.totalBoostedEffective() * BASE, staking.totalPositiveEquity() * staking.boostByDays(2555),
            "fixture: the weights exceed maxBoost x the refreshed equity");
        _assertSoundReading("carrier");
    }

    function test_BIT4_soundReadingHoldsWhenACarrierIsAttributedWithoutResync_100d() public { _carrier(100); }
    function test_BIT4_soundReadingHoldsWhenACarrierIsAttributedWithoutResync_12y() public { _carrier(12 * 365); }
    function test_BIT4_soundReadingHoldsWhenACarrierIsAttributedWithoutResync_30y() public { _carrier(30 * 365); }

    /// Emergency: `syncEquity` attributes the frozen interest and refreshes equity, weights unchanged.
    function test_BIT4_soundReadingHoldsThroughAnEmergencySync() public {
        for (uint256 i; i < 60; ++i) _borrower(i, 2555);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + 30 * 365 days);
        vm.roll(block.number + 12);
        _guardian();
        vm.prank(keeper); staking.declareEmergency();
        _assertSoundReading("emergency, nobody synced");
        for (uint256 i; i < 60; ++i) {
            staking.syncEquity(borrowers[i]);
            _assertSoundReading("emergency, syncing");
        }
        assertEq(staking.totalBoostedEffective(), _sumTracked(), "accumulator == sum of tracked weights");
    }

    /// Ranges: 1..24 borrowers, 90..2555-day locks, 1 day..60 idle years. Vectors: the keeper's
    /// claim (sweep), a borrower carrying a poke batch (attribution without resync), an emergency
    /// with every borrower synced.
    function testFuzz_BIT4_soundReadingHoldsOnEveryClock(uint256 n, uint256 lockDays, uint256 idleDays, uint256 door) public {
        n = bound(n, 1, 24); lockDays = bound(lockDays, 90, 2555); idleDays = bound(idleDays, 1, 60 * 365);
        for (uint256 i; i < n; ++i) _borrower(i, lockDays);
        vm.prank(bob); staking.deposit(100e18, 90);
        vm.roll(block.number + 11);
        vm.warp(block.timestamp + idleDays * 1 days);
        vm.roll(block.number + 12);
        door = door % 3;
        if (door == 0) {
            vm.prank(keeper); staking.claimRewards();
        } else if (door == 1) {
            address[] memory l = new address[](1); l[0] = bob;
            vm.prank(borrowers[0]);
            try staking.pokeExpiredLocks(l) {} catch {}   // refused while bob's lock is running
        } else {
            _guardian();
            vm.prank(keeper); staking.declareEmergency();
            for (uint256 i; i < n; ++i) staking.syncEquity(borrowers[i]);
        }
        assertEq(staking.totalBoostedEffective(), _sumTracked() + _tracked(bob), "accumulator == sum of tracked weights");
        _assertSoundReading("fuzz");
    }
}
