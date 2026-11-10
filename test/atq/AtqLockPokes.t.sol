// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  atq-1111 (staking front) — elapsed locks: the pokes and the guards of `lock`
//
//  1. `pokeExpiredLock`: refused for a position that never locked and one second before the
//     unlock; at the unlock second it normalises exactly the named position, once; under a pause
//     (no window runs) it still normalises, through its own direct step.
//  2. `pokeExpiredLocks`: a batch with nothing elapsed is refused; a batch with one elapsed entry
//     among committed, unlocked and repeated ones normalises that one, once, and nothing else.
//  3. `lock`: refused without a stake and inside the flash-protection blocks, to the block.
//
//  Refusals are checked by selector. Paired mutants: [ATQ-staking-64..71].
//  Run: forge test --match-path test/atq/AtqLockPokes.t.sol
// =============================================================================

import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";

contract AtqLockPokesTest is Base {
    uint256 internal unlock;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        staking.fundEmission(1_000_000e18);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.stopPrank();
        vm.prank(alice);
        staking.deposit(10_000e18, 90);
        vm.prank(bob);
        staking.deposit(10_000e18, 365);
        vm.roll(vm.getBlockNumber() + 11);
        (, unlock,,) = staking.lockInfoOf(alice);
    }

    function _one(address a) internal pure returns (address[] memory l) { l = new address[](1); l[0] = a; }

    function _assertNormalised(address who, uint256 sweepsBefore) internal view {
        (uint256 d, uint256 u,, ) = staking.lockInfoOf(who);
        assertEq(d, 0, "commitment not cleared");
        assertEq(u, 0, "unlock time not cleared");
        assertFalse(staking.isTrackedLocker(who), "still in the locker registry");
        assertFalse(staking.hasStaleBoost(who), "still boosted");
        assertEq(staking.totalLockSweeps() - sweepsBefore, 1, "normalised other than exactly once");
    }

    function _assertBobUntouched() internal view {
        (uint256 d,,, ) = staking.lockInfoOf(bob);
        assertEq(d, 365, "a committed lock was touched");
        assertTrue(staking.isTrackedLocker(bob), "a committed lock left the registry");
    }

    // ── 1. the single poke ─────────────────────────────────────────────────────────────────────
    function test_AtqPokeExpiredLock_RefusedUntilTheUnlockSecond_ThenExactlyOnce() public {
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoLock.selector);
        staking.pokeExpiredLock(carol);                       // never locked, never staked
        vm.warp(unlock - 1);
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__StillLocked.selector);
        staking.pokeExpiredLock(alice);
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__StillLocked.selector);
        staking.pokeExpiredLock(bob);
        vm.warp(unlock);
        uint256 before = staking.totalLockSweeps();
        vm.prank(keeper);
        staking.pokeExpiredLock(alice);
        _assertNormalised(alice, before);
        _assertBobUntouched();
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoLock.selector);
        staking.pokeExpiredLock(alice);                       // nothing left to normalise
    }

    function test_AtqPokeExpiredLock_StillNormalisesUnderAPause() public {
        vm.warp(unlock);
        vm.prank(keeper);
        staking.pause();
        assertTrue(staking.hasStaleBoost(alice), "vacuous: nothing stale to release");
        uint256 before = staking.totalLockSweeps();
        vm.prank(carol);
        staking.pokeExpiredLock(alice);
        _assertNormalised(alice, before);
        _assertBobUntouched();
    }

    // ── 2. the batch poke ──────────────────────────────────────────────────────────────────────
    function test_AtqPokeExpiredLocks_RefusesABatchWithNothingElapsed_AndActsOnceOnTheOneThatIs() public {
        address[] memory batch = new address[](5);
        batch[0] = bob; batch[1] = alice; batch[2] = carol; batch[3] = alice; batch[4] = address(0);

        vm.warp(unlock - 1);
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoLock.selector);
        staking.pokeExpiredLocks(batch);                      // alice is one second short

        vm.warp(unlock);
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoLock.selector);
        staking.pokeExpiredLocks(_one(bob));                  // committed
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoLock.selector);
        staking.pokeExpiredLocks(_one(carol));                // never locked
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoLock.selector);
        staking.pokeExpiredLocks(new address[](0));           // empty

        uint256 before = staking.totalLockSweeps();
        vm.prank(keeper);
        staking.pokeExpiredLocks(batch);                      // the unlock second itself counts as elapsed
        _assertNormalised(alice, before);
        _assertBobUntouched();
    }

    // ── 3. the guards of `lock` ────────────────────────────────────────────────────────────────
    function test_AtqLock_RefusedWithoutAStake_AndInsideTheFlashBlocks() public {
        vm.prank(carol);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoStake.selector);
        staking.lock(180);
        assertFalse(staking.isTrackedLocker(carol), "an empty position entered the registry");

        vm.prank(carol);
        staking.deposit(10_000e18, 90);
        uint256 at = vm.getBlockNumber();
        vm.prank(carol);
        vm.expectRevert(BlazePhoenixStaking.Staking__FlashLoanProtection.selector);
        staking.lock(180);
        vm.roll(at + 10);
        vm.prank(carol);
        vm.expectRevert(BlazePhoenixStaking.Staking__FlashLoanProtection.selector);
        staking.lock(180);
        vm.roll(at + 11);
        vm.prank(carol);
        staking.lock(180);
        (uint256 d,,, ) = staking.lockInfoOf(carol);
        assertEq(d, 180, "the lock did not take");
    }
}
