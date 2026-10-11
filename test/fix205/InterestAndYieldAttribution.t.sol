// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice Attribution of emission and pure yield across interest accrual, lock expiry and
///         uncollectible interest. Each test states the property it checks and the oracle used.
///         Tests named `documents` describe accepted current behaviour and pass; the others
///         assert the intended property and are expected to fail until it is fixed.
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
    // EMIS-INT. In `claimRewards` the emission settle runs before `_accrueInterestFor`, so a
    // borrower is paid for the whole un-touched window at its PRE-interest effective stake.
    // Oracle: the borrower's emission share over the window must not exceed the share implied
    // by its POST-interest effective stake, E * wA_post / (wA_post + wB). The fair
    // time-weighted value lies between that bound and the pre-interest share; the test logs
    // both bounds and the claimed amount.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function _emisIntWindow(uint256 window)
        internal
        returns (uint256 claimed, uint256 boundPost, uint256 boundPre)
    {
        // Window bounds are read from contract state, not from `block.timestamp` in this frame
        // (via-IR may re-read the timestamp after `vm.warp`).
        uint256 tStart = staking.lastRewardTime();
        vm.warp(tStart + window);
        uint256 eA0 = staking.effectiveStakeOf(alice);
        uint256 eB = staking.effectiveStakeOf(bob);
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
        emit log_named_decimal_uint("window emission E        ", e, 18);
        emit log_named_decimal_uint("wA pre-interest          ", eA0, 18);
        emit log_named_decimal_uint("wA post-interest         ", eA1, 18);
        emit log_named_decimal_uint("wB                       ", eB, 18);
        boundPost = e * eA1 / (eA1 + eB);
        boundPre = e * eA0 / (eA0 + eB);
    }

    function test_EMISINT_borrowerEmissionShareUsesPreInterestWeight() public {
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

        uint256 snap = vm.snapshotState();
        (uint256 c1, uint256 post1, uint256 pre1) = _emisIntWindow(365 days);
        vm.revertToState(snap);
        (uint256 c5, uint256 post5, uint256 pre5) = _emisIntWindow(5 * 365 days);

        emit log_named_decimal_uint("borrowed (near MAX_LTV)  ", maxB, 18);
        emit log_named_decimal_uint("1y: claimed(A)           ", c1, 18);
        emit log_named_decimal_uint("1y: bound post-interest  ", post1, 18);
        emit log_named_decimal_uint("1y: bound pre-interest   ", pre1, 18);
        emit log_named_uint("1y: excess over post bound, bps", c1 > post1 ? (c1 - post1) * 10_000 / post1 : 0);
        emit log_named_decimal_uint("5y: claimed(A)           ", c5, 18);
        emit log_named_decimal_uint("5y: bound post-interest  ", post5, 18);
        emit log_named_decimal_uint("5y: bound pre-interest   ", pre5, 18);
        emit log_named_uint("5y: excess over post bound, bps", c5 > post5 ? (c5 - post5) * 10_000 / post5 : 0);

        assertLe(c1, post1 + DUST, "EMIS-INT: borrower paid emission above its post-interest share (1y)");
        assertLe(c5, post5 + DUST, "EMIS-INT: borrower paid emission above its post-interest share (5y)");
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
    // with principal and credited yield. Today the uncollectible interest credited as pure
    // yield is netted out of `_owed()` through `totalBadDebt`, so `isSolvent()` stays true
    // while the claims exceed the backing and are paid first-come-first-served.
    function test_OWEDFCFS_solventFlagWhilePureStakerCannotExit() public {
        Book memory b = _uncollectibleBook();
        assertGt(b.badDebt, 0, "setup: uncollectible interest must be recorded as bad debt");
        assertGt(b.grossClaims, b.backingPre, "setup: pure claims exceed backing");
        assertTrue(
            !b.solventBeforeBob || (b.aliceExit && b.bobExit),
            "OWED-FCFS: isSolvent() is true but a pure staker cannot exit"
        );
    }

    // PURE-UNCOLL. Oracle: pure stakers can be paid at most the pool share (1 - reserve
    // factor) of the interest that was actually collected from borrowers,
    // totalInterestAccruedGlobal - totalUncollectedInterest. Today the full slice, including
    // the uncollectible shortfall, is credited and paid out.
    function test_PUREUNCOLL_pureYieldPaidExceedsCollectedInterest() public {
        Book memory b = _uncollectibleBook();
        uint256 collected = staking.totalInterestAccruedGlobal() - staking.totalUncollectedInterest();
        uint256 poolShare = collected * 9_700 / 10_000;
        uint256 paid = b.aliceGain + b.bobGain;
        emit log_named_decimal_uint("interest collected       ", collected, 18);
        emit log_named_decimal_uint("pool share of collected  ", poolShare, 18);
        emit log_named_decimal_uint("pure yield paid          ", paid, 18);
        assertGt(staking.totalUncollectedInterest(), 0, "setup: some interest must be uncollectible");
        assertLe(paid, poolShare + DUST, "PURE-UNCOLL: pure yield paid exceeds the pool share of collected interest");
    }
}
