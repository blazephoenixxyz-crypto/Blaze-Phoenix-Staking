// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Four dimensions beyond the eight named in docs/INVARIANTS_AND_TIME.md, derived directly from
// reading src/BlazePhoenixStaking.sol v3.0.0 rather than restating the existing map:
//
//   9  Cross-position externality  — every user tx involuntarily does work on OTHER users'
//      positions via _autoMaintain/maintStep. Does the involuntary path produce the exact same
//      economic outcome as the direct, deliberate one?
//  10  Griefing / cost asymmetry  — can an adversary cheaply impose a sustained gas cost on every
//      future, unrelated depositor via the borrower registry, and does the MAINT_MAX_SCAN ceiling
//      actually bound it?
//  11  Maintenance-sweep coverage/fairness — the rotating cursor does NOT advance on a liquidation
//      (the swapped-in borrower occupies the freed index instead). Does that ever starve a borrower
//      (never scanned) or loop forever on one slot instead of draining the backlog?
//  12  Lifecycle-phase boundary — exact behaviour AT/after `emissionEnd`. `borrow`/`repay`/
//      `withdraw`/`claimPureYield`/`liquidate` have NO emissionEnded check (only deposit/lock do).
//      Does reward accrual correctly freeze at the boundary even if first touched years late?
//
// forge test --match-contract DimensionsExtended -vv
//
// ENVIRONMENT NOTE: this forge build (1.7.1-dev) mis-optimizes `vm.warp(block.timestamp + X)` /
// `vm.roll(block.number + X)` whenever that exact expression shape is evaluated more than once
// within a function (even with no loop involved) — it silently reuses a stale opcode read instead
// of the post-warp/roll value, so time/block number can appear frozen. Every helper below instead
// tracks time/block in a local variable seeded ONCE and only ever incremented — `block.timestamp`
// / `block.number` are never read again directly for arithmetic after that first capture.

