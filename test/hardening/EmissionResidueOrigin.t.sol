// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Where the emission left in `rewardReserve` after the curve closes comes from, and who
///         can reach it. The curve moves exactly its own delta from the reserve into the
///         accumulator each window (`_windowReward`), never the reserve itself, so a token that
///         goes BACK to the reserve during the programme is never emitted again. Two settles send
///         tokens back (`_settlePendingRewards`): P1-C, the share of a window a borrower's stale
///         tracked weight implies over her live equity (interest erodes the equity between
///         touches), and LOCK-STALE, the boost a lapsed lock earned after its unlock. With every
///         window carrying weight above MIN_EMISSION_WEIGHT, the residue is exactly their sum.
///         Book: carol stakes 1M and touches the book every ten days (the D2 shape of
///         UnbookedLossReadIsALowerBound); `n - 1` passive stakers of 10k each, all 90-day locks.
///         Measured at d71468f (residue at the close, every staker settled once after it):
///         no borrow n=1: 0, n=2: 0, n=10: 353.97e18; borrow n=1: 110101.57e18, n=2: 106363.44e18
///         (the D2 reserve at its breach, ten years later), n=10: 83877.55e18.
contract EmissionResidueOriginTest is Base {
    uint256 internal constant CAROL_STAKE = 1_000_000e18;
    uint256 internal constant PASSIVE_STAKE = 10_000e18;
    uint256 internal constant CADENCE = 10 days;

    function _passive(uint256 i) internal pure returns (address) {
        return address(uint160(0xBEEF00 + i));
    }

    /// Runs the programme to its close plus one cadence, then settles every staker once.
    /// Returns the reserve at that point: the residue nobody is owed.
    function _residue(uint256 n, bool borrow) internal returns (uint256) {
        vm.prank(carol);
        staking.deposit(CAROL_STAKE, 90);
        for (uint256 i = 1; i < n; ++i) {
            _fund(_passive(i));
            vm.prank(_passive(i));
            staking.deposit(PASSIVE_STAKE, 90);
        }
        uint256 total = staking.TOTAL_REWARDS();
        vm.prank(admin);
        staking.fundEmission(total);
        vm.roll(block.number + 11);
        if (borrow) {
            vm.prank(carol);
            staking.borrow(CAROL_STAKE / 2);
        }
        uint256 t = block.timestamp;
        uint256 bn = block.number;
        uint256 end = staking.emissionEnd() + CADENCE;
        while (t < end) {
            t += CADENCE;
            bn += 30;
            vm.warp(t);
            vm.roll(bn);
            vm.prank(carol);
            staking.claimRewards();
        }
        for (uint256 i = 1; i < n; ++i) {
            vm.prank(_passive(i));
            staking.claimRewards();
        }
        assertTrue(staking.isSolvent(), "setup: the book is solvent at the close");
        return staking.rewardReserve();
    }

    /// No interest and every lapsed lock normalised at its unlock instant (the cadence divides
    /// the 90 days and the lock window acts on up to four positions in that transaction): no
    /// stale weight anywhere, so nothing goes back and the curve leaves no tail.
    function test_RESIDUE_aBookWithNoStaleWeightLeavesNothing_n1() public {
        assertEq(_residue(1, false), 0, "no stale weight, no residue");
    }

    function test_RESIDUE_aBookWithNoStaleWeightLeavesNothing_n2() public {
        assertEq(_residue(2, false), 0, "no stale weight, no residue");
    }

    /// Ten lapsed locks and four lock actions per transaction: the last ones are normalised up
    /// to two cadences after their unlock and the boost they drew there goes back (LOCK-STALE).
    /// Bound: each of the nine passive positions draws at most the boost premium of its share of
    /// those two cadences, and its share is at most its boosted weight over the book at 1.00x.
    function test_RESIDUE_lapsedLocksNormalisedLateReturnTheirBoost_n10() public {
        uint256 r = _residue(10, false);
        // The locks open at the deployment instant (no warp before the deposits). Not read from
        // `block.timestamp`: under via_ir the read is cached across the warps of the loop.
        uint256 u = staking.emissionStart() + 90 days;
        uint256 late = staking.emittedAt(u + 2 * CADENCE) - staking.emittedAt(u);
        uint256 premium = staking.boostByDays(90) - staking.boostByDays(0);
        uint256 bound = late * 9 * PASSIVE_STAKE / (CAROL_STAKE + 9 * PASSIVE_STAKE) * premium / staking.boostByDays(0);
        assertGt(r, 0, "a lock normalised after its unlock returns the boost it drew there");
        assertLe(r, bound, "no more than the boost premium of two cadences goes back");
    }

    /// With a borrower the residue is P1-C: interest erodes her equity between touches, the
    /// tracked weight is stale high, and the excess share of each window goes back. The same book
    /// without the loan leaves exactly nothing (the tests above), so all of it is P1-C.
    function test_RESIDUE_aBorrowersStaleWeightIsTheResidue_n1() public {
        assertGt(_residue(1, true), 0, "the stale-weight excess of a borrower is the residue");
    }

    function test_RESIDUE_aBorrowersStaleWeightIsTheResidue_n2() public {
        assertGt(_residue(2, true), 0, "the stale-weight excess of a borrower is the residue");
    }

    /// Reachable by its owner and nobody else: the admin sweeps it whole to the immutable
    /// treasury (measured on the treasury balance), a second sweep finds nothing because every
    /// position settled after the close, and the stakers still claim.
    function test_RESIDUE_theAdminSweepsItWholeToTheTreasury() public {
        uint256 r = _residue(2, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, bob, keccak256("ADMIN_ROLE")));
        staking.sweepUndistributedEmission();
        uint256 b0 = token.balanceOf(treasury);
        vm.prank(admin);
        staking.sweepUndistributedEmission();
        assertEq(token.balanceOf(treasury) - b0, r, "the treasury received the whole residue");
        assertEq(staking.rewardReserve(), 0, "nothing left in the emission reserve");
        assertTrue(staking.isSolvent(), "the book stays solvent without it");
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAmount.selector);
        staking.sweepUndistributedEmission();
        vm.prank(carol);
        staking.claimRewards();
        vm.prank(_passive(1));
        staking.claimRewards();
    }
}
