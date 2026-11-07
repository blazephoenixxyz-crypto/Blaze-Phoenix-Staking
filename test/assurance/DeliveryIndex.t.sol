// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================================
//  EMISSION DELIVERY INDEX — how much of the scheduled emission actually reaches positions.
//
//  Delivery = `totalRewardDistributed`; whatever is not delivered stays in `rewardReserve`
//  (and reaches the treasury through `sweepUndistributedEmission`). The literals below are
//  derived independently of the contract, from the published schedule (the closed form restated
//  from the specification and evaluated in Python, not read back from the contract):
//    S = 120 000 000e18 (the halving series), PERIOD = 5·365 days = 157 680 000 s, 2 periods,
//    R0 = ⌊(S / 2) / PERIOD⌋ = 380 517 503 805 175 038 wei/s,
//    end-of-programme emission E_end = S − (S >> 2) = 90 000 000e18 = the whole budget: no tail,
//    one year at R0 = R0 · 365 days = 12M − 1 632 000 wei (the floor of R0, not a round 12M),
//    E(start + 730 days) = R0 · 730 days = 24M − 3 264 000 wei (still inside period 0).
//
//  What each test measures:
//    full pool, start to end         -> delivery = E_end; the reserve ends at zero and the sweep
//                                       has nothing to send (Staking__ZeroAmount)
//    empty pool in the first year    -> delivery = E_end − one year at R0
//    a single 1-wei position         -> delivery = E_end · 1 / 1e21 = 90 000 wei (the MIN_EMISSION_WEIGHT throttle)
//    empty pool for the whole programme -> the sweep sends all 90 000 000e18 to the treasury
//    under-funded window (10M)       -> pays what exists and stops (reserve clamp)
//    lone lock left untouched past its unlockTime -> delivery = E(unlock) + (E_end − E(unlock)) · 1.00x/1.25x;
//                                       the rest of its own boost stays in the reserve
//
//  A lock that lapses is normalised by the first transaction whose lock window reaches it (or by
//  anyone, with `pokeExpiredLock`); the fixtures below do that at unlockTime, which is what any
//  traffic does. The last test leaves it untouched and pins what the split at unlockTime pays.
// =============================================================================================

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

contract EmissionDeliveryIndexTest is Base {
    uint256 internal constant E_END             = 90_000_000e18;                           // S − (S >> 2)
    uint256 internal constant ONE_YEAR_AT_R0    = 11_999_999_999_999_999_998_368_000;      // 12M − 1 632 000 wei
    uint256 internal constant AFTER_EMPTY_YEAR  = 78_000_000_000_000_000_001_632_000;      // E_END − ONE_YEAR_AT_R0
    uint256 internal constant ONE_WEI_DELIVERED = 90_000;                                  // ⌊E_END / 1e21⌋
    uint256 internal constant E_AT_UNLOCK       = 23_999_999_999_999_999_996_736_000;      // E(start + 730 days)
    uint256 internal constant DUST              = 1e10;                                    // CONSERVATION_DUST

    /// @dev What any transaction's lock window does once `who`'s commitment has elapsed.
    function _normaliseAt(address who, uint256 unlock) internal {
        vm.warp(unlock); vm.roll(block.number + 2);
        vm.prank(keeper); staking.pokeExpiredLock(who);
    }

    /// The schedule closes at exactly the budget, so a pool that is never empty takes all of it:
    /// nothing is left in the reserve, and the sweep is refused for want of a residue.
    function test_FullPoolReceivesTheWholeSchedule() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        vm.prank(admin); staking.fundEmission(90_000_000e18);
        _normaliseAt(alice, block.timestamp + 730 days);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);

        vm.prank(alice); staking.claimRewards();

        assertEq(staking.totalRewardDistributed(), E_END, "the whole schedule must be delivered");
        assertEq(staking.rewardReserve(), 0, "the schedule leaves no tail in the reserve");
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAmount.selector);
        staking.sweepUndistributedEmission();
    }

    function test_EmptyFirstYearStaysInTheReserve() public {
        vm.warp(block.timestamp + 365 days);                    // first year with an empty pool
        vm.prank(admin); staking.fundEmission(90_000_000e18);  // settles before funding: tbe == 0
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        _normaliseAt(alice, block.timestamp + 730 days);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);

        vm.prank(alice); staking.claimRewards();

        assertEq(staking.totalRewardDistributed(), AFTER_EMPTY_YEAR, "an empty first year is not delivered");
        assertEq(staking.rewardReserve(), ONE_YEAR_AT_R0, "the empty window stays in the reserve, for the sweep");
    }

    function test_OneWeiCannotCaptureTheSchedule() public {
        vm.prank(alice); staking.deposit(1, 730);                // tbe = 1 wei
        vm.prank(admin); staking.fundEmission(90_000_000e18);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);

        vm.prank(alice); staking.claimRewards();

        assertEq(staking.totalRewardDistributed(), ONE_WEI_DELIVERED, "1 wei scales the schedule by 1/1e21");
    }

    function test_UnderfundedWindowIsClampedToTheReserve() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        vm.prank(admin); staking.fundEmission(10_000_000e18);   // 1/9 of the programme
        _normaliseAt(alice, block.timestamp + 730 days);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);

        vm.prank(alice); staking.claimRewards();

        assertEq(staking.totalRewardDistributed(), 10_000_000e18, "the window stops at what the reserve holds");
        assertEq(staking.rewardReserve(), 0, "the reserve ends at zero");
    }

    /// LOCK-STALE, the split at unlockTime (`_postUnlockAtBase`) with nobody to normalise the lock:
    /// alice is the whole book, so the emission up to unlockTime (two years inside period 0,
    /// E_AT_UNLOCK) is hers at 1.25x and the rest of the programme is priced at 1.00x of the 1.25x
    /// weight that still sits in the denominator. Delivery = E_AT_UNLOCK + (E_END − E_AT_UNLOCK) ·
    /// 10 000 / 12 500 = 76 800 000e18 − 652 800 wei; the accumulator's per-share dust moves it by a
    /// few wei. The other 0.25/1.25 of the second part (13 200 000e18 + 652 800 wei) is not paid to
    /// anyone: it stays in the reserve for the sweep. Normalised at unlockTime (the first test) the
    /// same book takes the whole schedule.
    function test_LOCKSTALE_documents_aLoneLapsedLockLeftUntouchedLeavesItsBoostInTheReserve() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        vm.prank(admin); staking.fundEmission(90_000_000e18);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);

        vm.prank(alice); staking.claimRewards();

        uint256 delivered = E_AT_UNLOCK + (E_END - E_AT_UNLOCK) * 10_000 / 12_500;
        assertEq(delivered, 76_799_999_999_999_999_999_347_200, "derivation");
        assertApproxEqAbs(staking.totalRewardDistributed(), delivered, DUST,
                          "the boost is paid up to unlockTime and the base after it");
        assertEq(staking.rewardReserve(), 90_000_000e18 - staking.totalRewardDistributed(),
                 "what was not paid stays in the reserve");
    }

    function test_EmptyProgrammeSweepsTheWholeBudgetToTreasury() public {
        vm.prank(admin); staking.fundEmission(90_000_000e18);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);
        uint256 before = token.balanceOf(treasury);

        vm.prank(admin); staking.sweepUndistributedEmission();

        assertEq(token.balanceOf(treasury) - before, 90_000_000e18, "with no positions, everything goes to the treasury");
        assertEq(staking.totalRewardDistributed(), 0, "nothing delivered");
    }
}
