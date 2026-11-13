// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice Interest is attributed lazily: between two touches a borrower's tracked weight keeps the
///         equity of its last resync while the interest index lowers the live one. Any transaction
///         carries the borrower sweep (`_autoMaintain`), which accrues and resyncs every borrower in
///         its window, so a third party's traffic brings the denominator back to the live weights.
///         Green on 82febb5. Red with the resync of `maintStep` deleted (the mutant registered in
///         mutants.py).
contract SweepResyncsIdleBorrowerTest is Base {
    function test_AThirdPartyTransactionResyncsAnIdleBorrowersWeight() public {
        address h = address(0xA0);
        address b = address(0xB0);
        token.mint(h, 1_000_000e18);
        token.mint(b, 20_000_000e18);
        vm.prank(h); token.approve(address(staking), type(uint256).max);
        vm.prank(b); token.approve(address(staking), type(uint256).max);
        vm.prank(admin); staking.fundEmission(90_000_000e18);
        vm.prank(h); staking.deposit(1_000_000e18, 2555);
        vm.prank(b); staking.deposit(20_000_000e18, 2555);
        vm.roll(block.number + 20);
        vm.prank(b); staking.borrow(9_900_000e18);
        uint256 tbeBefore = staking.totalBoostedEffective();
        vm.warp(vm.getBlockTimestamp() + 365 days); vm.roll(block.number + 1);
        vm.prank(h); staking.claimRewards();   // carries the borrower sweep
        uint256 live = (staking.effectiveStakeOf(h) + staking.effectiveStakeOf(b)) * staking.boostByDays(2555) / 10_000;
        assertLt(staking.effectiveStakeOf(b), 20_000_000e18 - 9_900_000e18, "fixture: interest was attributed");
        assertLt(staking.totalBoostedEffective(), tbeBefore, "the denominator moved");
        assertApproxEqAbs(staking.totalBoostedEffective(), live, 1e6, "denominator == live weights after a third-party tx");
    }
}

