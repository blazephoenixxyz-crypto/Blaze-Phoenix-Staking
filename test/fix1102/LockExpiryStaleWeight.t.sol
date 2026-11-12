// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice LOCK-STALE. A lock that lapsed between two touches is paid its boost only up to
///         `unlockTime` and 1.00x after it, in both channels, and the view quotes exactly that
///         payment. The settle splits the window at `unlockTime` on the clock the channel flows
///         on (`_postUnlockAtBase`): the emission curve for emission, time for pure yield. The
///         part of the window the lapsed boost did not earn returns to the reserve that funded
///         it. Red on 82febb5: the lapsed position collected 1,232,876.71 BZPX of emission and
///         749.42 BZPX of pure yield beyond the oracle. The `documents` tests pin what an O(1)
///         settle cannot reach: the window is apportioned on the clock, not on the accumulator,
///         and until the position is touched its old weight still sits in the denominators
///         (docs/KNOWN_ISSUES.md, LOCK-STALE).
contract LapsedLockSplitTest is Base {
    uint256 internal constant S = 1_000_000e18;
    uint256 internal constant DUST = 1e10;      // CONSERVATION_DUST
    uint256 internal constant BASE_BPS = 10_000;
    uint256 internal constant LOCK = 730;       // 1.25x; the emission window below runs past the first halving
    address internal dave = address(0xDA7E);

    /// Dave (stake S) holds a 1.00x position checkpointed at t0: a 90-day lock that lapsed and
    /// was normalised by his own claim at t0. Alice (stake S) locks LOCK days at t0. With
    /// `borrower`, carol borrows at t0, so interest (the pure-yield flow) runs over the window.
    /// Nobody touches anything between t0 and the settle, so the denominators hold still.
    function _fixture(bool emission, bool borrower) internal returns (uint256 t0, uint256 tu) {
        if (emission) { vm.prank(admin); staking.fundEmission(90_000_000e18); }
        uint256 start = staking.emissionStart();
        token.mint(dave, S);
        vm.prank(dave); token.approve(address(staking), type(uint256).max);
        vm.warp(start + 265 days); vm.roll(block.number + 1);
        vm.prank(dave); staking.deposit(S, 90);
        if (borrower) { vm.prank(carol); staking.deposit(10 * S, 90); }
        t0 = start + 365 days;
        vm.warp(t0); vm.roll(block.number + 20);
        vm.prank(dave); staking.claimRewards();
        if (borrower) { vm.prank(carol); staking.borrow(S); }
        vm.prank(alice); staking.deposit(S, LOCK);
        (, tu,,) = staking.lockInfoOf(alice);
        assertEq(staking.effectiveStakeOf(dave), S, "fixture: dave at 1.00x from t0");
    }

    /// Both positions settle in the block at t1; a sweep may pay alice inside dave's transaction,
    /// so each payment is the balance delta across both claims.
    function _settle(uint256 t1) internal returns (uint256 quoteA, uint256 paidA, uint256 paidD) {
        vm.warp(t1); vm.roll(block.number + 20);
        (, , uint256 bps, bool expired) = staking.lockInfoOf(alice);
        assertTrue(expired, "fixture: the lock lapsed and nobody touched it");
        assertEq(bps, BASE_BPS, "lockInfoOf reads 1.00x, what the settle pays after unlockTime");
        quoteA = staking.pendingRewards(alice) + staking.pendingPureYield(alice);
        uint256 a0 = token.balanceOf(alice);
        uint256 d0 = token.balanceOf(dave);
        vm.prank(dave);  staking.claimRewards();
        vm.prank(alice); staking.claimRewards();
        paidA = token.balanceOf(alice) - a0;
        paidD = token.balanceOf(dave) - d0;
    }

    /// Oracle: dave is the 1.00x unit. Per unit of weight, the window paid him what alice's weight
    /// earned at every instant; alice's weight was B/BASE of his up to tu and equal after it. The
    /// emission window flows on the curve: E(t) = `emittedAt(t)`, whose bonus halves at start + 2
    /// and start + 4 years, both inside this window (t0 = start + 1 year, tu = start + 3 years,
    /// t1 = start + 5 years + 180 days), so wall time would mis-split it. Inside one period the
    /// curve is linear and the two splits agree to the wei, so a window that crosses no turn cannot
    /// tell them apart.
    /// Expected:
    ///     alice = dave * (B * (E(tu) - E(t0)) + BASE * (E(t1) - E(tu))) / (BASE * (E(t1) - E(t0))).
    /// The emission alice's lapsed boost did not earn is back in `rewardReserve`:
    ///     reserve after = reserve before - (E(t1) - E(t0)) + (dave * B / BASE - alice).
    function test_LapsedLockEmissionIsPaidTheBoostUntilUnlockAndBaseAfter() public {
        (uint256 t0, uint256 tu) = _fixture(true, false);
        uint256 t1 = staking.emissionStart() + 5 * 365 days + 180 days;   // past the second bonus turn (start + 4 years)
        uint256 r0 = staking.rewardReserve();
        (uint256 quoteA, uint256 paidA, uint256 paidD) = _settle(t1);
        uint256 b = staking.boostByDays(LOCK);
        uint256 e0 = staking.emittedAt(t0);
        uint256 eu = staking.emittedAt(tu);
        uint256 e1 = staking.emittedAt(t1);
        assertGt(paidD, 0, "fixture: emission flowed");
        assertTrue((eu - e0) * (t1 - t0) != (e1 - e0) * (tu - t0),
            "fixture: the curve and wall-time splits differ in this window (it crosses a bonus turn)");
        uint256 expected = paidD * (b * (eu - e0) + BASE_BPS * (e1 - eu)) / (BASE_BPS * (e1 - e0));
        assertApproxEqAbs(paidA, expected, DUST, "lapsed boost paid past unlockTime (emission)");
        assertEq(quoteA, paidA, "pendingRewards is the payment");
        assertApproxEqAbs(staking.rewardReserve() + (e1 - e0) - r0, paidD * b / BASE_BPS - paidA, DUST,
            "the unearned boost returns to rewardReserve");
        emit log_named_decimal_uint("alice paid (BZPX)              ", paidA, 18);
        emit log_named_decimal_uint("returned to rewardReserve (BZPX)", paidD * b / BASE_BPS - paidA, 18);
    }

    /// Oracle: as above, on the time clock (one interest slice covers the whole window, priced at
    /// the rate sampled at its start, so the flow is linear in time). Expected:
    ///     alice = dave * (B * (tu - t0) + BASE * (t1 - tu)) / (BASE * (t1 - t0)).
    /// The pure yield alice's lapsed boost did not earn lands in `protocolReserve`, beside the
    /// reserve factor of the slice: reserve delta = slice * 3% + (dave * B / BASE - alice).
    function test_LapsedLockPureYieldIsPaidTheBoostUntilUnlockAndBaseAfter() public {
        (uint256 t0, uint256 tu) = _fixture(false, true);
        uint256 t1 = tu + 180 days;
        uint256 p0 = staking.protocolReserve();
        uint256 g0 = staking.totalInterestAccruedGlobal();
        (uint256 quoteA, uint256 paidA, uint256 paidD) = _settle(t1);
        uint256 b = staking.boostByDays(LOCK);
        assertGt(paidD, 0, "fixture: pure yield flowed");
        assertEq(staking.rewardReserve(), 0, "fixture: no emission in this window");
        uint256 expected = paidD * (b * (tu - t0) + BASE_BPS * (t1 - tu)) / (BASE_BPS * (t1 - t0));
        assertApproxEqAbs(paidA, expected, DUST, "lapsed boost paid past unlockTime (pure yield)");
        assertEq(quoteA, paidA, "pendingPureYield is the payment");
        uint256 slice = staking.totalInterestAccruedGlobal() - g0;
        uint256 cut = slice * staking.RESERVE_FACTOR_BPS() / BASE_BPS;
        assertApproxEqAbs(staking.protocolReserve() - p0 - cut, paidD * b / BASE_BPS - paidA, DUST,
            "the unearned boost returns to protocolReserve");
        emit log_named_decimal_uint("alice paid (BZPX)                ", paidA, 18);
        emit log_named_decimal_uint("returned to protocolReserve (BZPX)", paidD * b / BASE_BPS - paidA, 18);
    }

    /// One run of the shrinking-book fixture: alice (S, LOCK days) and dave (S, 2555 days, running
    /// throughout) beside a large holder q (20 S, 90 days) who exits one day before alice's unlock.
    /// With `poke`, alice is touched at her unlock instant. Returns alice's emission over the run
    /// and what dave's weight earned over the tail [tu, t1] (views only; nothing else is touched).
    function _shrinkingBook(bool poke) internal returns (uint256 gainA, uint256 tailD) {
        address q = address(0x51C0);
        vm.prank(admin); staking.fundEmission(90_000_000e18);
        token.mint(dave, S); token.mint(q, 20 * S);
        vm.prank(dave); token.approve(address(staking), type(uint256).max);
        vm.prank(q);    token.approve(address(staking), type(uint256).max);
        uint256 t0 = staking.emissionStart() + 10 days;
        vm.warp(t0); vm.roll(block.number + 1);
        vm.prank(dave);  staking.deposit(S, 2555);
        vm.prank(q);     staking.deposit(20 * S, 90);
        vm.prank(alice); staking.deposit(S, LOCK);
        (, uint256 tu,,) = staking.lockInfoOf(alice);
        uint256 a0 = token.balanceOf(alice);
        vm.warp(tu - 1 days); vm.roll(block.number + 20);
        vm.prank(q); staking.withdraw(20 * S);
        vm.warp(tu); vm.roll(block.number + 1);
        uint256 qD = staking.pendingRewards(dave);
        if (poke) { vm.prank(keeper); staking.pokeExpiredLock(alice); }
        vm.warp(tu + 30 days); vm.roll(block.number + 1);
        tailD = staking.pendingRewards(dave) - qD;
        vm.prank(alice); staking.claimRewards();
        gainA = token.balanceOf(alice) - a0;
    }

    /// documents. The split apportions the window on the emission clock, which is exact while the
    /// denominator holds still inside the window. When the book SHRANK inside it (here a large
    /// holder exits a day before the unlock), the accumulator grew faster after the unlock than
    /// the clock says, so part of that growth is credited at the lapsed boost: the position
    /// collects more than if it had been touched at its unlock, never more than its lapsed boost
    /// earned over the untouched tail (what it collected before the split existed). A book that
    /// grew inside the window moves the error the other way. Touching the position (its holder,
    /// `pokeExpiredLock`, the sweep carried by traffic) ends the tail. A settle that reads the
    /// accumulator at the unlock instant turns this red.
    function test_LOCKSTALE_documents_aBookThatShrankInsideTheWindowShiftsTheSplit() public {
        uint256 snap = vm.snapshotState();
        (uint256 x, uint256 tailD) = _shrinkingBook(false);
        vm.revertToState(snap);
        (uint256 y,) = _shrinkingBook(true);
        // dave runs at boost(2555); the lapsed boost of alice's tracked weight is (B - BASE) * S.
        uint256 bound = tailD * (staking.boostByDays(LOCK) - BASE_BPS) / staking.boostByDays(2555);
        emit log_named_decimal_uint("untouched over touched-at-unlock (BZPX)", x > y ? x - y : 0, 18);
        emit log_named_decimal_uint("lapsed boost over the tail (BZPX)      ", bound, 18);
        assertGt(x, y + DUST, "a shrinking book shifts part of the tail onto the lapsed boost");
        assertLe(x - y, bound + DUST, "never more than the lapsed boost earned over the tail");
    }
}

