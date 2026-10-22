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
contract UnbookedLossReadIsALowerBoundTest is Base {
    uint256 internal constant DUST = 1e10;

    function _stakeDebt(address u) internal view returns (uint256 s, uint256 d) {
        (s, d, , , , , , , , , , , , ) = staking.getUserInfo(u);
    }

    function _reachUnbookedLoss() internal {
        vm.prank(alice);
        staking.deposit(10_000e18, 90);
        vm.prank(carol);
        staking.deposit(1_000_000e18, 90);
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
            if (!staking.isSolvent()) return;
        }
        revert("setup: no breach reached");
    }

    function test_OWEDREAD_unbookedLossReadsAsABreachBoundedByTheRealDeficit() public {
        _reachUnbookedLoss();
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

        assertFalse(r.solvent, "the read still sees the breach");
        assertGt(r.deficit, DUST, "and a deficit above the dust");
        assertLe(r.deficit, realDeficit, "the read deficit is a lower bound of the real one");
        assertGe(r.backing + r.totalBadDebt + unbooked + DUST, r.owed, "backing + B + unbooked >= owed");

        // Booking it (liquidation, open under a breach) moves it into the recorded loss.
        vm.prank(keeper);
        staking.liquidate(carol);
        BlazePhoenixStaking.SolvencyReport memory a = staking.solvency();
        assertGe(a.backing + a.totalBadDebt + DUST, a.owed, "once booked: backing + B >= owed");
    }
}
