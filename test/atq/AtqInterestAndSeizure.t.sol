// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  atq-1111 (staking front) — borrow interest and the seizure edge, to the wei
//
//  The emission is left unfunded on purpose: the only value that moves is interest, so every
//  wei the borrower loses can be followed into the pool and the reserve.
//
//  ORACLE: simple interest on the principal at the quoted rate, in the test's own arithmetic,
//  and the documented constants (95% seizure threshold, 5% keeper bonus, 3% reserve factor).
//  TOLERANCES are derived: one step floors the index once (less than debt/1e18 wei) and the
//  charge once (less than one wei); a borrower settled once over m steps is charged at most
//  m - 1 wei above what those steps booked, and never below.
//
//  1. One step: the charge is simple interest on the principal, equals what the pool booked,
//     and splits between pool and reserve with nothing created or lost.
//  2. Many steps: the stake never keeps interest the pool already booked.
//  3. Seizure opens exactly at debt * 100 == stake * 95: one wei of debt less and it is refused;
//     at the edge the keeper is paid 5% of the debt and the borrower keeps the rest.
//
//  Paired mutants: [ATQ-staking-72..78] in .github/scripts/mutants.py.
//  Run: forge test --match-path test/atq/AtqInterestAndSeizure.t.sol
// =============================================================================

import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";

