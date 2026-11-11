// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  atq-1111 (staking front) — the two maintenance windows and their rotating cursors
//
//  GREEN (each with its mutant, [ATQ-staking-44..52] in .github/scripts/mutants.py):
//   1. On a registry nobody changes, the lock window reaches every elapsed lock within one
//      rotation (len probes), for every index and three registry sizes.
//   2. The lock window acts on at most four locks per transaction (MAINT_MAX_LOCK_ACTIONS).
//   3. The window budget ladder: 1 + len/50 + gap/15min, capped at 10 and at len. ORACLE: the
//      test's own arithmetic from the documented constants, never the contract's view of itself.
//   4. On a registry nobody changes, the borrower window seizes a seizable borrower within one
//      rotation of third-party probes, and never seizes its own caller.
//
//  A "probe" is a transaction of an address that holds nothing (`claimRewards()` pays it
//  nothing): it carries both windows and changes no registry.
//
//  The two properties that go beyond a stable registry live in AtqSweepCursorOpen.t.sol.
//  Run: forge test --match-path test/atq/AtqSweepCursor.t.sol
// =============================================================================

import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";

abstract contract AtqSweepBase is Base {
    address internal constant STRANGER = address(0x57A6E);
    uint256 internal constant GAP_UNIT = 15 minutes;

    function _a(uint256 salt, uint256 i) internal pure returns (address) { return address(uint160(salt + i)); }

    function _probe() internal {
        vm.prank(STRANGER);
        staking.claimRewards();
    }

    /// n lockers; `target` commits 90 days and the others 365. The cursor is turned `spins` times ten
    /// first (a deployment that has lived), then the clock stops on the second `target` elapses,
    /// with the time budget already spent: every transaction from here carries one probe.
    function _openLockers(uint256 n, uint256 target, uint256 spins) internal returns (address t) {
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        for (uint256 i; i < n; ++i) {
            address a = _a(0x10C000, i);
            _fund(a);
            vm.prank(a);
            staking.deposit(10_000e18, i == target ? 90 : 365);
        }
        t = _a(0x10C000, target);
        for (uint256 s; s < spins; ++s) { vm.warp(vm.getBlockTimestamp() + 10 * GAP_UNIT); _probe(); }
        (, uint256 unlock,,) = staking.lockInfoOf(t);
        vm.warp(unlock - 1);
        _probe();
        assertTrue(staking.isTrackedLocker(t), "setup: the target was normalised before it elapsed");
        vm.warp(unlock);
        assertEq(staking.lockSweepBudget(), 1, "setup: one probe per transaction");
    }

    /// n borrowers on 10k each; `v` borrows all it may and the others one token. Time runs, a year
    /// at a time, until a keeper's `liquidate(v)` stops refusing.
    function _openBorrowers(uint256 n, uint256 v) internal returns (address who) {
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        for (uint256 i; i < n; ++i) {
            address a = _a(0xB0000, i);
            _fund(a);
            vm.prank(a);
            staking.deposit(10_000e18, 90);
        }
        vm.roll(vm.getBlockNumber() + 11);
        for (uint256 i; i < n; ++i) {
            address a = _a(0xB0000, i);
            uint256 amt = i == v ? staking.maxBorrowOf(a) : 1e18;
            vm.prank(a);
            staking.borrow(amt);
        }
        who = _a(0xB0000, v);
        for (uint256 y; y < 400 && !_seizable(who); ++y) vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.roll(vm.getBlockNumber() + 30);
        assertTrue(_seizable(who), "setup: the borrower never became seizable");
    }

    function _seizable(address who) internal returns (bool ok) {
        uint256 snap = vm.snapshot();
        vm.prank(keeper);
        try staking.liquidate(who) { ok = true; } catch {}
        vm.revertTo(snap);
    }

    function _lockSweptWithin(address t, uint256 probes) internal returns (bool gone) {
        uint256 snap = vm.snapshot();
        for (uint256 i; i < probes; ++i) _probe();
        gone = !staking.isTrackedLocker(t);
        vm.revertTo(snap);
    }

    function _seizedByNextProbe(address who) internal returns (bool gone) {
        uint256 snap = vm.snapshot();
        _probe();
        gone = !staking.isTrackedBorrower(who);
        vm.revertTo(snap);
    }
}

