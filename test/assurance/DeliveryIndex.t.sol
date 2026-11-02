// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================================
//  EMISSION DELIVERY INDEX — how much of the scheduled emission actually reaches positions.
//
//  Delivery = `totalRewardDistributed`; whatever is not delivered stays in `rewardReserve`
//  (and reaches the treasury through `sweepUndistributedEmission`). The literals below are
//  derived independently of the contract, from the published schedule:
//    PERIOD = 2·365 days, R0 = ⌊90 000 000e18 / PERIOD⌋ wei/s, 8 halving periods,
//    end-of-programme emission E_end = 180M − (180M >> 8) = 179 296 875e18,
//    one year at R0 = R0 · 365 days = 45M − 21 888 000 wei (the floor of R0, not a round 45M).
//
//  What each test measures:
//    full pool, start to end         -> delivery = E_end; the reserve keeps the 703 125e18 tail
//    empty pool in the first year    -> delivery = E_end − one year at R0
//    a single 1-wei position         -> delivery = E_end · 1 / 1e21 = 179 296 wei (the MIN_EMISSION_WEIGHT throttle)
//    empty pool for the whole programme -> the sweep sends all 180 000 000e18 to the treasury
//    under-funded window (10M)       -> pays what exists and stops (reserve clamp)
//    lone lock left untouched past its unlockTime -> delivery = E(unlock) + (E_end − E(unlock)) · 1.00x/1.25x;
//                                       the rest of its own boost stays in the reserve
//
//  A lock that lapses is normalised by the first transaction whose lock window reaches it (or by
//  anyone, with `pokeExpiredLock`); the fixtures below do that at unlockTime, which is what any
//  traffic does. The last test leaves it untouched and pins what the split at unlockTime pays.
// =============================================================================================

import {Base} from "../BlazePhoenixStaking.t.sol";

contract EmissionDeliveryIndexTest is Base {
    uint256 internal constant E_END             = 179_296_875e18;
    uint256 internal constant TAIL              = 703_125e18;
    uint256 internal constant ONE_YEAR_AT_R0    = 44_999_999_999_999_999_978_112_000;   // 45M − 21 888 000 wei
    uint256 internal constant AFTER_EMPTY_YEAR  = 134_296_875_000_000_000_021_888_000;  // E_END − ONE_YEAR_AT_R0
    uint256 internal constant ONE_WEI_DELIVERED = 179_296;                              // ⌊E_END / 1e21⌋
    uint256 internal constant E_FIRST_PERIOD    = 90_000_000e18;                        // E(start + PERIOD), exact anchor
    uint256 internal constant DUST              = 1e10;                                 // CONSERVATION_DUST

    /// @dev What any transaction's lock window does once `who`'s commitment has elapsed.
    function _normaliseAt(address who, uint256 unlock) internal {
        vm.warp(unlock); vm.roll(block.number + 2);
        vm.prank(keeper); staking.pokeExpiredLock(who);
    }

    function test_FullPoolReceivesTheScheduleLessTheTail() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        vm.prank(admin); staking.fundEmission(180_000_000e18);
        _normaliseAt(alice, block.timestamp + 730 days);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);

        vm.prank(alice); staking.claimRewards();

        assertEq(staking.totalRewardDistributed(), E_END, "everything but the tail must be delivered");
        assertEq(staking.rewardReserve(), TAIL, "the reserve at the end is the tail");
    }

    function test_EmptyFirstYearStaysInTheReserve() public {
        vm.warp(block.timestamp + 365 days);                    // first year with an empty pool
        vm.prank(admin); staking.fundEmission(180_000_000e18);  // settles before funding: tbe == 0
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        _normaliseAt(alice, block.timestamp + 730 days);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);

        vm.prank(alice); staking.claimRewards();

        assertEq(staking.totalRewardDistributed(), AFTER_EMPTY_YEAR, "an empty first year is not delivered");
        assertEq(staking.rewardReserve(), 180_000_000e18 - AFTER_EMPTY_YEAR,
                 "the empty window and the tail stay in the reserve, for the sweep");
    }

    function test_OneWeiCannotCaptureTheSchedule() public {
        vm.prank(alice); staking.deposit(1, 730);                // tbe = 1 wei
        vm.prank(admin); staking.fundEmission(180_000_000e18);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);

        vm.prank(alice); staking.claimRewards();

        assertEq(staking.totalRewardDistributed(), ONE_WEI_DELIVERED, "1 wei scales the schedule by 1/1e21");
    }

    function test_UnderfundedWindowIsClampedToTheReserve() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        vm.prank(admin); staking.fundEmission(10_000_000e18);   // 1/18 of the programme
        _normaliseAt(alice, block.timestamp + 730 days);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);

        vm.prank(alice); staking.claimRewards();

        assertEq(staking.totalRewardDistributed(), 10_000_000e18, "the window stops at what the reserve holds");
        assertEq(staking.rewardReserve(), 0, "the reserve ends at zero");
    }

    /// LOCK-STALE, the split at unlockTime (`_postUnlockAtBase`) with nobody to normalise the lock:
    /// alice is the whole book, so the emission up to unlockTime (the first period, exactly 90M)
    /// is hers at 1.25x and the rest of the programme is priced at 1.00x of the 1.25x weight that
    /// still sits in the denominator. Delivery = 90M + (E_END − 90M) · 10 000 / 12 500 = 161 437 500e18; the
    /// accumulator's per-share dust moves it by a few wei. The other 0.25/1.25 of the second part
    /// (17 859 375e18) is not paid to anyone: it stays in the reserve for the sweep, beside the
    /// tail. Normalised at unlockTime (the test above) the same book takes everything but the tail.
    function test_LOCKSTALE_documents_aLoneLapsedLockLeftUntouchedLeavesItsBoostInTheReserve() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 730);
        vm.prank(admin); staking.fundEmission(180_000_000e18);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);

        vm.prank(alice); staking.claimRewards();

        uint256 delivered = E_FIRST_PERIOD + (E_END - E_FIRST_PERIOD) * 10_000 / 12_500;
        assertEq(delivered, 161_437_500e18, "derivation");
        assertApproxEqAbs(staking.totalRewardDistributed(), delivered, DUST,
                          "the boost is paid up to unlockTime and the base after it");
        assertEq(staking.rewardReserve(), 180_000_000e18 - staking.totalRewardDistributed(),
                 "what was not paid stays in the reserve");
    }

    function test_EmptyProgrammeSweepsTheWholeBudgetToTreasury() public {
        vm.prank(admin); staking.fundEmission(180_000_000e18);
        vm.warp(staking.emissionEnd()); vm.roll(block.number + 2);
        uint256 before = token.balanceOf(treasury);

        vm.prank(admin); staking.sweepUndistributedEmission();

        assertEq(token.balanceOf(treasury) - before, 180_000_000e18, "with no positions, everything goes to the treasury");
        assertEq(staking.totalRewardDistributed(), 0, "nothing delivered");
    }
}
