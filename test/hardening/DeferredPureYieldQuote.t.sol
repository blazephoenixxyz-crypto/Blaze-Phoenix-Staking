// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice DEFER-QUOTE. A credit has one getter. Pure yield settled under a hard breach is not
///         paid: it becomes a credit in `_rewardDeferred`, whose one payer is the reward settle
///         and whose one quote is `pendingRewards`. From that settle on `pendingPureYield` reads
///         only the un-settled share (0 right after it), `pendingRewards` reads the credit, and
///         the two still sum to what a claim pays.
///
///         Oracle: the quotes read before the deferral, and the token balance a claim moves once
///         the breach is gone. No emission is funded, so every wei `pendingRewards` shows after
///         the deferral is the deferred pure yield.
contract DeferredPureYieldQuoteTest is Base {
    uint256 internal constant S = 10_000_000e18;

    /// Pure staker bob beside borrower alice; `idleDays` later a shortfall of `missing` opens a
    /// hard breach and bob relocks, a door that stays open under a breach and settles him.
    function _deferAndClaim(uint256 idleDays, uint256 missing) internal {
        vm.prank(alice); staking.deposit(S, 90);
        vm.prank(bob);   staking.deposit(S, 90);
        vm.roll(block.number + 11);
        uint256 maxB = staking.maxBorrowOf(alice);
        vm.prank(alice); staking.borrow(maxB);

        vm.warp(block.timestamp + idleDays * 1 days);
        uint256 pureBefore = staking.pendingPureYield(bob);
        assertGt(pureBefore, 0, "fixture: bob has pending pure yield");
        assertEq(staking.pendingRewards(bob), 0, "fixture: no emission funded, nothing quoted there");

        deal(address(token), address(staking), token.balanceOf(address(staking)) - missing);
        assertFalse(staking.isSolvent(), "fixture: the breach is real");

        uint256 bal = token.balanceOf(bob);
        vm.prank(bob); staking.lock(90);
        assertEq(token.balanceOf(bob), bal, "pure yield paid at par into a breach");

        assertEq(staking.pendingPureYield(bob), 0, "pure quote still shows the settled share");
        assertEq(staking.pendingRewards(bob), pureBefore, "emission quote absorbed the deferred pure yield");
        (, , , , , , uint256 infoRewards, uint256 infoPure, , , , , , ) = staking.getUserInfo(bob);
        assertEq(infoPure, 0, "getUserInfo: pure yield still shows the settled share");
        assertEq(infoRewards, pureBefore, "getUserInfo: rewards do not carry the deferred credit");

        deal(address(token), address(staking), token.balanceOf(address(staking)) + missing);
        assertTrue(staking.isSolvent(), "fixture: the breach cleared");
        uint256 quoted = staking.pendingRewards(bob) + staking.pendingPureYield(bob);
        bal = token.balanceOf(bob);
        vm.prank(bob); staking.claimRewards();
        assertEq(token.balanceOf(bob) - bal, quoted, "the two quotes did not sum to what the claim paid");
        assertEq(quoted, pureBefore, "the claim is not the pure yield quoted before the deferral");
    }

    /// 120 days, 1,000 BZPX missing: the credit is 35,701.708265784847747 BZPX.
    function test_DEFER_pureCreditIsQuotedByPendingRewards() public {
        _deferAndClaim(120, 1_000e18);
    }

    /// Ranges: 91..365 idle days (bob's 90-day lock has lapsed), 1 wei above the dust tolerance
    /// to 100,000 BZPX missing.
    function testFuzz_DEFER_pureCreditIsQuotedByPendingRewards(uint256 idleDays, uint256 missing) public {
        _deferAndClaim(bound(idleDays, 91, 365), bound(missing, 1e10 + 1, 100_000e18));
    }
}
