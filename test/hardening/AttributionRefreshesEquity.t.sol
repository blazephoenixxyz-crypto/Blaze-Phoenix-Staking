// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice EQUITY-FRESH. Oracle (raw storage, never the code under test): after EVERY transaction
///         `totalPositiveEquity` is the sum over all positions of max(stored staked - stored debt, 0)
///         and each position's `trackedEquity` is its own summand. An interest attribution lowers
///         `staked`, so every attribution refreshes that summand in the same transaction. The
///         emergency haircut divides by the accumulator; its STALE-EQUITY guard measures only the
///         interest still UNATTRIBUTED, so an attribution that left the summand behind passed the
///         guard with a stale-high denominator and the payout then depended on the exit order.
///         Money oracle (the P1 one of test/fix1027): payout = eq * pot / sum(eq), with eq the true
///         equity at the frozen index.
///         Red at 9731e05: `_attributeFirst` booked the interest of a position the transaction
///         names (the caller of `pokeExpiredLock`, every entry of `pokeExpiredLocks`) and did not
///         refresh it. A borrower poked a lapsed lock and the breaker tripped at the same
///         timestamp: her `trackedEquity` read 5,000,000e18 against 4,700,000e18 stored, and a
///         pure staker exiting first was paid 7,500,000e18 where 7,614,213.19e18 was due.
contract AttributionRefreshesEquityTest is Base {
    uint256 internal constant S = 10_000_000e18;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USERS_SLOT = 36;   // as in test/fix1027/StaleQuantityFamily.t.sol
    uint256 internal constant TOL = 1e11;        // 10 x CONSERVATION_DUST, the tolerance of the P1 pin
    bytes4 internal constant STALE = bytes4(keccak256("Staking__StaleEquity()"));

    address internal dave = address(0xD4);

    // ── storage oracle ───────────────────────────────────────────────────────────────────
    function _ld(address u, uint256 off) internal view returns (uint256) {
        return uint256(vm.load(address(staking), bytes32(uint256(keccak256(abi.encode(u, USERS_SLOT))) + off)));
    }

    /// @dev max(stored staked - stored debt, 0): slot 0 and slot 1 of the position.
    function _storedEq(address u) internal view returns (uint256) {
        uint256 staked = _ld(u, 0);
        uint256 debt = _ld(u, 1);
        return staked > debt ? staked - debt : 0;
    }

    /// @dev True equity at the frozen index: staked - min(owed interest, staked) - debt, floored at 0.
    function _trueEq(address u) internal view returns (uint256) {
        uint256 staked = _ld(u, 0);
        uint256 debt = _ld(u, 1);
        if (debt != 0) {
            uint256 i = debt * (staking.accInterestPerDebt() - _ld(u, 5)) / WAD;
            staked -= i > staked ? staked : i;
        }
        return staked > debt ? staked - debt : 0;
    }

    function _assertFresh(address[] memory who, string memory door) internal view {
        uint256 sum;
        for (uint256 i; i < who.length; ++i) {
            uint256 eq = _storedEq(who[i]);
            assertEq(_ld(who[i], 8), eq, string.concat(door, ": trackedEquity is not max(staked - debt, 0)"));
            sum += eq;
        }
        assertEq(staking.totalPositiveEquity(), sum,
            string.concat(door, ": totalPositiveEquity is not the sum of the stored positive equity"));
    }

    function _three() internal view returns (address[] memory w) {
        w = new address[](3);
        w[0] = alice; w[1] = bob; w[2] = carol;
    }

    // ── fixture ─────────────────────────────────────────────────────────────────────────
    function _guardianPause() internal {
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(keeper);
        staking.pause();
    }

    function _lose(uint256 x) internal {
        deal(address(token), address(staking), token.balanceOf(address(staking)) - x);
    }

    /// @dev alice: 10M under `aliceLock` days, borrows `aPct` % of her limit. bob: 10M, 90 days,
    ///      debt-free. carol: 5M, 90 days, borrows `cPct` % of her limit (0 = debt-free).
    function _book(uint256 aliceLock, uint256 aPct, uint256 cPct) internal {
        vm.prank(alice); staking.deposit(S, aliceLock);
        vm.prank(bob);   staking.deposit(S, 90);
        vm.prank(carol); staking.deposit(S / 2, 90);
        vm.roll(block.number + 11);
        uint256 a = staking.maxBorrowOf(alice) * aPct / 100;
        vm.prank(alice); staking.borrow(a);
        uint256 c = staking.maxBorrowOf(carol) * cPct / 100;
        if (c != 0) { vm.prank(carol); staking.borrow(c); }
    }

    function _batch(address a, address b, address c) internal pure returns (address[] memory l) {
        l = new address[](3);
        l[0] = a; l[1] = b; l[2] = c;
    }

    /// @dev The doors through which a transaction names a position and attributes its interest.
    ///      0: a borrower pokes one lapsed lock (the caller is attributed, the window skips it).
    ///      1: a borrower names itself in a batch (attributed by name, the window skips it).
    ///      2: a third party's batch under a guardian pause (attributed by name, no window).
    ///      3: a third party's batch, unpaused (attributed by name; the window resyncs).
    ///      4: the other borrower pokes one lapsed lock (the window reaches alice).
    function _door(uint256 door) internal {
        if (door == 0) {
            vm.prank(alice); staking.pokeExpiredLock(bob);
        } else if (door == 1) {
            vm.prank(alice); staking.pokeExpiredLocks(_batch(alice, bob, carol));
        } else if (door == 2) {
            _guardianPause();
            vm.prank(dave); staking.pokeExpiredLocks(_batch(alice, carol, bob));
        } else if (door == 3) {
            vm.prank(dave); staking.pokeExpiredLocks(_batch(alice, bob, carol));
        } else {
            vm.prank(carol); staking.pokeExpiredLock(bob);
        }
    }

    // ── exits ───────────────────────────────────────────────────────────────────────────
    function _exitNow(address u) internal returns (uint256 got) {
        uint256 b0 = token.balanceOf(u);
        vm.prank(u);
        staking.emergencyWithdraw();
        got = token.balanceOf(u) - b0;
    }

    /// @dev An exit as the spec allows it: on a fresh book, or it waits with exactly
    ///      `Staking__StaleEquity` until every borrower is synced.
    function _exitOrSync(address u) internal returns (uint256 got) {
        uint256 b0 = token.balanceOf(u);
        vm.prank(u);
        try staking.emergencyWithdraw() {} catch (bytes memory err) {
            assertEq(bytes4(err), STALE, "only the stale-book guard may refuse an exit");
            staking.syncEquity(alice);
            staking.syncEquity(carol);
            vm.prank(u);
            staking.emergencyWithdraw();
        }
        got = token.balanceOf(u) - b0;
    }

    /// @dev Every one of the six exit orders pays each position eq * pot / sum(eq). `wait` lets an
    ///      exit wait for the sync (a book that still carries unattributed interest); without it
    ///      the first exit must go through as it stands.
    function _assertOrderFree(bool wait) internal {
        address[3] memory who = [alice, bob, carol];
        uint256[3] memory eq;
        uint256 sum;
        for (uint256 i; i < 3; ++i) { eq[i] = _trueEq(who[i]); sum += eq[i]; }
        uint256 pot = token.balanceOf(address(staking));
        assertLt(pot, sum, "fixture: the haircut must engage");

        uint8[3][6] memory orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
        for (uint256 p; p < 6; ++p) {
            uint256 snap = vm.snapshotState();
            uint256 paid;
            for (uint256 k; k < 3; ++k) {
                uint256 i = orders[p][k];
                uint256 got = wait ? _exitOrSync(who[i]) : _exitNow(who[i]);
                assertApproxEqAbs(got, eq[i] * pot / sum, TOL, "a payout depends on the exit order");
                paid += got;
            }
            assertLe(paid, pot, "over-drain");
            vm.revertToState(snap);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    //  The accumulator after each door (no emergency)
    // ══════════════════════════════════════════════════════════════════════════════════════

    /// RED at 9731e05. `pokeExpiredLock` attributes its caller and the borrower window skips it.
    function test_EQUITYFRESH_pokeExpiredLock_theCallersAttributionRefreshesItsEquity() public {
        _book(2555, 100, 0);
        vm.warp(block.timestamp + 3 * 365 days);
        _door(0);
        _assertFresh(_three(), "pokeExpiredLock, caller");
    }

    /// RED at 9731e05 (uid 4063). The caller names itself; its own lock still runs, so the batch
    /// does not normalise it and the borrower window skips it as the beneficiary.
    function test_EQUITYFRESH_pokeExpiredLocks_aBorrowerNamingItselfIsRefreshed() public {
        _book(365, 100, 0);
        vm.warp(block.timestamp + 180 days);
        _door(1);
        _assertFresh(_three(), "pokeExpiredLocks, self-named");
    }

    /// RED at 9731e05. Under a guardian pause the batch still attributes every name and carries
    /// no borrower window, so a named borrower whose lock still runs is left to nobody.
    function test_EQUITYFRESH_pokeExpiredLocks_underAGuardianPauseANamedBorrowerIsRefreshed() public {
        _book(2555, 100, 0);
        vm.warp(block.timestamp + 3 * 365 days);
        _door(2);
        _assertFresh(_three(), "pokeExpiredLocks, paused");
    }

    /// RED at 9731e05 (uid 4048). Twelve borrowers named in one batch: the window is capped at ten
    /// scans a transaction, so two of them were attributed and never reached.
    function test_EQUITYFRESH_pokeExpiredLocks_namedBorrowersBeyondTheWindowBudgetAreRefreshed() public {
        address[] memory all = new address[](13);
        for (uint256 i; i < 12; ++i) {
            address b = address(uint160(0xB000 + i));
            all[i] = b;
            _fund(b);
            vm.prank(b); staking.deposit(1_000_000e18, 365);
        }
        all[12] = carol;
        vm.prank(carol); staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        for (uint256 i; i < 12; ++i) {
            uint256 m = staking.maxBorrowOf(all[i]);
            vm.prank(all[i]); staking.borrow(m / 2);
        }
        vm.warp(block.timestamp + 180 days);

        vm.prank(dave);
        staking.pokeExpiredLocks(all);
        _assertFresh(all, "pokeExpiredLocks, 12 borrowers");
    }

    /// RED at 9731e05. A named position the token refuses to pay: its `lockStep` reverts inside the
    /// batch's try, after its interest was attributed outside it.
    function test_EQUITYFRESH_pokeExpiredLocks_aNamedPositionWhoseNormalisationFailsIsRefreshed() public {
        vm.prank(admin);
        staking.fundEmission(50_000_000e18);
        _book(90, 50, 0);
        vm.warp(block.timestamp + 120 days);
        _guardianPause();
        assertGt(staking.pendingRewards(alice), 0, "fixture: alice has emission to be paid");
        vm.mockCallRevert(address(token), abi.encodeWithSelector(token.transfer.selector, alice), "refused");

        uint256 sweeps0 = staking.totalLockSweeps();
        vm.prank(dave);
        staking.pokeExpiredLocks(_batch(alice, bob, carol));
        vm.clearMockedCalls();

        assertEq(staking.totalLockSweeps() - sweeps0, 2, "fixture: bob and carol normalised, alice refused");
        (,,,,,,,,, uint256 lockDays,,,,) = staking.getUserInfo(alice);
        assertEq(lockDays, 90, "fixture: alice's normalisation was rolled back");
        _assertFresh(_three(), "pokeExpiredLocks, refused normalisation");
    }

    /// The expiry boundary, one second either side, under a pause. One second BEFORE the unlock the
    /// batch skips alice (RED at 9731e05); AT the unlock its `lockStep` resyncs her (green there).
    function test_EQUITYFRESH_pokeExpiredLocks_oneSecondEitherSideOfTheUnlock() public {
        _book(91, 100, 0);
        _guardianPause();
        (,,,,,,,,,, uint256 unlockAlice,,,) = staking.getUserInfo(alice);

        uint256 snap = vm.snapshotState();
        vm.warp(unlockAlice - 1);
        vm.prank(dave); staking.pokeExpiredLocks(_batch(alice, bob, carol));
        (,,,,,,,,, uint256 lockDays,,,,) = staking.getUserInfo(alice);
        assertEq(lockDays, 91, "one second before the unlock alice keeps her lock");
        _assertFresh(_three(), "unlockTime - 1");
        vm.revertToState(snap);

        vm.warp(unlockAlice);
        vm.prank(dave); staking.pokeExpiredLocks(_batch(alice, bob, carol));
        (,,,,,,,,, lockDays,,,,) = staking.getUserInfo(alice);
        assertEq(lockDays, 0, "at the unlock alice is normalised");
        _assertFresh(_three(), "unlockTime");
    }

    /// Every door, any age of the book (through seizure and the interest clamp), any loan size.
    function testFuzz_EQUITYFRESH_everyPokeDoorLeavesTheAccumulatorAtTheStoredSum(
        uint256 dt, uint256 aPct, uint256 cPct, uint256 door, bool longLock
    ) public {
        dt = bound(dt, 91 days, 40 * 365 days);
        aPct = bound(aPct, 1, 100);
        cPct = bound(cPct, 1, 100);
        door = bound(door, 0, 4);
        _book(longLock ? 2555 : 90, aPct, cPct);
        vm.warp(block.timestamp + dt);
        _door(door);
        _assertFresh(_three(), "fuzz");
    }

    /// The refresh is the equity summand ALONE. The weights and the reward debts of the attributed
    /// position stay as its last settle left them, so nothing unsettled is repriced: what the
    /// caller was quoted before the poke is what it is quoted after it and what its claim pays.
    function test_EQUITYFRESH_theRefreshLeavesWeightsAndRewardDebtsUntouched() public {
        vm.prank(admin);
        staking.fundEmission(50_000_000e18);
        _book(2555, 50, 0);
        vm.warp(block.timestamp + 200 days);

        uint256 be = _ld(alice, 6);
        uint256 bp = _ld(alice, 7);
        uint256 rewardDebt = _ld(alice, 2);
        uint256 pureDebt = _ld(alice, 3);
        uint256 checkpoint = _ld(alice, 4);
        uint256 quote = staking.pendingRewards(alice);
        assertGt(quote, 0, "fixture: alice has unsettled emission");

        _door(0);

        assertEq(_ld(alice, 6), be, "trackedBoostedEffective moved");
        assertEq(_ld(alice, 7), bp, "trackedBoostedPure moved");
        assertEq(_ld(alice, 2), rewardDebt, "rewardDebt was rebased");
        assertEq(_ld(alice, 3), pureDebt, "pureYieldDebt was rebased");
        assertEq(_ld(alice, 4), checkpoint, "checkpointTime moved");
        assertEq(staking.pendingRewards(alice), quote, "the caller's unsettled emission was repriced");

        uint256 b0 = token.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards();
        assertEq(token.balanceOf(alice) - b0, quote, "the claim does not pay the quote");
        _assertFresh(_three(), "after the claim");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    //  The money: no emergency payout depends on the exit order
    // ══════════════════════════════════════════════════════════════════════════════════════

    /// RED at 9731e05 (audit-1106 C01). The borrower pokes, the breaker trips at the same timestamp.
    function test_EQUITYFRESH_EMG_aBorrowerPokeThenASameTimestampTrip_noPayoutDependsOnTheExitOrder() public {
        _book(2555, 100, 0);
        vm.warp(block.timestamp + 3 * 365 days);
        _lose(5_000_000e18);
        _door(0);
        vm.prank(dave); staking.tripBreaker();
        _assertOrderFree(false);
    }

    /// RED at 9731e05 (uid 4063). The borrower names itself in a batch, then the trip.
    function test_EQUITYFRESH_EMG_aSelfNamedBatchThenASameTimestampTrip_noPayoutDependsOnTheExitOrder() public {
        _book(365, 100, 0);
        vm.warp(block.timestamp + 300 days);
        _lose(5_000_000e18);
        _door(1);
        vm.prank(dave); staking.tripBreaker();
        _assertOrderFree(false);
    }

    /// RED at 9731e05. A third party's batch under a guardian pause, then the trip.
    function test_EQUITYFRESH_EMG_aPausedThirdPartyBatchThenASameTimestampTrip_noPayoutDependsOnTheExitOrder() public {
        _book(2555, 100, 0);
        vm.warp(block.timestamp + 3 * 365 days);
        _lose(5_000_000e18);
        _door(2);
        vm.prank(dave); staking.tripBreaker();
        _assertOrderFree(false);
    }

    /// RED at 9731e05. One day of interest on an active borrower is already far above the dust.
    function test_EQUITYFRESH_EMG_oneDayOfInterest_noPayoutDependsOnTheExitOrder() public {
        _book(2555, 100, 0);
        vm.warp(block.timestamp + 90 days - 12 hours);
        vm.prank(alice); staking.repay(1e18);          // alice is current; no lock has lapsed yet
        vm.warp(block.timestamp + 1 days);             // bob's lock lapsed 12 hours ago
        _lose(5_000_000e18);
        _door(0);
        vm.prank(dave); staking.tripBreaker();
        _assertOrderFree(false);
    }

    /// Any door, any age, any loss, any loan sizes, any exit order: an exit either goes through at
    /// eq * pot / sum(eq) or waits with `Staking__StaleEquity` for the sync and is then paid that.
    function testFuzz_EQUITYFRESH_EMG_aPokeBeforeTheTripNeverMakesAPayoutDependOnTheExitOrder(
        uint256 dt, uint256 lossPct, uint256 aPct, uint256 cPct, uint256 door, uint8 perm, bool longLock
    ) public {
        dt = bound(dt, 91 days, 4 * 365 days);
        lossPct = bound(lossPct, 20, 70);
        aPct = bound(aPct, 10, 100);
        cPct = bound(cPct, 10, 100);
        door = bound(door, 0, 4);
        _book(longLock ? 2555 : 90, aPct, cPct);
        vm.warp(block.timestamp + dt);
        _lose(token.balanceOf(address(staking)) * lossPct / 100);
        _door(door);
        vm.prank(dave); staking.tripBreaker();

        address[3] memory who = [alice, bob, carol];
        uint256[3] memory eq;
        uint256 sum;
        for (uint256 i; i < 3; ++i) { eq[i] = _trueEq(who[i]); sum += eq[i]; }
        uint256 pot = token.balanceOf(address(staking));
        assertLt(pot, sum, "fixture: the haircut must engage");

        uint8[3][6] memory orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
        uint8[3] memory o = orders[perm % 6];
        uint256 paid;
        for (uint256 k; k < 3; ++k) {
            uint256 got = _exitOrSync(who[o[k]]);
            assertApproxEqAbs(got, eq[o[k]] * pot / sum, TOL, "a payout depends on the exit order");
            paid += got;
        }
        assertLe(paid, pot, "over-drain");
    }

    /// Control, green before and after: the guard still measures what it measured. One second
    /// between the poke and the trip leaves interest unattributed, and the exit waits, by selector.
    function test_EQUITYFRESH_control_aTripOneSecondAfterThePokeStillWaitsForTheSync() public {
        _book(2555, 100, 0);
        vm.warp(block.timestamp + 3 * 365 days);
        _lose(5_000_000e18);
        _door(0);
        vm.warp(block.timestamp + 1);
        vm.prank(dave); staking.tripBreaker();

        vm.prank(bob);
        vm.expectRevert(STALE);
        staking.emergencyWithdraw();

        _assertOrderFree(true);
    }
}
