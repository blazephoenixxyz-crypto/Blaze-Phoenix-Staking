// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================================
//  CONSTANT ORACLES — literal oracles for constants whose value no Foundry test pinned.
//
//  A test that reads `staking.RESERVE_FACTOR_BPS()` or `staking.MAX_STAKE_PER_WALLET()` moves
//  with a mutant of that constant and cannot catch it. The literals here come from the published
//  specification (a 3 % reserve factor; a 30 000 000e18 per-wallet cap), not from the contract:
//
//    execution: ΔprotocolReserve == Δ(totalInterestAccruedGlobal) · 300 / 10 000   (_updateInterestIndex)
//    view:      the published APR nets 9 700 / 10 000                            (pureStakerApr)
//    cap:       a deposit of exactly 30 000 000e18 settles; 1 wei more is refused (deposit)
//
//  Book for the first two: alice is a LARGE pure position (totalBoostedPure ≥ MIN_EMISSION_WEIGHT,
//  so `_dampPure` does not bite and the reserve keeps exactly its cut), carol is a healthy
//  borrower at about half of the LTV cap.
// =============================================================================================

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

contract ConstantOraclesTest is Base {
    uint256 internal constant RESERVE_BPS_LITERAL = 300;      // 3 %, published
    uint256 internal constant NET_BPS_LITERAL     = 9_700;    // 10 000 − 300
    uint256 internal constant CAP_LITERAL         = 30_000_000e18;

    /// A healthy book with a full pure-weight denominator (the damper does not bite).
    function _book() internal {
        vm.prank(alice); staking.deposit(10_000_000e18, 365);
        vm.prank(carol); staking.deposit(10_000_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(carol); staking.borrow(5_000_000e18);
        vm.warp(block.timestamp + 200 days);
    }

    /// Execution: `reserveCut = mulDiv(slice, RESERVE_FACTOR_BPS, 10_000)`. With a full
    /// denominator the reserve gains the cut and nothing else, and the global accrual gains `slice`.
    function test_ReserveTakesThreeHundredBpsOfRealisedInterest() public {
        _book();
        assertGe(staking.totalBoostedPure(), staking.MIN_EMISSION_WEIGHT(),
                 "precondition: the damper does not bite (full denominator)");

        uint256 reserve0 = staking.protocolReserve();
        uint256 accrued0 = staking.totalInterestAccruedGlobal();
        vm.prank(carol); staking.repay(1);                     // poke: runs the accrual
        uint256 accrued = staking.totalInterestAccruedGlobal() - accrued0;
        uint256 reserveGained = staking.protocolReserve() - reserve0;

        assertGt(accrued, 0, "non-vacuous: interest ran over the measured interval");
        assertEq(reserveGained, accrued * RESERVE_BPS_LITERAL / 10_000,
                 "the reserve did not take 300 bps of the realised interest (literal oracle)");
    }

    /// View: `aprBps = mulDiv(_dampPure(base, tbp), 10_000 − RESERVE_FACTOR_BPS, 10_000)`. The
    /// expected value uses the literal 9 700; debt, rate and boost are read from the contract, so
    /// the test pins the factor, not the rate curve.
    function test_PublishedAprNetsTheReserveFactor() public {
        _book();
        uint256 tbp = staking.totalBoostedPure();
        assertGe(tbp, staking.MIN_EMISSION_WEIGHT(), "precondition: full denominator");

        uint256 boost = staking.boostByDays(365);
        (, , , , , , , , uint256 rateBps, , , , , ) = staking.getUserInfo(carol);
        assertGt(rateBps, 0, "precondition: the live rate is non-zero");

        uint256 base = (staking.totalDebt() * rateBps / tbp) * boost / 10_000;
        uint256 expected = base * NET_BPS_LITERAL / 10_000;

        assertEq(staking.pureStakerApr(365), expected,
                 "the published APR does not net the published 300 bps reserve factor");
        assertGt(expected, 0, "non-vacuous: the published APR is measurable");
    }

    /// Per-wallet cap, as a literal (`deposit`: `u.staked + amount_ > MAX_STAKE_PER_WALLET`).
    /// The boundary test in BoundaryEquality reads the constant back, so it moves with a mutant;
    /// this one pins the published value and its unit.
    function test_WalletCapIsThirtyMillionTokens() public {
        vm.prank(alice); staking.deposit(CAP_LITERAL, 90);
        (uint256 staked, , , , , , , , , , , , , ) = staking.getUserInfo(alice);
        assertEq(staked, CAP_LITERAL, "a deposit of exactly the published cap settled");

        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__CapExceeded.selector);
        staking.deposit(1, 90);
    }
}
