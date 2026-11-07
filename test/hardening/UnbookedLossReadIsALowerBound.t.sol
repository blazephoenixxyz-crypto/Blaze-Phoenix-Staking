// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice OWED-READ. Oracle: a loss is recognised when it is booked (attribution beyond the stake,
///         liquidation, an under-water emergency exit). Before that, `_owed()` reads a borrower
///         whose debt has outgrown its stake only in part, through its floors: the read deficit is
///         a LOWER bound of the real one, never more, and the solvency surface still reads the
///         breach. The identity that always holds is
///             backing + totalBadDebt + unbookedLoss >= owed,
///         with unbookedLoss = Σ max(0, debt − stake after attribution).
///         The book: a small pure staker and one large borrower who alone acts (her own claim
///         every 10 days), so her interest is attributed as it accrues and never exceeds her
///         stake in one slice; after ~20 years her debt passes her stake with nothing booked.
///         Each test runs twice: with the emission reserve empty, and funded before the borrow so
///         that it is still live at the breach (R > 0), where the read nets it with the other
///         reserves and the pure staker's own claim carries emission as well as pure yield.
contract UnbookedLossReadIsALowerBoundTest is Base {
    uint256 internal constant DUST = 1e10;
    /// @dev The curve releases TOTAL_REWARDS * (1 - 2^-EMISSION_PERIODS) over its 16 years and
    ///      the funding is R_LEFT above it, so the reserve keeps at least R_LEFT once it ends.
    uint256 internal constant R_LEFT = 20_000e18;

    function _stakeDebt(address u) internal view returns (uint256 s, uint256 d) {
        (s, d, , , , , , , , , , , , ) = staking.getUserInfo(u);
    }

    function _fundEmissionLeaving(uint256 left) internal {
        uint256 total = staking.TOTAL_REWARDS();
        uint256 amount = total - (total >> staking.EMISSION_PERIODS()) + left;
        vm.prank(admin);
        staking.fundEmission(amount);
    }

    function _reachUnbookedLoss(bool funded) internal {
        vm.prank(alice);
        staking.deposit(10_000e18, 90);
        vm.prank(carol);
        staking.deposit(1_000_000e18, 90);
        if (funded) _fundEmissionLeaving(R_LEFT);
        vm.roll(block.number + 11);
        vm.prank(carol);
        staking.borrow(500_000e18);
        // The clock is carried in locals: under via_ir `block.timestamp` is cached across a loop.
        uint256 t = block.timestamp;
        uint256 bn = block.number;
        for (uint256 i = 0; i < 3000; i++) {
            t += 10 days;
            bn += 30;
            vm.warp(t);
            vm.roll(bn);
            vm.prank(carol);
            staking.claimRewards();
            if (!staking.solvency().solvent) return;
        }
        revert("setup: no breach reached");
    }

    function test_OWEDREAD_unbookedLossReadsAsABreachBoundedByTheRealDeficit() public {
        _reachUnbookedLoss(false);
        _checkTheBreachReadIsBoundedByTheRealDeficit();
    }

    /// @dev The same breach with the emission reserve live: the read nets it with the protocol
    ///      reserve, and once the loss is booked `owed` carries it again.
    function test_OWEDREAD_liveEmissionReserve_theBreachNetsItWithTheOtherReserves() public {
        _reachUnbookedLoss(true);
        assertGe(staking.rewardReserve(), R_LEFT, "setup: the emission reserve is live at the breach");
        _checkTheBreachReadIsBoundedByTheRealDeficit();
    }

    function _checkTheBreachReadIsBoundedByTheRealDeficit() internal {
        BlazePhoenixStaking.SolvencyReport memory r = staking.solvency();
        (uint256 cs, uint256 cd) = _stakeDebt(carol);
        (uint256 as_, ) = _stakeDebt(alice);
        assertEq(r.totalBadDebt, 0, "setup: nothing booked yet");
        assertGt(cd, cs, "setup: the borrower is under water");
        assertEq(r.totalStaked, as_ + cs, "setup: every stake is attributed");

        uint256 unbooked = cd - cs;
        // Real claims exclude the borrower's negative equity (she holds the borrowed tokens).
        uint256 realDeficit = as_ + r.rewardReserve + r.protocolReserve + r.pendingDistribution - r.backing;
        assertApproxEqAbs(realDeficit, unbooked, DUST, "the real deficit is the unbooked loss");

        // The loop stopped on the first read of the breach; `isSolvent()` reads it too.
        assertFalse(staking.isSolvent(), "isSolvent() reads the unbooked breach");
        assertGt(r.deficit, DUST, "and a deficit above the dust");
        // Past the other stakes and the reserves, the read nets exactly them: no more is hidden.
        // With the real deficit above, this is the lower bound: it reads as_ + R + P under it.
        assertApproxEqAbs(
            r.deficit, unbooked - as_ - r.rewardReserve - r.protocolReserve, DUST,
            "the read nets exactly the other stakes and the reserves"
        );
        assertGe(r.backing + r.totalBadDebt + unbooked + DUST, r.owed, "backing + B + unbooked >= owed");

        // Booking it (liquidation, open under a breach) moves it into the recorded loss.
        vm.prank(keeper);
        staking.liquidate(carol);
        BlazePhoenixStaking.SolvencyReport memory a = staking.solvency();
        assertApproxEqAbs(
            a.owed, a.backing + a.totalBadDebt, DUST, "once booked: owed == backing + B, every reserve included"
        );
    }

    /// @dev The same book, stopped while the loss is still inside what the read nets: past the
    ///      protocol reserve, below the pure stake plus the reserves. That window (~10k wide) is
    ///      narrower than one 10-day slice of interest at the rate cap (~20k), so the clock takes
    ///      10-day steps while the gap is wide and daily steps near it.
    function _reachApparentSolvency(bool funded) internal {
        vm.prank(alice);
        staking.deposit(10_000e18, 90);
        vm.prank(carol);
        staking.deposit(1_000_000e18, 90);
        if (funded) _fundEmissionLeaving(R_LEFT);
        vm.roll(block.number + 11);
        vm.prank(carol);
        staking.borrow(500_000e18);
        uint256 t = block.timestamp;
        uint256 bn = block.number;
        for (uint256 i = 0; i < 8000; i++) {
            (uint256 cs, uint256 cd) = _stakeDebt(carol);
            uint256 pr = staking.protocolReserve();
            if (cd > cs + pr + 1_000e18) return;
            t += cs > cd + pr + 60_000e18 ? 10 days : 1 days;
            bn += 30;
            vm.warp(t);
            vm.roll(bn);
            vm.prank(carol);
            staking.claimRewards();
        }
        revert("setup: the loss never passed the reserve");
    }

    function test_OWEDREAD_documents_anUnbookedLossReadsSolventUntilTheSweepBooksIt() public {
        _reachApparentSolvency(false);
        _checkTheSweepBooksTheLossAheadOfHerPayment();
    }

    /// @dev The same book with the emission reserve live: her claim now carries emission too,
    ///      and the emission settle runs after the booking as well, so it is deferred with the rest.
    function test_OWEDREAD_documents_liveEmissionReserve_herEmissionIsDeferredToo() public {
        _reachApparentSolvency(true);
        assertGe(staking.rewardReserve(), R_LEFT, "setup: the emission reserve is live");
        assertGt(staking.pendingRewards(alice), DUST, "setup: her claim carries emission");
        _checkTheSweepBooksTheLossAheadOfHerPayment();
    }

    function _checkTheSweepBooksTheLossAheadOfHerPayment() internal {
        BlazePhoenixStaking.SolvencyReport memory r = staking.solvency();
        (uint256 cs, uint256 cd) = _stakeDebt(carol);
        (uint256 as_, ) = _stakeDebt(alice);
        uint256 unbooked = cd - cs;
        assertEq(r.totalBadDebt, 0, "setup: nothing booked yet");
        assertGt(unbooked, r.protocolReserve + DUST, "setup: the loss passes what the reserve covers");
        uint256 realDeficit = as_ + r.rewardReserve + r.protocolReserve + r.pendingDistribution - r.backing;
        assertApproxEqAbs(realDeficit, unbooked, DUST, "the real deficit is the unbooked loss");

        // The lower bound at its loosest: the read nets the whole loss and sees nothing.
        assertTrue(r.solvent, "an unbooked loss reads solvent");
        assertTrue(staking.isSolvent(), "isSolvent() agrees");
        assertEq(r.deficit, 0, "with no deficit read");

        // A pure staker's own claim passes its breach gate on that read, and the borrower
        // window it carries reaches carol and books the loss beyond the reserve. Her own
        // payment settles after the booking (LOSS-FIRST), so it is deferred, not paid at par.
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 owedBefore = staking.pendingRewards(alice) + staking.pendingPureYield(alice);
        vm.prank(alice);
        staking.claimPureYield();
        BlazePhoenixStaking.SolvencyReport memory a = staking.solvency();
        (, uint256 cdAfter) = _stakeDebt(carol);
        assertEq(cdAfter, 0, "the window seized her");
        assertApproxEqAbs(a.totalBadDebt, unbooked - r.protocolReserve, DUST, "booked: the loss beyond the reserve");
        assertFalse(a.solvent, "and the read turns");
        assertFalse(staking.isSolvent(), "isSolvent() turns too");
        assertEq(token.balanceOf(alice), aliceBefore, "LOSS-FIRST: her claim is deferred, not paid at par");
        assertGe(a.backing + a.totalBadDebt + DUST, a.owed, "once booked: backing + B >= owed");
        assertGe(
            staking.pendingRewards(alice) + staking.pendingPureYield(alice) + DUST, owedBefore,
            "deferred, not dropped: her claim stays on her position"
        );
    }
}
