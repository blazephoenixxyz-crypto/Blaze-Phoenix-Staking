// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice R3 (docs/INVARIANTS_AND_TIME.md): a multiplier is the price of the commitment the
///         capital it pays actually carries. A lock is paid at the term it committed to for the
///         whole term (a seven-year lock with 555 days left is still paid at seven years, a fresh
///         555-day lock at 555 days), and principal added under a longer existing lock re-keys the
///         whole position to the days that remain, so no capital is priced at a commitment it did
///         not make. Green on 82febb5 and here. Red with the re-key deleted (the mutant registered
///         in mutants.py; the `LockSet` event alone does not see it).
contract CommitmentPricingTest is Base {
    uint256 internal constant S = 1_000_000e18;

    function test_AMultiplierPaysTheCommitmentMadeAndATopUpRekeysToWhatRemains() public {
        vm.prank(alice); staking.deposit(S, 2555);
        (, uint256 unlockA, , ) = staking.lockInfoOf(alice);
        vm.warp(vm.getBlockTimestamp() + 2000 days); vm.roll(block.number + 11);
        uint256 rem = (unlockA - this.clockTs()) / 1 days;
        assertEq(rem, 555, "fixture: 555 days remain");
        (, , uint256 bpsA, ) = staking.lockInfoOf(alice);
        assertEq(bpsA, staking.boostByDays(2555), "an aged lock is paid the term it committed to");

        vm.prank(bob); staking.deposit(S, rem);
        (, uint256 unlockB, uint256 bpsB, ) = staking.lockInfoOf(bob);
        assertEq(unlockB, unlockA, "fixture: the fresh lock ends with the aged one");
        assertEq(bpsB, staking.boostByDays(rem), "a fresh lock is paid its own term");
        assertGt(bpsA, bpsB, "same principal and unlock, different commitments, different prices");

        vm.prank(alice); staking.deposit(1e18, 90);
        (uint256 dA, uint256 unlockA2, uint256 bpsA2, ) = staking.lockInfoOf(alice);
        assertEq(unlockA2, unlockA, "a shorter top-up keeps the existing unlock");
        assertEq(dA, rem, "new principal re-keys the position to the days that remain");
        assertEq(bpsA2, staking.boostByDays(rem), "and the whole position is priced at what it now carries");
        uint256 b = staking.boostByDays(rem);
        assertEq(staking.totalBoostedEffective(),
            staking.effectiveStakeOf(alice) * b / 10_000 + staking.effectiveStakeOf(bob) * b / 10_000,
            "the tracked weights follow the re-key");
    }

    // A second read of the clock goes through an external call: via_ir may re-read TIMESTAMP for
    // a local after vm.warp.
    function clockTs() external view returns (uint256) { return block.timestamp; }
}