contract AtqSweepCursorTest is AtqSweepBase {
    // ── 1. lock window, stable registry ────────────────────────────────────────────────────────
    function test_AtqLockWindowReachesEveryElapsedLockWithinOneRotation_OnAStableRegistry() public {
        uint256[3] memory sizes = [uint256(1), 3, 12];
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            for (uint256 t; t < n; ++t) {
                uint256 snap = vm.snapshot();
                address target = _openLockers(n, t, 7);
                uint256 probes;
                while (staking.isTrackedLocker(target) && probes <= n) { _probe(); ++probes; }
                assertFalse(staking.isTrackedLocker(target), "an elapsed lock outlived a whole rotation");
                assertLe(probes, n, "more probes than registry entries");
                assertEq(staking.activeLockerCount(), n - 1, "a committed lock left the registry");
                (uint256 daysLeft,,, ) = staking.lockInfoOf(target);
                assertEq(daysLeft, 0, "normalised without clearing the commitment");
                assertFalse(staking.hasStaleBoost(target), "normalised but still boosted");
                vm.revertTo(snap);
            }
        }
    }

    // ── 2. at most four lock actions per transaction ───────────────────────────────────────────
    function test_AtqLockWindowNormalisesAtMostFourLocksPerTransaction() public {
        uint256 n = 11;
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        for (uint256 i; i < n; ++i) {
            address a = _a(0x10C000, i);
            _fund(a);
            vm.prank(a);
            staking.deposit(10_000e18, 90);
        }
        (, uint256 unlock,,) = staking.lockInfoOf(_a(0x10C000, 0));
        vm.warp(unlock - 1);
        _probe();
        vm.warp(unlock);
        uint256[3] memory left = [uint256(7), 3, 0];
        for (uint256 k; k < 3; ++k) {
            uint256 before = staking.totalLockSweeps();
            _probe();
            assertEq(staking.activeLockerCount(), left[k], "lock actions in one transaction");
            assertEq(staking.totalLockSweeps() - before, k == 2 ? 3 : 4, "sweeps counted");
        }
    }

    // ── 3. the budget ladder ───────────────────────────────────────────────────────────────────
    function _budget(uint256 len, uint256 gap) internal pure returns (uint256 c) {
        if (len == 0) return 0;
        c = 1 + len / 50 + gap / GAP_UNIT;
        if (c > 10) c = 10;
        if (c > len) c = len;
    }

    function test_AtqWindowBudgetLadder_ByRegistryLengthAndGap() public {
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        uint256[9] memory gaps = [uint256(0), GAP_UNIT - 1, GAP_UNIT, GAP_UNIT + 1, 2 * GAP_UNIT,
                                  8 * GAP_UNIT - 1, 9 * GAP_UNIT - 1, 9 * GAP_UNIT, 3650 days];
        assertEq(staking.lockSweepBudget(), 0, "empty registry");
        assertEq(staking.maintenanceBudget(), 0, "empty registry");
        uint256 made;
        uint256[10] memory lens = [uint256(1), 2, 9, 10, 11, 49, 50, 51, 100, 451];
        for (uint256 k; k < lens.length; ++k) {
            // dust positions: one wei and a lock is all a registry entry costs
            for (; made < lens[k]; ++made) {
                address a = _a(0xD0000, made);
                token.mint(a, 1);
                vm.startPrank(a);
                token.approve(address(staking), 1);
                staking.deposit(1, 2555);
                vm.stopPrank();
            }
            assertEq(staking.activeLockerCount(), lens[k], "a dust lock is a registry entry");
            uint256 last = staking.lastMaintTime();
            for (uint256 g; g < gaps.length; ++g) {
                uint256 snap = vm.snapshot();
                vm.warp(last + gaps[g]);
                assertEq(staking.lockSweepBudget(), _budget(lens[k], gaps[g]), "lock budget");
                assertEq(staking.maintenanceBudget(), 0, "no borrower, no borrower budget");
                vm.revertTo(snap);
            }
        }
    }

    // ── 4. borrower window, stable registry ────────────────────────────────────────────────────
    function test_AtqBorrowerWindowSeizesWithinOneRotationOfThirdPartyProbes_OnAStableRegistry() public {
        uint256 n = 6;
        for (uint256 v; v < n; ++v) {
            uint256 snap = vm.snapshot();
            address who = _openBorrowers(n, v);
            // spend the time budget on the borrower's own transaction, which never seizes its caller
            vm.prank(who);
            staking.claimRewards();
            assertTrue(staking.isTrackedBorrower(who), "the window seized its own caller");
            assertEq(staking.maintenanceBudget(), 1, "one probe per transaction");
            uint256 probes;
            uint256 before = staking.totalAutoLiquidations();
            while (staking.isTrackedBorrower(who) && probes <= n) { _probe(); ++probes; }
            assertFalse(staking.isTrackedBorrower(who), "a seizable borrower outlived a whole rotation");
            assertLe(probes, n, "more probes than registry entries");
            assertEq(staking.totalAutoLiquidations() - before, 1, "exactly the seizable one was seized");
            assertEq(staking.activeBorrowerCount(), n - 1, "a healthy borrower left the registry");
            vm.revertTo(snap);
        }
    }
}