/// @notice LOCK-STALE in a populated book. Ten staggered lockers (1M each, 90..180 days) and one
///         staker committed for 2555 days; the committed staker transacts every `gap` (0 = never),
///         which carries the maintenance sweep. Oracle: the same run with every lock touched at
///         its exact unlock instant. The expired positions may collect no more than in the oracle
///         run. Red on 82febb5: the gains past unlock were paid at the lapsed boost, 317.78 (daily
///         traffic), 43,120.45 (no traffic) and 192,945.20 BZPX (5-year boosts) over the oracle.
contract LockExpiryStaleWeightTest is Base {
    uint256 internal constant STAKE = 1_000_000e18;
    uint256 internal constant DUST = 1e10;      // CONSERVATION_DUST
    address internal committed = address(0xC0);
    uint256 internal baseDays = 90;             // locker i locks baseDays + 10*i

    struct R {
        uint256 lockersGain;   // what the N lockers collected
        uint256 committedGain; // what the committed staker (lock running) collected
        uint256 maxDelay;      // max (normalisation time - unlockTime), seconds
    }

    function _locker(uint256 i) internal pure returns (address) { return address(uint160(0x1000 + i)); }

    function _mk(address who, uint256 amt, uint256 d) internal {
        token.mint(who, amt);
        vm.prank(who); token.approve(address(staking), type(uint256).max);
        vm.prank(who); staking.deposit(amt, d);
    }

    function _run(uint256 n, uint256 gap, uint256 tail, bool ideal) internal returns (R memory r) {
        vm.prank(admin); staking.fundEmission(90_000_000e18);
        uint256 t0 = vm.getBlockTimestamp();   // via_ir may re-read TIMESTAMP after a warp
        _mk(committed, STAKE, 2555);
        for (uint256 i = 0; i < n; i++) _mk(_locker(i), STAKE, baseDays + 10 * i);
        vm.roll(block.number + 20);

        uint256 first = t0 + baseDays * 1 days;
        uint256 end   = t0 + (baseDays + 10 * (n - 1)) * 1 days + tail;
        uint256[] memory syncedAt = new uint256[](n);
        uint256 cBal0 = token.balanceOf(committed);

        uint256 nextTraffic = gap == 0 ? type(uint256).max : first + gap / 2;   // off the unlock grid
        uint256 nextUnlockIdx = 0;
        uint256 t;
        while (true) {
            uint256 tu = (ideal && nextUnlockIdx < n) ? t0 + (baseDays + 10 * nextUnlockIdx) * 1 days : type(uint256).max;
            t = nextTraffic < tu ? nextTraffic : tu;
            if (t >= end) break;
            vm.warp(t); vm.roll(block.number + 1);
            if (t == tu) {
                vm.prank(keeper); staking.pokeExpiredLock(_locker(nextUnlockIdx));
                nextUnlockIdx++;
            }
            if (t == nextTraffic) {
                vm.prank(committed); staking.claimRewards();
                nextTraffic = t + gap;
            }
            for (uint256 i = 0; i < n; i++) {
                if (syncedAt[i] == 0 && !staking.isTrackedLocker(_locker(i))) syncedAt[i] = t;
            }
        }
        vm.warp(end); vm.roll(block.number + 1);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(_locker(i)); staking.claimRewards();
            if (syncedAt[i] == 0) syncedAt[i] = end;
            uint256 d = syncedAt[i] - (t0 + (baseDays + 10 * i) * 1 days);
            if (d > r.maxDelay) r.maxDelay = d;
        }
        // Lockers deposited their whole balance, so every token they hold now is emission paid to
        // them (by their own claim, a poke, or a sweep run by somebody else).
        for (uint256 i = 0; i < n; i++) r.lockersGain += token.balanceOf(_locker(i));
        vm.prank(committed); staking.claimRewards();
        r.committedGain = token.balanceOf(committed) - cBal0;
    }

    /// over: what the expired positions collected beyond the oracle run.
    /// shortfall: what the committed staker collected below the oracle run.
    /// maxDelay: the longest a lapsed lock waited for its normalisation in the untouched run.
    function _pair(uint256 n, uint256 gap, uint256 tail, string memory label)
        internal returns (uint256 over, uint256 shortfall, uint256 maxDelay)
    {
        uint256 s = vm.snapshotState();
        R memory a = _run(n, gap, tail, false);
        vm.revertToState(s);
        R memory b = _run(n, gap, tail, true);
        vm.revertToState(s);
        over      = a.lockersGain   > b.lockersGain   ? a.lockersGain   - b.lockersGain   : 0;
        shortfall = b.committedGain > a.committedGain ? b.committedGain - a.committedGain : 0;
        emit log_string(label);
        emit log_named_decimal_uint("  expired positions over the oracle (BZPX)", over, 18);
        emit log_named_decimal_uint("  committed staker under the oracle (BZPX)", shortfall, 18);
        emit log_named_uint        ("  max normalisation delay (s)             ", a.maxDelay);
        maxDelay = a.maxDelay;
    }

    function test_ExpiredLocksEarnNoMoreThanIfTouchedAtUnlock_DailyTraffic() public {
        (uint256 over,,) = _pair(10, 1 days, 30 days, "N=10 gap=1d tail=30d");
        assertLe(over, 10 * DUST, "expired positions paid the lapsed boost past unlockTime");
    }

    function test_ExpiredLocksEarnNoMoreThanIfTouchedAtUnlock_NoTraffic() public {
        (uint256 over,,) = _pair(10, 0, 30 days, "N=10 gap=none tail=30d");
        assertLe(over, 10 * DUST, "expired positions paid the lapsed boost past unlockTime");
    }

    /// Lockers at 1825..1915 days (2.0x..2.1x); the committed staker's lock is still running at the end.
    function test_ExpiredLocksEarnNoMoreThanIfTouchedAtUnlock_LargeBoost() public {
        baseDays = 1825;
        (uint256 over,,) = _pair(10, 0, 30 days, "N=10 base=1825d gap=none tail=30d");
        assertLe(over, 10 * DUST, "expired positions paid the lapsed boost past unlockTime");
    }

    /// documents. Until a lapsed position is touched (its owner, `pokeExpiredLock`, or the sweep
    /// carried by traffic), its old weight still sits in `totalBoostedEffective`, so a running
    /// lock is paid at a diluted rate; the part the lapsed boost did not earn goes back to
    /// `rewardReserve`, not to the running locks. Any staker can end the dilution with the
    /// permissionless poke. A settle that hands that part to the diluted stakers turns this red.
    /// The bound on the residue is the traffic: every transaction carries the lock sweep, so with
    /// a transaction a day no lapsed lock waits more than a day for its normalisation (measured
    /// 43,200 s, the half-day offset of the traffic from the unlock grid).
    function test_LOCKSTALE_documents_lapsedWeightDilutesRunningLocksUntilTouched() public {
        (, uint256 shortfall, uint256 maxDelay) = _pair(10, 1 days, 30 days, "N=10 gap=1d tail=30d");
        assertGt(shortfall, DUST, "a running lock is diluted by lapsed weight until it is touched");
        assertLe(maxDelay, 1 days, "the traffic sweep normalises a lapsed lock within one traffic interval");
    }
}