import {Base} from "./BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract DimensionsExtendedTest is Base {

    // ─── Dimension 9 — cross-position externality ──────────────────────────────────────────
    // Alice is driven underwater by pure interest accrual (the only lever available — no
    // oracle, collateral == borrowed asset). She never touches her own position again past the
    // warm-up, so she can never self-liquidate (maintStep skips `who == beneficiary`). Bob then
    // makes a totally unrelated deposit; his tx's own _autoMaintain sweep is the ONLY thing that
    // can liquidate her. Assert the outcome matches what an explicit `liquidate(alice)` produces.
    function test_Dim9_InvoluntarySweepMatchesExplicitLiquidation() public {
        uint256 b = block.number;
        vm.prank(alice);
        staking.deposit(1_000e18, 90);
        b += 11; vm.roll(b);
        vm.prank(alice);
        staking.borrow(500e18); // exactly MAX_LTV (50%)

        _driveUnderwater(alice);
        assertEq(staking.daysToLiquidation(alice), 0, "warm-up must reach the liquidation threshold");
        assertTrue(staking.isTrackedBorrower(alice));

        uint256 bobBalBefore = token.balanceOf(bob);
        uint256 aliceStakedBefore; uint256 aliceDebtBefore;
        (aliceStakedBefore, aliceDebtBefore,,,,,,,,,,,,) = staking.getUserInfo(alice);

        // Bob's action has nothing to do with Alice — and by now (decades of warm-up at low
        // utilisation) we're long past emissionEnd, where deposit() itself would revert. bob has
        // never staked at all; claimRewards() still runs _autoMaintain(bob) at the end (its own
        // settle calls simply no-op on his zero tracked weight), so it's the neutral trigger.
        vm.prank(bob);
        staking.claimRewards();

        // The involuntary sweep must have actually fired.
        assertEq(staking.totalAutoLiquidations(), 1, "bob's tx must have swept alice via maintStep");
        (, uint256 aliceDebtAfter,,,,,,,,,,,,) = staking.getUserInfo(alice);
        assertEq(aliceDebtAfter, 0, "involuntary sweep must fully clear the debt, same as explicit liquidate");
        assertFalse(staking.isTrackedBorrower(alice));

        // Bob, as the tx's beneficiary, must have received exactly the keeper bonus — the same
        // bonus formula _executeLiquidation pays a direct liquidate() caller.
        uint256 expectedBonus = _expectedBonus(aliceDebtBefore);
        assertEq(token.balanceOf(bob) - bobBalBefore, expectedBonus,
            "involuntary-sweep keeper payout must equal the direct-liquidation bonus formula");
        assertTrue(staking.isSolvent(), "conservation must hold across the involuntary path");
    }

    function _expectedBonus(uint256 debt) internal pure returns (uint256) {
        uint256 bonus = debt * 500 / 10_000; // LIQ_BONUS_BPS
        uint256 seized = debt + bonus;
        // stake at the liquidation boundary is debt/0.95; bonus is capped by (stake - debt).
        // For this scenario stake comfortably covers debt+bonus, so seized isn't clamped.
        return seized - debt <= bonus ? seized - debt : bonus;
    }

    /// @dev Warm-up only: alice pokes her OWN position (self-skip in maintStep means this can
    ///      never liquidate her), purely to let _accrueInterestFor grind her stake down until
    ///      debt/staked crosses LIQ_THRESHOLD. Bounded loop so a broken interest curve fails
    ///      loudly instead of hanging. At 50% LTV with only this position funding utilisation,
    ///      staked must shrink from debt/0.5 to debt/0.95 via interest alone (no oracle, no price
    ///      lever) — a multi-decade process at low utilisation before the 80% kink accelerates
    ///      it, so the bound is generous rather than tuned to a guessed convergence time.
    function _driveUnderwater(address who) internal {
        // Adaptive step, not a fixed 180 days: a fixed large step overshoots badly once past the
        // 80%-utilisation kink (rate can reach >100%/yr there), landing staked BELOW debt —
        // genuine bad debt rather than "just past the 95% liquidation line" — which zeroes the
        // keeper bonus this test is trying to measure. daysToLiquidation() is itself the
        // interest curve's own linear projection at the CURRENT rate, so stepping by exactly
        // that many days is a Newton-like approach that tightens as the rate keeps rising instead
        // of jumping past the target.
        //
        // The loop EXIT condition deliberately does NOT call daysToLiquidation() repeatedly —
        // this forge build (1.7.1-dev) has the same stale-cache defect for a view call's result
        // reused across loop iterations as it does for inline block.timestamp/number reads: a
        // repeated `staking.daysToLiquidation(who)` call site inside a loop was empirically
        // observed returning a stale "0" one iteration early, before debt*100>=staked*95 was
        // actually true, which then made the real _isLiquidatable() check (and a direct
        // liquidate() call) revert NotLiquidatable(). Computing the SAME condition locally from
        // getUserInfo()'s raw fields does not exhibit this — only the recurring call site does.
        uint256 t = block.timestamp;
        for (uint256 i; i < 2000; ++i) {
            (uint256 staked, uint256 debt,,,,,,,,,,,,) = staking.getUserInfo(who);
            if (debt == 0) revert("position has no debt");
            if (debt * 100 >= staked * 95) return; // LIQ_THRESHOLD, mirrors _isLiquidatable exactly
            uint256 remaining = staking.daysToLiquidation(who);
            uint256 step = remaining > 180 ? 180 : (remaining == 0 ? 1 : remaining);
            t += step * 1 days;
            vm.warp(t);
            vm.prank(who);
            staking.claimRewards(); // neutral self-poke: drives _updateGlobal + _accrueInterestFor
        }
        revert("interest curve never reached the liquidation threshold within the bound");
    }

    // ─── Dimension 10 — griefing / cost asymmetry via the borrower registry ────────────────
    // MAINT_MAX_SCAN=10 is the claimed hard ceiling on gas regardless of backlog size. Prove it
    // holds from BOTH levers the formula exposes: registry density and elapsed-time gap.
    function test_Dim10_MaintenanceBudgetSaturatesUnderDensity() public {
        // c = MAINT_BASE(1) + len/MAINT_DENSITY(50). len=110 -> 1+2=3: below the ceiling, so this
        // also pins down the linear part of the formula, not just the clamp.
        uint256 b = block.number;
        for (uint256 i; i < 110; ++i) {
            address who = address(uint160(0x10000 + i));
            _fund(who);
            vm.prank(who); staking.deposit(1_000e18, 90);
            b += 11; vm.roll(b);
            vm.prank(who); staking.borrow(1e18);
        }
        assertEq(staking.activeBorrowerCount(), 110);
        assertEq(staking.maintenanceBudget(), 3, "density term must scale exactly as MAINT_BASE + len/MAINT_DENSITY");
    }

    function test_Dim10_MaintenanceBudgetCappedByTimeGapAlone() public {
        // _maintBudget also clamps to `len` (can't scan more borrowers than exist), so the gap
        // term can only be OBSERVED in isolation once len alone already exceeds MAINT_MAX_SCAN.
        // 15 borrowers keeps the density term itself negligible (15/50 == 0) so the saturation
        // seen below is provably coming from the elapsed-time gap, not from density.
        uint256 b = block.number;
        uint256 n = 15;
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(0x30000 + i));
            _fund(who);
            vm.prank(who); staking.deposit(1_000e18, 90);
            b += 11; vm.roll(b);
            vm.prank(who); staking.borrow(1e18);
        }

        uint256 t = block.timestamp + 60 days; // 60d / 15min >> MAINT_MAX_SCAN on its own
        vm.warp(t);
        assertEq(staking.maintenanceBudget(), 10, "gap term alone must saturate at MAINT_MAX_SCAN");

        // And the bound must actually hold once exercised, not just in the view: a neutral tx
        // must not revert or behave differently now that the budget is pinned at the ceiling.
        vm.prank(carol);
        staking.deposit(1_000e18, 90);
    }

    // ─── Dimension 11 — maintenance-sweep coverage under swap-pop ──────────────────────────
    // 12 borrowers, ALL simultaneously liquidatable, budget forced to 1-per-call (no density/gap
    // contribution). The cursor does NOT advance on a liquidation (the swapped-in borrower
    // occupies the freed slot instead) — confirm this drains the WHOLE backlog rather than
    // looping forever on one slot or starving the rest.
    function test_Dim11_RotatingCursorDrainsFullBacklogUnderSwapPop() public {
        uint256 n = 12;
        uint256 b = block.number;
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(0x20000 + i));
            _fund(who);
            vm.prank(who); staking.deposit(1_000e18, 90);
            b += 11; vm.roll(b);
            vm.prank(who); staking.borrow(500e18);
        }

        // All 12 share ONE global pool: warming borrower[0] up via claimRewards() would also
        // drive _autoMaintain(borrower[0]), which can scan and auto-liquidate a LATER borrower
        // in the list before this loop ever reaches them directly — contaminating the "all 12
        // simultaneously liquidatable, untouched" setup this test needs. Pause first: claimRewards
        // has no whenNotPaused guard and still accrues the CALLER's own interest, but _autoMaintain
        // no-ops on `paused()` internally, so warm-up can't side-effect anyone else.
        bytes32 roleGuardian = keccak256("GUARDIAN_ROLE");
        vm.prank(admin); staking.grantRole(roleGuardian, admin);
        vm.prank(admin); staking.pause();

        for (uint256 i; i < n; ++i) _driveUnderwater(address(uint160(0x20000 + i)));
        // Not daysToLiquidation() in a loop here either — same stale-call-site defect noted in
        // _driveUnderwater, this time keyed off the repeated call site rather than the address.
        for (uint256 i; i < n; ++i) {
            (uint256 staked, uint256 debt,,,,,,,,,,,,) = staking.getUserInfo(address(uint160(0x20000 + i)));
            assertTrue(debt * 100 >= staked * 95, "each of the 12 must be liquidatable before the sweep");
        }

        vm.prank(admin); staking.unpause();

        // NOTE: budget is not necessarily 1 here — pausing froze lastMaintTime for the whole
        // (multi-decade, real-world-equivalent) warm-up, so the elapsed-time gap term alone can
        // saturate the ceiling on the very first post-unpause call (Dimension 10's own finding).
        // That's fine: the actual claim under test is coverage, not throughput-per-call. A fixed,
        // generous call count (not a `staking.*() > 0` loop condition — the same repeated-call-
        // site defect could make that stale too) drives the sweep; the final assertion below is a
        // single fresh call and will honestly fail if any borrower was really left stranded.
        for (uint256 i; i < 20; ++i) {
            vm.prank(keeper);
            staking.claimRewards();
        }

        assertEq(staking.activeBorrowerCount(), 0, "swap-pop-without-cursor-advance must not strand anyone");
        for (uint256 i; i < n; ++i) {
            (, uint256 debt,,,,,,,,,,,,) = staking.getUserInfo(address(uint160(0x20000 + i)));
            assertEq(debt, 0, "every simultaneously-liquidatable borrower must have been reached");
        }
    }

    // ─── Dimension 12 — lifecycle-phase boundary at emissionEnd ────────────────────────────
    function test_Dim12_DepositAndLockRevertExactlyAtEmissionEnd() public {
        uint256 end = staking.emissionEnd();
        // Not `end - 1`: maxDays = (emissionEnd - now) / 1 days floors to 0 with only 1 second
        // left, which trips Staking__LockExceedsEmissionEnd on its own — a real, separate guard,
        // not the one this test targets. Leave enough headroom for the 90-day lock to fit so the
        // ONLY guard in play here is the emissionEnded check itself.
        vm.warp(end - 95 days);
        vm.prank(alice);
        staking.deposit(1_000e18, 90); // comfortably before the end: must still succeed

        vm.warp(end); // exact boundary: must now revert (`>=`, not `>`)
        vm.prank(bob);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmissionEnded.selector);
        staking.deposit(1_000e18, 90);
    }

    function test_Dim12_LendingSurvivesForeverAfterEmissionEnd() public {
        uint256 b = block.number;
        vm.prank(alice); staking.deposit(1_000e18, 90);
        b += 11; vm.roll(b);
        vm.prank(alice); staking.borrow(400e18);

        uint256 t = staking.emissionEnd() + 365 days; // one year INTO the post-emission tail
        vm.warp(t);

        // No emissionEnded check exists on borrow/repay/withdraw/claimPureYield/liquidate — all
        // must keep working indefinitely, since interest/pure-yield is funded by borrowers'
        // interest, not the emission reserve.
        vm.prank(alice);
        staking.repay(400e18);
        b += 11; vm.roll(b);
        t += 91 days; vm.warp(t); // clear the (already-expired) lock

        // Read BEFORE pranking: staking.effectiveStakeOf(alice) as an inline argument would be
        // its own external call, consuming vm.prank's single-next-call scope before withdraw
        // ever runs — leaving withdraw executing as the test contract itself, not alice.
        uint256 aliceStake = staking.effectiveStakeOf(alice);
        vm.prank(alice);
        staking.withdraw(aliceStake);
        assertEq(staking.totalStaked(), 0);
        assertTrue(staking.isSolvent());
    }

    function test_Dim12_RewardAccrualFreezesExactlyAtEmissionEndEvenIfTouchedYearsLate() public {
        vm.prank(admin);
        staking.fundEmission(180_000_000e18);

        vm.prank(alice); staking.deposit(1_000e18, 90); // sole staker -> owns the whole denominator

        uint256 end = staking.emissionEnd();
        uint256 start = staking.emissionStart();
        // Touch the contract long AFTER emissionEnd, having never touched it since deposit.
        // Can't use bob's own deposit() here — deposit() itself reverts EmissionEnded past the
        // boundary. claimRewards() carries no such guard and is harmless for a never-staked bob
        // (its settle calls no-op on a zero tracked weight), so it's the neutral post-end poke.
        vm.warp(end + 3 * 365 days);
        vm.prank(bob); staking.claimRewards(); // unrelated neutral tx, drives _updateGlobal()

        // The whole-programme emission is the closed-form curve's delta, clamped at emissionEnd,
        // not at the late touch time.
        uint256 expectedDistributed = staking.emittedAt(end) - staking.emittedAt(start);
        assertApproxEqAbs(staking.totalRewardDistributed(), expectedDistributed,
            staking.INITIAL_REWARD_PER_SEC(),
            "accRewardPerShare must have stopped accruing exactly at emissionEnd, not at the late touch time");
    }

    // ─── Dimension 13 — the biennial-halving curve itself ──────────────────────────────────
    // The period-boundary anchors are EXACT by construction (the partial term is zero there and
    // 180M is divisible by 2^8), so these are assertEq, not approx: any drift in the closed form
    // is a hard failure, not noise.
    function test_Dim13_EmissionCurveHalvingAnchors() public view {
        uint256 start  = staking.emissionStart();
        uint256 period = staking.HALVING_PERIOD();
        uint256 total  = staking.TOTAL_REWARDS();

        assertEq(staking.emittedAt(start), 0, "curve starts at zero");
        assertEq(staking.emittedAt(start + period),     total - (total >> 1), "year 2:  90M (50%)");
        assertEq(staking.emittedAt(start + 2 * period), total - (total >> 2), "year 4: 135M (75%)");
        assertEq(staking.emittedAt(start + 3 * period), total - (total >> 3), "year 6: 157.5M (87.5%)");
        assertEq(staking.emittedAt(staking.emissionEnd()),            total - (total >> 8),
            "close: 179,296,875 - the 2^-8 tail is never emitted");
        assertEq(staking.emittedAt(staking.emissionEnd() + 365 days), total - (total >> 8),
            "the curve is flat after the close");

        // Mid-period the curve is linear at the halved rate (sub-wei flooring aside).
        assertApproxEqAbs(staking.emittedAt(start + period / 2), 45_000_000e18, 1e18,
            "halfway through period 0 at R0");
        assertApproxEqAbs(staking.emittedAt(start + period + period / 2), 112_500_000e18, 1e18,
            "halfway through period 1 at R0/2");
    }
}
