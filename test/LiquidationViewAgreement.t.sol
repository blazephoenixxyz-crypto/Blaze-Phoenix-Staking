// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// =============================================================================
//  REGRESSION — the monitoring views must agree with the function that enforces.
//
//  `_isLiquidatable` treats a position with debt and zero stake as liquidatable,
//  and it is right to: that is a loan with no collateral left at all. Both public
//  monitoring views disagreed with it, in the same direction and for the same
//  reason — an early return guarded on `staked == 0`:
//
//    daysToLiquidation  ->  type(uint256).max   ("never liquidatable")
//    healthFactor       ->  WAD                 (the BEST score it can return)
//
//  Inside `_health` the two branches contradicted each other outright: the line
//  after the guard says `debt >= staked` means zero health, which is exactly this
//  state — but the guard fired first and returned the opposite.
//
//  The state is reached by ordinary interest accrual, not by an attack: `_accrue`
//  clamps interest to the stake and books the remainder as uncollected, so a
//  position left alone long enough arrives at stake == 0 with debt outstanding.
//
//  Why it costs money rather than merely being untidy: a liquidator scanning
//  these views for work skips precisely the positions with no collateral left —
//  the ones generating bad debt — while the protocol's own numbers report them
//  as healthy.
//
//  The assertion below uses `liquidate()` itself as the oracle. Whatever the
//  views say, the enforcing function is the truth, and they must not disagree.
//
//  forge test --match-contract LiquidationViewAgreement -vv
// =============================================================================

import {Base} from "./BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract LiquidationViewAgreementTest is Base {
    /// Drive a real borrower to stake == 0 through interest alone, then require
    /// the views and the enforcer to give the same verdict.
    function test_ViewsAgreeWithEnforcer_WhenInterestConsumesTheStake() public {
        vm.prank(alice); staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(alice); staking.borrow(400e18); // comfortably inside the LTV cap

        // One long jump, one poke. Accrual is index-based, so the whole elapsed
        // interval is applied in a single settlement — and `pokeExpiredLock`
        // clears the expired lock it acts on, so calling it twice reverts
        // `Staking__NoLock()`. It is a one-shot trigger, not a pump.
        // `pokeExpiredLock` is NOT usable here: it settles the expired position
        // outright, leaving stake and debt both at zero, so the state under test
        // never persists past the call. A reward claim accrues without closing
        // anything, which is the ordinary thing an absent borrower does when
        // they come back.
        vm.warp(block.timestamp + 36_500 days); // a century of interest
        vm.prank(alice);
        try staking.claimRewards() {} catch {}

        (uint256 staked, uint256 debt,,,,,,,,,,,,) = staking.getUserInfo(alice);

        // If this fails, the finding is not gone — the setup stopped reaching the
        // state, and the test must be repaired rather than deleted.
        assertEq(staked, 0, "setup must reach stake == 0");
        assertGt(debt, 0, "setup must leave debt outstanding");

        // Read the monitoring surface BEFORE touching state, exactly as an
        // off-chain liquidator or a borrower's dashboard would.
        uint256 days_ = staking.daysToLiquidation(alice);
        uint256 health = staking.healthFactor(alice);

        // The oracle. Done last, so no snapshot is needed.
        bool enforcerAccepts;
        vm.prank(keeper);
        try staking.liquidate(alice) { enforcerAccepts = true; }
        catch { enforcerAccepts = false; }

        assertTrue(enforcerAccepts, "a loan with no collateral must be liquidatable");
        assertEq(days_, 0, "daysToLiquidation must not report a liquidatable position as safe");
        assertEq(health, 0, "healthFactor must not report maximum health for a liquidatable position");

        // ── an executable record of the defect ────────────────────────────────
        // The old guards are reproduced here rather than reintroduced into the
        // contract, so this file keeps proving what was wrong long after anyone
        // remembers it. Both early returns fired on `staked == 0` and answered
        // before the line that would have judged the state correctly.
        uint256 oldDays   = (debt == 0 || staked == 0) ? type(uint256).max : 0;
        uint256 oldHealth = (staked == 0 || debt == 0) ? 1e18 /* WAD */ : 0;

        assertEq(oldDays, type(uint256).max, "record: the old view called this position never-liquidatable");
        assertEq(oldHealth, 1e18, "record: the old view gave this position maximum health");

        // The disagreement, stated as the thing that actually mattered: the old
        // views contradicted the enforcer on the same state in the same block.
        assertTrue(enforcerAccepts && oldDays != 0, "record: view and enforcer disagreed");
        assertTrue(enforcerAccepts && oldHealth != 0, "record: health and enforcer disagreed");
    }

    /// The same disagreement, stated as the property rather than the scenario:
    /// zero days to liquidation and zero health must both mean the enforcer
    /// accepts, and a position the enforcer refuses must show neither.
    function test_HealthAndDaysNeverContradictEachOther() public {
        vm.prank(alice); staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(alice); staking.borrow(100e18); // small debt: healthy for a long time

        uint256 days_ = staking.daysToLiquidation(alice);
        uint256 health = staking.healthFactor(alice);

        // A healthy position: neither view may claim the liquidation boundary.
        assertGt(days_, 0, "a healthy position must not read as liquidatable now");
        assertGt(health, 0, "a healthy position must not read as zero health");

        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NotLiquidatable.selector);
        staking.liquidate(alice);
    }
}