contract AtqInterestAndSeizureTest is Base {
    address internal constant STRANGER = address(0x57A6E);

    function _pos(address a) internal view returns (uint256 s, uint256 d) {
        (s, d,,,,,,,,,,,,) = staking.getUserInfo(a);
    }

    function _probe() internal { vm.prank(STRANGER); staking.claimRewards(); }

    /// alice stakes and borrows a quarter of it; bob is the unborrowed pool the interest goes to.
    function _open(uint256 stake) internal returns (uint256 debt, uint256 s0, uint256 rateBps) {
        vm.prank(alice);
        staking.deposit(stake, 90);
        vm.prank(bob);
        staking.deposit(100_000e18, 365);
        vm.roll(vm.getBlockNumber() + 11);
        debt = stake / 4;
        vm.prank(alice);
        staking.borrow(debt);
        uint256 d;
        (s0, d) = _pos(alice);
        assertEq(d, debt, "setup: debt");
        assertEq(s0, stake, "setup: stake");
        rateBps = staking.currentInterestRateBps();
        assertGt(rateBps, 0, "vacuous: no interest rate");
    }

    // ── 1. one step ────────────────────────────────────────────────────────────────────────────
    function testFuzz_AtqInterestOneStep_SimpleOnThePrincipal_SplitBetweenPoolAndReserveToTheWei(
        uint256 stake, uint256 elapsed
    ) public {
        stake   = bound(stake, 10_000e18, 30_000_000e18);
        elapsed = bound(elapsed, 1, 300 days);          // inside every lock: a settle after an unlock returns the stale excess to the reserve
        (uint256 debt, uint256 s0, uint256 rate) = _open(stake);
        uint256 r0 = staking.protocolReserve();
        uint256 p0 = staking.totalRewardDistributed();
        uint256 g0 = staking.totalInterestAccruedGlobal();

        vm.warp(vm.getBlockTimestamp() + elapsed);
        vm.prank(alice);
        staking.claimRewards();

        (uint256 s1, uint256 d1) = _pos(alice);
        uint256 lost  = s0 - s1;
        uint256 exact = debt * rate * elapsed / (10_000 * 365 days);
        assertEq(d1, debt, "the principal moved");
        assertGt(lost, 0, "vacuous: nothing was charged");
        assertLe(lost, exact, "charged above simple interest on the principal");
        assertLe(exact - lost, debt / 1e18 + 1, "charged under simple interest by more than the two floors");

        uint256 booked    = staking.totalInterestAccruedGlobal() - g0;
        uint256 toReserve = staking.protocolReserve() - r0;
        uint256 toPool    = staking.totalRewardDistributed() - p0;
        assertEq(lost, booked, "the borrower's charge and the pool's booking differ");
        assertEq(toReserve + toPool, booked, "interest was created or lost in the split");
        assertEq(toReserve, booked * 300 / 10_000, "the reserve share is not 3%, rounded down");
    }

    // ── 2. many steps ──────────────────────────────────────────────────────────────────────────
    function testFuzz_AtqInterestManySteps_TheStakeNeverKeepsWhatThePoolBooked(
        uint256 stake, uint256[6] memory gaps
    ) public {
        stake = bound(stake, 10_000e18, 30_000_000e18);
        (uint256 debt, uint256 s0,) = _open(stake);
        uint256 r0 = staking.protocolReserve();
        uint256 p0 = staking.totalRewardDistributed();
        uint256 g0 = staking.totalInterestAccruedGlobal();

        for (uint256 i; i < gaps.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(gaps[i], 1, 60 days));
            if (i == 2) { vm.prank(alice); staking.claimRewards(); } else { _probe(); }
        }
        vm.prank(alice);
        staking.claimRewards();

        (uint256 s1, uint256 d1) = _pos(alice);
        uint256 lost   = s0 - s1;
        uint256 booked = staking.totalInterestAccruedGlobal() - g0;
        assertEq(d1, debt, "the principal moved");
        assertGt(booked, 0, "vacuous: nothing was booked");
        assertGe(lost, booked, "the stake kept interest the pool had booked");
        // two settles over six steps: at most (3 - 1) + (3 - 1) wei above the bookings
        assertLe(lost - booked, 4, "charged above the bookings by more than the floors");
        assertEq((staking.protocolReserve() - r0) + (staking.totalRewardDistributed() - p0), booked,
                 "interest was created or lost in the split");
    }

    // ── 3. the seizure edge ────────────────────────────────────────────────────────────────────
    function _seizable(address who) internal returns (bool ok) {
        uint256 snap = vm.snapshot();
        vm.prank(keeper);
        try staking.liquidate(who) { ok = true; } catch {}
        vm.revertTo(snap);
    }

    function test_AtqSeizureOpensAtNinetyFivePercentToTheWei() public {
        (uint256 debt,,) = _open(40_000e18);
        for (uint256 m; m < 6000 && !_seizable(alice); ++m) vm.warp(vm.getBlockTimestamp() + 30 days);
        assertTrue(_seizable(alice), "setup: never seizable");
        vm.roll(vm.getBlockNumber() + 30);

        // the borrower's own transactions never seize it: settle, a second at a time, until the
        // stake is a multiple of 20 wei, so that 95% of it is a whole number of wei
        uint256 s;
        for (uint256 i; i < 2000; ++i) {
            vm.prank(alice);
            staking.claimRewards();
            (s,) = _pos(alice);
            if (s % 20 == 0) break;
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        assertEq(s % 20, 0, "setup: no whole edge");
        uint256 edge = s / 20 * 19;                      // edge * 100 == s * 95
        assertGt(debt, edge, "setup: the debt is not past the edge");
        assertGt(edge, 0, "setup: nothing left to seize");

        vm.prank(alice);
        staking.repay(debt - edge);
        (uint256 sNow, uint256 dNow) = _pos(alice);
        assertEq(sNow, s, "setup: the repayment moved the stake");
        assertEq(dNow * 100, sNow * 95, "setup: not on the edge");

        uint256 snap = vm.snapshot();
        vm.prank(alice);
        staking.repay(1);                                // one wei inside the edge
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NotLiquidatable.selector);
        staking.liquidate(alice);
        vm.revertTo(snap);

        uint256 keeperBefore = token.balanceOf(keeper);
        uint256 debtBefore   = staking.totalDebt();
        vm.prank(keeper);
        staking.liquidate(alice);                        // on the edge: open
        uint256 bonus = edge * 500 / 10_000;
        (uint256 sAfter, uint256 dAfter) = _pos(alice);
        assertEq(dAfter, 0, "the debt survived the seizure");
        assertEq(sAfter, s - edge - bonus, "the borrower kept other than stake - debt - 5%");
        assertEq(token.balanceOf(keeper) - keeperBefore, bonus, "the keeper was paid other than 5% of the debt");
        assertEq(debtBefore - staking.totalDebt(), edge, "the book's debt moved by other than the debt seized");
    }
}
