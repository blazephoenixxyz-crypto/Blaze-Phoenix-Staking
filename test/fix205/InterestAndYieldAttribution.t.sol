// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice Attribution of emission and pure yield across interest accrual, lock expiry and
///         uncollectible interest. Each test states the property it checks and the oracle used.
///         Every test here but EMIS-INT (fixed, 3256-P1-C) is a `documents` test: the items are
///         left for an owner decision (see the pull request), so each pins the current behaviour,
///         asserts its direction and logs the measured size. A fix flips the documented assertion
///         and turns the test red.
contract InterestAndYieldAttributionTest is Base {
    uint256 internal constant STAKE = 1_000_000e18;
    uint256 internal constant DUST = 1e10;

    // ─────────────────────────────────────────────────────────────────────────────────────
    // LOCK-STALE (documents). `_settlePendingRewards` pays with `trackedBoostedEffective`,
    // which only drops when the position is resynced (own action, poke, or sweep). An expired
    // lock that nobody touches keeps earning at its historical multiplier.
    // Oracle: scenario X (no touch until the final claim) vs scenario Y (the lock is poked at
    // the exact unlock instant). Same final claim instant in both. X - Y > 0 and grows with
    // the length of the un-touched tail.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function _lockStaleScenario(uint256 tail, bool pokeAtExpiry)
        internal
        returns (uint256 aliceGain, uint256 tailEmission)
    {
        (, uint256 aliceUnlock,,) = staking.lockInfoOf(alice);
        uint256 endT = aliceUnlock + tail;
        uint256 bal0 = token.balanceOf(alice);
        if (pokeAtExpiry) {
            vm.warp(aliceUnlock);
            vm.prank(keeper);
            staking.pokeExpiredLock(alice);
        }
        vm.warp(endT);
        vm.prank(alice);
        staking.claimRewards();
        aliceGain = token.balanceOf(alice) - bal0;
        tailEmission = staking.emittedAt(endT) - staking.emittedAt(aliceUnlock);
    }

    function test_LOCKSTALE_documents_expiredLockOverEarnsUntilTouched() public {
        vm.prank(admin);
        staking.fundEmission(180_000_000e18);
        vm.prank(alice);
        staking.deposit(STAKE, 365);
        vm.prank(bob);
        staking.deposit(STAKE, 90);

        uint256 snap = vm.snapshotState();
        (uint256 x1, uint256 e1) = _lockStaleScenario(365 days, false);
        vm.revertToState(snap);
        (uint256 y1,) = _lockStaleScenario(365 days, true);
        vm.revertToState(snap);
        (uint256 x2, uint256 e2) = _lockStaleScenario(3 * 365 days, false);
        vm.revertToState(snap);
        (uint256 y2,) = _lockStaleScenario(3 * 365 days, true);

        assertGt(x1, y1, "un-touched expired lock should over-earn (1y tail)");
        assertGt(x2, y2, "un-touched expired lock should over-earn (3y tail)");
        uint256 d1 = x1 - y1;
        uint256 d2 = x2 - y2;
        assertGt(d2, d1, "over-earning grows with the un-touched tail");

        emit log_named_decimal_uint("tail 1y: X (no touch)   ", x1, 18);
        emit log_named_decimal_uint("tail 1y: Y (poked)      ", y1, 18);
        emit log_named_decimal_uint("tail 1y: delta tokens   ", d1, 18);
        emit log_named_decimal_uint("tail 1y: tail emission  ", e1, 18);
        emit log_named_uint("tail 1y: delta bps of tail emission", d1 * 10_000 / e1);
        emit log_named_decimal_uint("tail 3y: delta tokens   ", d2, 18);
        emit log_named_decimal_uint("tail 3y: tail emission  ", e2, 18);
        emit log_named_uint("tail 3y: delta bps of tail emission", d2 * 10_000 / e2);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // EMIS-INT (3256-P1-C). Interest is attributed lazily, so between touches a borrower's
    // tracked emission weight is stale high by the interest charged. The settle pays the window
    // at the LIVE weight (`_atLiveWeight`: the weight the post-interest equity commands under the
    // tracked lock) and returns the stale-weight excess, never earned, to `rewardReserve`. The
    // quote routes through the same helper, so `pendingRewards` is the payment.
    // Oracle (independent of the contract's arithmetic): window emission E from `emittedAt`, net
    // stakes from `effectiveStakeOf` before (wA_pre, wB) and after (wA_post) the claim. Equal
    // locks, so the boost cancels. The window integrated the per-unit rate E / (wA_pre + wB), so
    // the claim is E * wA_post / (wA_pre + wB) within dust, and the reserve gets back
    // E * wA_pre / (wA_pre + wB) - claim. Every unit of live weight earns the same rate: the
    // claim is the pure staker's window times wA_post / wB.
    // Red at 8cc2b65: the settle paid the pre-interest share, 153 bps (1y) and 845 bps (5y) over
    // the post-interest share at max LTV, untouched.
    // Residual (logged, not asserted): a lazy window's per-unit rate is set by the stale
    // denominator, which no O(1) settle corrects; every staker is paid at that rate, so the claim
    // sits below the post-interest share E * wA_post / (wA_post + wB) and the difference stays in
    // the reserve.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function _emisIntWindow(uint256 window)
        internal
        returns (uint256 claimed, uint256 boundPost)
    {
        // Window bounds are read from contract state, not from `block.timestamp` in this frame
        // (via-IR may re-read the timestamp after `vm.warp`).
        uint256 tStart = staking.lastRewardTime();
        uint256 bobQ0 = staking.pendingRewards(bob);
        vm.warp(tStart + window);
        uint256 eA0 = staking.effectiveStakeOf(alice);
        uint256 eB = staking.effectiveStakeOf(bob);
        uint256 quoted = staking.pendingRewards(alice);
        uint256 r0 = staking.rewardReserve();
        uint256 bal0 = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards();
        claimed = token.balanceOf(alice) - bal0;
        uint256 tEnd = staking.lastRewardTime();
        assertEq(tEnd - tStart, window, "window bounds");
        uint256 e = staking.emittedAt(tEnd) - staking.emittedAt(tStart);
        uint256 eA1 = staking.effectiveStakeOf(alice);
        assertEq(staking.effectiveStakeOf(bob), eB, "pure staker weight unchanged");
        assertLt(eA1, eA0, "interest was charged against the borrower's collateral");
        uint256 atLive = e * eA1 / (eA0 + eB);
        uint256 atTracked = e * eA0 / (eA0 + eB);
        boundPost = e * eA1 / (eA1 + eB);
        emit log_named_decimal_uint("window emission E        ", e, 18);
        emit log_named_decimal_uint("wA pre-interest          ", eA0, 18);
        emit log_named_decimal_uint("wA post-interest         ", eA1, 18);
        emit log_named_decimal_uint("wB                       ", eB, 18);
        emit log_named_decimal_uint("claimed(A)               ", claimed, 18);
        emit log_named_decimal_uint("at live weight (oracle)  ", atLive, 18);
        emit log_named_decimal_uint("at tracked weight        ", atTracked, 18);
        emit log_named_decimal_uint("post-interest share      ", boundPost, 18);
        assertEq(quoted, claimed, "pendingRewards quotes the payment");
        assertApproxEqAbs(claimed, atLive, DUST, "the window is paid at the live weight");
        // Per unit of live weight the borrower earns what the debt-free staker earns in the window.
        assertApproxEqAbs(claimed, (staking.pendingRewards(bob) - bobQ0) * eA1 / eB, DUST,
            "the borrower earns the pure staker's per-unit rate");
        // The reserve funded E for the window and got the stale-weight excess back.
        assertApproxEqAbs(staking.rewardReserve() + e, r0 + atTracked - claimed, DUST,
            "the stale-weight excess returns to rewardReserve");
    }

    function test_EMISINT_borrowerWindowIsPaid_atLiveWeight() public {
        vm.prank(admin);
        staking.fundEmission(180_000_000e18);
        vm.prank(alice);
        staking.deposit(STAKE, 2555);
        vm.prank(bob);
        staking.deposit(STAKE, 2555);
        vm.roll(block.number + 11);
        uint256 maxB = staking.maxBorrowOf(alice);
        vm.prank(alice);
        staking.borrow(maxB);
        emit log_named_decimal_uint("borrowed (near MAX_LTV)  ", maxB, 18);

        uint256 snap = vm.snapshotState();
        (uint256 c1, uint256 post1) = _emisIntWindow(365 days);
        vm.revertToState(snap);
        (uint256 c5, uint256 post5) = _emisIntWindow(5 * 365 days);
        emit log_named_uint("1y: claim below the post-interest share, bps", c1 < post1 ? (post1 - c1) * 10_000 / post1 : 0);
        emit log_named_uint("5y: claim below the post-interest share, bps", c5 < post5 ? (post5 - c5) * 10_000 / post5 : 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // Shared book for OWED-FCFS and PURE-UNCOLL: two equal pure stakers and one borrower
    // whose interest, left un-touched for a very long time, outgrows her collateral. The
    // uncollectible part is recorded as `totalBadDebt`, yet the full slice was already
    // credited to the pure-yield accumulator by `_updateInterestIndex`.
    // ─────────────────────────────────────────────────────────────────────────────────────
    struct Book {
        uint256 grossClaims;     // sum of pure stakes + projected pending pure yield, pre-touch
        uint256 backingPre;
        uint256 backingPost;
        uint256 badDebt;
        uint256 owedPost;
        bool solventPost;
        uint256 aliceGain;       // net of principal recovered
        uint256 bobGain;         // net of principal recovered
        bool aliceExit;
        bool bobExit;
        bool solventBeforeBob;
    }

    function _exit(address who) internal returns (bool ok, uint256 principalBack) {
        vm.prank(who);
        try staking.claimPureYield() {} catch {}
        (uint256 staked,,,,,,,,,,,,,) = staking.getUserInfo(who);
        if (staked == 0) return (true, 0);
        vm.prank(who);
        try staking.withdraw(staked) {
            ok = true;
            principalBack = staked;
        } catch (bytes memory err) {
            // Expected: Staking__TransferFailed from settling the credited pure yield.
            emit log_named_bytes("withdraw revert data", err);
        }
    }

    function _uncollectibleBook() internal returns (Book memory b) {
        vm.prank(alice);
        staking.deposit(STAKE, 90);
        vm.prank(bob);
        staking.deposit(STAKE, 90);
        vm.prank(carol);
        staking.deposit(STAKE, 90);
        vm.roll(block.number + 11);
        uint256 maxB = staking.maxBorrowOf(carol);
        vm.prank(carol);
        staking.borrow(maxB);
        vm.roll(block.number + 11);

        vm.warp(block.timestamp + 1000 * 365 days);

        b.grossClaims = 2 * STAKE + staking.pendingPureYield(alice) + staking.pendingPureYield(bob);
        b.backingPre = staking.backing();

        uint256 a0 = token.balanceOf(alice);
        uint256 bo0 = token.balanceOf(bob);

        // One neutral touch: the borrower window of `_autoMaintain` reaches carol.
        vm.prank(keeper);
        staking.claimRewards();

        b.badDebt = staking.totalBadDebt();
        b.owedPost = staking.owed();
        b.backingPost = staking.backing();
        b.solventPost = staking.isSolvent();

        uint256 pa;
        uint256 pb;
        (b.aliceExit, pa) = _exit(alice);
        b.solventBeforeBob = staking.isSolvent();
        (b.bobExit, pb) = _exit(bob);

        b.aliceGain = token.balanceOf(alice) - a0 - pa;
        b.bobGain = token.balanceOf(bob) - bo0 - pb;

        emit log_named_decimal_uint("borrowed by carol        ", maxB, 18);
        emit log_named_decimal_uint("grossClaims (pre-touch)  ", b.grossClaims, 18);
        emit log_named_decimal_uint("backing (pre-touch)      ", b.backingPre, 18);
        emit log_named_decimal_uint("backing (post-touch)     ", b.backingPost, 18);
        emit log_named_decimal_uint("owed (post-touch)        ", b.owedPost, 18);
        emit log_named_decimal_uint("totalBadDebt             ", b.badDebt, 18);
        emit log_named_decimal_uint("totalInterestAccruedGlob ", staking.totalInterestAccruedGlobal(), 18);
        emit log_named_decimal_uint("totalUncollectedInterest ", staking.totalUncollectedInterest(), 18);
        emit log_named_decimal_uint("alice pure yield received", b.aliceGain, 18);
        emit log_named_decimal_uint("bob pure yield received  ", b.bobGain, 18);
        emit log_named_string("alice exit", b.aliceExit ? "ok" : "REVERTED");
        emit log_named_string("bob exit  ", b.bobExit ? "ok" : "REVERTED");
        emit log_named_string("isSolvent before bob", b.solventBeforeBob ? "true" : "false");
    }

    // OWED-FCFS. Oracle: if the protocol reports itself solvent, every pure staker can exit
    // with principal and credited yield. Uncovered bad debt is a claim the contract cannot pay,
    // so `_owed()` counts it: `isSolvent()` reads false, the full-value exit closes for everyone
    // (no first-come-first-served), and the permissionless breaker opens the pro-rata exit.
    // Before the fix `_owed()` netted `totalBadDebt` out, the flag read true, the first pure
    // staker exited whole and the second could not exit at all.
    function test_OWEDFCFS_uncoveredLossReadsInsolventAndExitIsProRata() public {
        Book memory b = _uncollectibleBook();
        assertGt(b.badDebt, 0, "setup: uncollectible interest must be recorded as bad debt");
        assertGt(b.grossClaims, b.backingPre, "setup: pure claims exceed backing");
        assertFalse(b.solventPost, "uncovered bad debt reads insolvent");
        assertFalse(b.aliceExit, "no full-value exit for the first staker");
        assertFalse(b.bobExit, "nor for the second");
        vm.prank(keeper);
        staking.tripBreaker();
        uint256 pot = staking.backing();
        uint256 a0 = token.balanceOf(alice);
        uint256 bo0 = token.balanceOf(bob);
        vm.prank(alice);
        staking.emergencyWithdraw();
        vm.prank(bob);
        staking.emergencyWithdraw();
        uint256 pa = token.balanceOf(alice) - a0;
        uint256 pb = token.balanceOf(bob) - bo0;
        assertApproxEqAbs(pa, pb, 1e10, "equal principals exit equal, whatever the order");
        assertLe(pa + pb, pot, "never more than the pot");
    }

    // PURE-UNCOLL. Oracle: pure stakers can be paid at most the pool share (1 - reserve
    // factor) of the interest that was actually collected from borrowers,
    // totalInterestAccruedGlobal - totalUncollectedInterest. Before the fix the keeper's touch
    // booked the loss and the same transaction's lock window then paid alice 1,455,000 BZPX at
    // par. `_settlePendingPureYield` now refuses to pay while the book reads a hard breach.
    // Residual below the clamp: test/hardening/PureYieldNeverFromUncollected.t.sol.
    function test_PUREUNCOLL_pureYieldPaidNeverExceedsCollectedInterest() public {
        Book memory b = _uncollectibleBook();
        uint256 collected = staking.totalInterestAccruedGlobal() - staking.totalUncollectedInterest();
        uint256 poolShare = collected * 9_700 / 10_000;
        uint256 paid = b.aliceGain + b.bobGain;
        emit log_named_decimal_uint("interest collected       ", collected, 18);
        emit log_named_decimal_uint("pool share of collected  ", poolShare, 18);
        emit log_named_decimal_uint("pure yield paid          ", paid, 18);
        assertGt(staking.totalUncollectedInterest(), 0, "setup: some interest must be uncollectible");
        assertLe(paid, poolShare + DUST, "pure yield paid exceeds the pool share of collected interest");
    }
}