/// @notice What the lazy attribution leaves until the borrower is touched (docs/KNOWN_ISSUES.md).
///         A debt-free 1M position and an idle 20M borrower at 9.9M of debt, both on 2555-day locks,
///         over one year: settled once at the end ("idle") or by a daily claim of the debt-free
///         position ("daily"), whose transactions carry the sweep that resyncs the borrower.
///         Measured on the 8-year 90M schedule: the idle book charges 331,650.00 BZPX of interest
///         against 333,730.36 BZPX daily (the same as on 82febb5), and pays the debt-free position
///         1,396,396.40 BZPX of emission against 1,417,717.78 daily (21,321.38 less); the
///         borrower's own settle returns 463,114.86 BZPX of the window to the reserve.
contract InterestStaleWeightTest is Base {
    address internal honest = address(0xA0);
    address internal borrower = address(0xB0);
    uint256 internal constant DUST = 1e10;
    uint256 internal constant B_STAKE = 20_000_000e18;
    uint256 internal constant B_DEBT = 9_900_000e18;
    uint256 internal constant HORIZON = 365 days;

    struct R {
        uint256 emission; uint256 interest; uint256 reserveUp;
        uint256 window; uint256 tbe0; uint256 tbeEnd; uint256 w; uint256 u0; uint256 uEnd;
    }

    function _mk(address who, uint256 amt) internal {
        token.mint(who, amt);
        vm.prank(who); token.approve(address(staking), type(uint256).max);
        vm.prank(who); staking.deposit(amt, 2555);
    }

    /// `gap` = the debt-free position's claim cadence (0 = only at the end).
    function _run(uint256 gap) internal returns (R memory r) {
        vm.prank(admin); staking.fundEmission(90_000_000e18);
        _mk(honest, 1_000_000e18);
        _mk(borrower, B_STAKE);
        vm.roll(block.number + 20);
        vm.prank(borrower); staking.borrow(B_DEBT);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 h0 = token.balanceOf(honest);
        uint256 i0 = staking.totalInterestAccruedGlobal();
        r.tbe0 = staking.totalBoostedEffective();
        r.w = staking.effectiveStakeOf(honest) * staking.boostByDays(2555) / 10_000;
        r.u0 = staking.utilizationRate();
        uint256 end = t0 + HORIZON;
        uint256 last = t0;
        if (gap != 0) {
            for (uint256 t = t0 + gap; t < end; t += gap) {
                vm.warp(t); vm.roll(block.number + 1);
                r.emission += staking.pendingRewards(honest);   // the quote is the payment
                vm.prank(honest); staking.claimRewards();
                last = t;
            }
        }
        vm.warp(end); vm.roll(block.number + 1);
        uint256 rr0 = staking.rewardReserve();
        r.emission += staking.pendingRewards(honest);
        vm.prank(honest); staking.claimRewards();
        assertGt(token.balanceOf(honest) - h0, r.emission, "fixture: both channels paid");
        r.interest = staking.totalInterestAccruedGlobal() - i0;
        // The last call released its own window from the reserve; what the settles in it returned
        // is the rest of the reserve's move.
        r.reserveUp = staking.rewardReserve() + (staking.emittedAt(end) - staking.emittedAt(last)) - rr0;
        r.window = staking.emittedAt(end) - staking.emittedAt(t0);
        r.tbeEnd = staking.totalBoostedEffective();
        r.uEnd = staking.utilizationRate();
    }

    function _pair() internal returns (R memory idle, R memory daily) {
        uint256 snap = vm.snapshotState();
        idle = _run(0);
        vm.revertToState(snap);
        daily = _run(1 days);
    }

    /// The idle borrower's pre-interest weight dilutes the debt-free position until the borrower is
    /// touched. Bounds: the daily book pays at most the window at the final denominator, the idle
    /// book exactly the window at the starting one, and what the idle book withholds is not paid to
    /// anyone: the borrower's settle returns at least as much to the reserve (P1-C).
    function test_S1_documents_anIdleBorrowerDilutesTheEmissionUntilTouched() public {
        (R memory idle, R memory daily) = _pair();
        assertGt(daily.emission, idle.emission + DUST, "the residue: the idle book pays less");
        uint256 shortfall = daily.emission - idle.emission;
        uint256 bound = idle.window * daily.w / daily.tbeEnd - idle.window * idle.w / idle.tbe0;
        assertLe(shortfall, bound + DUST, "the shortfall exceeds the weight the interest removed");
        assertGe(idle.reserveUp + DUST, shortfall, "what the idle book withholds goes back to the reserve");
        emit log_named_decimal_uint("debt-free emission, daily (BZPX)", daily.emission, 18);
        emit log_named_decimal_uint("debt-free emission, idle (BZPX) ", idle.emission, 18);
        emit log_named_decimal_uint("returned to rewardReserve (BZPX)", idle.reserveUp, 18);
    }

    /// The index prices each window at the rate its start reads (O(1) accrual, no integral of the
    /// curve): an untouched year is charged exactly the published rate at its starting utilisation,
    /// and a touched book picks up the rate the falling stake raises. The daily book is charged
    /// more, never more than the whole year at the final rate.
    function test_S2_documents_theInterestRateIsSampledAtTheStartOfEachWindow() public {
        (R memory idle, R memory daily) = _pair();
        uint256 r0 = staking.simulateRate(idle.u0);
        uint256 delta = (1e18 * r0 / 10_000) * HORIZON / 365 days;
        assertEq(idle.interest, B_DEBT * delta / 1e18, "an untouched window is charged the rate at its start");
        assertGt(daily.interest, idle.interest + DUST, "the residue: a touched book is charged more");
        uint256 rEnd = staking.simulateRate(daily.uEnd);
        assertLe(daily.interest, B_DEBT * rEnd / 10_000 * HORIZON / 365 days + DUST, "above the final rate");
        emit log_named_decimal_uint("interest, idle (BZPX) ", idle.interest, 18);
        emit log_named_decimal_uint("interest, daily (BZPX)", daily.interest, 18);
    }
}
