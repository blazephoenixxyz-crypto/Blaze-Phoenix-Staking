// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  PARITY, FUZZED — the quote a view publishes is what the executor pays, on
//  random books, not only on the fixed books of fix205/ViewsQuoteEqualsExecution.
//
//  Two producers of one quantity, asserted equal on the same block (method of
//  bp-dex SHARED_QUANTITIES.md, "Parity" family in TESTING.md):
//    Q1  pendingRewards + pendingPureYield  vs  what claimRewards() transfers
//    Q2  the same two quotes                 vs  what claimPureYield() transfers
//        (both executors settle both channels: claimRewards :808, claimPureYield :818)
//  and one round-trip relation:
//    RT  a debt-free staker who deposits, waits past the unlock and withdraws
//        never ends with less than the principal (no hidden haircut on a sound
//        book).
//
//  The book: alice is a debt-free locker (the quoted position), carol is a
//  borrower at a fuzzed fraction of her LTV, so interest, pure yield and the
//  maintenance sweep all move between the deposit and the quote. Time is
//  fuzzed across lock expiry, so the stale-lock path (item 2) is crossed.
//
//  Toolchain note: the clock is read once; every second read of a balance or a
//  view goes through a distinct external helper (see BoundaryEquality.t.sol).
//
//  forge test --match-contract ViewsQuoteEqualsExecutionFuzz -vv
// =============================================================================

import {Base} from "./BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract ViewsQuoteEqualsExecutionFuzzTest is Base {
    struct Book { uint256 a; uint256 lockA; uint256 c; uint256 borrowBps; uint256 dt; }

    function _book(Book memory k) internal {
        uint256 t0 = this.clockTs();
        uint256 n0 = this.clockBlock();
        vm.prank(admin); staking.fundEmission(100_000_000e18);
        vm.prank(alice); staking.deposit(k.a, k.lockA);
        vm.prank(carol); staking.deposit(k.c, 90);
        uint256 debt = (k.c * 50 / 100) * k.borrowBps / 10_000;
        if (debt > 0) { vm.prank(carol); staking.borrow(debt); }
        vm.warp(t0 + k.dt);
        vm.roll(n0 + 11);
    }

    function _bound(Book memory k) internal pure returns (Book memory) {
        k.a         = bound(k.a, 1_000e18, 20_000_000e18);
        k.lockA     = bound(k.lockA, 90, 2555);
        k.c         = bound(k.c, 1_000e18, 20_000_000e18);
        k.borrowBps = bound(k.borrowBps, 0, 10_000);
        k.dt        = bound(k.dt, 1 hours, 3 * 365 days);
        return k;
    }

    /// Q1. claimRewards settles BOTH channels (emission and pure yield), so the transfer it makes
    /// is compared with the sum of the two quotes, in the same block.
    function testFuzz_PendingQuotesAreWhatClaimRewardsPays(Book memory k) public {
        k = _bound(k);
        _book(k);
        uint256 quoteR = staking.pendingRewards(alice);
        uint256 quoteY = staking.pendingPureYield(alice);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice); staking.claimRewards();
        uint256 paid = this.balOf(alice) - before;
        assertGt(quoteR, 0, "non-vacuous: emission reached the staker");
        assertEq(paid, quoteR + quoteY, "Q1: the reward and pure-yield quotes did not sum to what claimRewards paid");
    }

    /// Q2. pendingPureYield == the transfer claimPureYield makes, in the same block. claimPureYield
    /// also settles emission rewards, so the transfer is compared with the sum of both quotes.
    function testFuzz_PendingPureYieldIsWhatClaimPureYieldPays(Book memory k) public {
        k = _bound(k);
        k.borrowBps = bound(k.borrowBps, 1_000, 10_000);    // a borrower exists, so interest exists
        _book(k);
        uint256 quoteY = staking.pendingPureYield(alice);
        uint256 quoteR = staking.pendingRewards(alice);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice); staking.claimPureYield();
        uint256 paid = this.balOf(alice) - before;
        assertGt(quoteY, 0, "non-vacuous: interest reached the pure staker");
        assertEq(paid, quoteY + quoteR, "Q2: the pure-yield and reward quotes did not sum to what claimPureYield paid");
    }

    /// RT. A debt-free staker leaves with at least the principal.
    function testFuzz_DebtFreeRoundTripNeverLosesPrincipal(Book memory k) public {
        k = _bound(k);
        k.dt = bound(k.dt, k.lockA * 1 days, k.lockA * 1 days + 365 days);   // past the unlock
        uint256 before = token.balanceOf(alice);
        _book(k);
        vm.prank(alice); staking.withdraw(k.a);
        assertGe(this.balOf(alice), before, "RT: a debt-free round trip lost principal");
    }

    function balOf(address w) external view returns (uint256) { return token.balanceOf(w); }
    // via_ir may re-read TIMESTAMP/NUMBER for a local after vm.warp/vm.roll; an external call's
    // result cannot be rematerialised, so the start of the clock is captured through these.
    function clockTs() external view returns (uint256) { return block.timestamp; }
    function clockBlock() external view returns (uint256) { return block.number; }
}
