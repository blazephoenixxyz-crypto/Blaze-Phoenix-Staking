// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EmissionCurveWalkTest} from "./EmissionCurveWalk.t.sol";

/// @notice The EC-7 maximiser of Monte Carlo campaign 2 (`docs/MONTE_CARLO_EMISSION.md`), replayed
///         and taken apart.
///
/// EC-7 says the quotes never exceed what the contract holds outside stake and reserve, and the
/// campaign reports the largest distance between the two: 1,681,405.17 BZPX at
/// (k, j, i) = (1, 13, 161), the forced close of sequence 13 of batch 1. A number that large must
/// be accounted for, to the wei, before it is called anything.
///
/// It is the stale boost of ONE lapsed lock. A lock that lapses keeps its boosted weight in the
/// denominator until the position is touched, so the windows after its `unlockTime` are booked on
/// `totalRewardDistributed` at the boost, while `pendingRewards` already quotes the position at
/// 1.00x from `unlockTime` on (LOCK-STALE). The difference is held by the contract and quoted to
/// nobody. The first touch settles it through `_settleEmission`: the position is paid its quote,
/// and the part the lapsed boost never earned moves back to `rewardReserve`, where the treasury
/// sweep takes it. What is left afterwards is 2,514,327,281 wei, not decomposed further here.
contract EmissionCurveGapTest is EmissionCurveWalkTest {
    uint256 internal constant GAP      = 1681405174094090999081348;   // the campaign's maximiser
    uint256 internal constant RETURNED = 1681405174094088484754067;   // back in rewardReserve
    uint256 internal constant LEFT     = 2514327281;                  // GAP - RETURNED
    uint256 internal constant QUOTED   = 12664497118674014162888855;  // the lapsed position's quote

    function _gap() internal view returns (uint256 gap) {
        uint256 quoted;
        for (uint256 a; a < actors.length; ++a) quoted += s.pendingRewards(actors[a]);
        gap = token.balanceOf(address(s)) - s.totalStaked() - s.rewardReserve() - quoted;
    }

    function test_ECG_gap_1_13_161_isTheStaleBoostOfOneLapsedLock_returnedToRewardReserveOnTouch() public {
        _sequence(1, 13, 160);

        // The replay lands on the campaign's own maximiser, and the close has swept the reserve.
        assertEq(worstGap, GAP, "not the campaign's maximiser");
        assertEq(worstGapJ, 13, "sequence");
        assertEq(worstGapI, 161, "action");
        assertEq(s.rewardReserve(), 0, "the close left a reserve");
        assertEq(_gap(), GAP, "the gap moved between the close and the sweep");

        // Anyone touches every position. Exactly one has a lapsed lock still carrying its boost.
        uint256 lapsed; uint256 paid;
        for (uint256 a; a < actors.length; ++a) {
            uint256 quote = s.pendingRewards(actors[a]);
            uint256 bal   = token.balanceOf(actors[a]);
            vm.prank(STRANGER);
            try s.pokeExpiredLock(actors[a]) {
                ++lapsed;
                paid = token.balanceOf(actors[a]) - bal;
                assertEq(paid, quote, "the touch paid something else than the quote");
            } catch {
                assertEq(token.balanceOf(actors[a]), bal, "a refused poke moved tokens");
            }
        }
        assertEq(lapsed, 1, "lapsed locks");
        assertEq(paid, QUOTED, "the lapsed position's payout");

        // The whole gap, less LEFT, is back in the reserve: it was never anyone's reward.
        assertEq(s.rewardReserve(), RETURNED, "the stale boost did not return to rewardReserve");
        assertEq(_gap(), LEFT, "what stays unassigned after the touch");
        assertEq(GAP - RETURNED, LEFT, "the three literals do not close");

        // And the treasury sweep, which had already run once, takes it.
        uint256 t0 = token.balanceOf(treasury);
        vm.prank(admin);
        s.sweepUndistributedEmission();
        assertEq(token.balanceOf(treasury) - t0, RETURNED, "the second sweep");
        assertEq(s.rewardReserve(), 0, "the second sweep left a reserve");
        assertEq(_gap(), LEFT, "the sweep moved the gap");
    }
}
