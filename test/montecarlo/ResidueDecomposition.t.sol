// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  RESIDUE DECOMPOSITION — replays one pre-registered Monte Carlo case (docs/MONTE_CARLO.md)
//  with the same keccak chain and the same actions, and accounts, wei by wei, for the two
//  quantities the campaign reports as distributions but does not explain:
//
//    R    = totalRewardDistributed - totalRewardsPaid - sum_i pendingRewards(i)   (the "residue")
//    diff = |backing + badDebt + loss - (netPrincipal + reserves + (distributed - paid) + donated)|
//           inside a breached emergency (MC-CONSERVE, amendment A3)
//
//  The ghosts are read only through views, so the trajectory is the one the campaign ran
//  (the (k, j, i) coordinates and the R / S lines are the same). Every term of a decomposition
//  is rebuilt on its own path (quotes before the exit, balances, the hatch's own reserve moves,
//  and a settle preview), never from R or diff themselves.
// =============================================================================

import {console2} from "forge-std/Test.sol";
import {MonteCarloWalkTest} from "./MonteCarloWalk.t.sol";

contract ResidueDecompositionTest is MonteCarloWalkTest {
    /// What a settle would do, read inside a snapshot that is reverted before anything else runs.
    struct Quote {
        uint256 paid;           // totalRewardsPaid moved (emission and pure yield paid to the holders)
        uint256 toReserve;      // rewardReserve moved (the stale-weight emission excess, LOCK-STALE)
        uint256 distDown;       // totalRewardDistributed moved down
        uint256 pureToReserve;  // protocolReserve moved (the stale-weight pure-yield excess)
        uint256 claims;         // claims that went through
    }

    // ── ghosts of the emergency exits (read before and after each successful exit) ──
    uint256 internal forfeitEmission;   // pendingRewards of the exiter the moment before it exits
    uint256 internal forfeitPure;       // pendingPureYield of the exiter the moment before it exits
    uint256 internal nExits;
    uint256 internal nHaircutExits;
    uint256 internal payoutPostSum;     // sum of (deltaTotalStaked - deltaTotalDebt): the equity debited
    uint256 internal paidSum;           // sum of what the exits transferred
    uint256 internal haircutFormula;    // sum of payout - mulDiv(payout, pot, eCorr), the H-05 scale
    uint256 internal haircutDebited;    // sum of payout - paid, measured
    uint256 internal underwaterExits;
    uint256 internal principalSum;      // sum of (staked - debt) of the exiters as getUserInfo quoted it before the exit
    uint256 internal potSum;            // sum of the pot each exit found
    // what a settle in the exit's own block would have done with the exiter's earned emission
    // (snapshot, cover the injected loss, lift the emergency, claim, revert); summed over the
    // exits that went through only
    uint256 internal settlePreviewPaid;
    uint256 internal settlePreviewToReserve;
    uint256 internal settlePreviewDistDown;
    uint256 internal settlePreviewPureToReserve;
    uint256 internal settlePreviewClaims;
    uint256 internal reserveReturned;   // rewardReserve moved by the hatches themselves (fix1112)
    uint256 internal pureReturned;      // protocolReserve moved by the hatches themselves (fix1112, `_settlePure`)

    function _peekActor() internal view returns (address) {
        return actors[uint256(keccak256(abi.encodePacked(rng))) % nActors];
    }

    /// The state an exit is measured against, read before it runs.
    struct ExitPre {
        address who;
        uint256 st; uint256 db; uint256 pr; uint256 py;
        uint256 tsB; uint256 tdB; uint256 pot; uint256 balB; uint256 settledB; uint256 resB; uint256 protB;
        Quote q;
    }

    function _act(uint256 a) internal override returns (bool ok) {
        if (a != 15) return super._act(a);
        ExitPre memory e = _exitPre();
        ok = super._act(a);
        if (settled == e.settledB) return ok;   // the exit reverted: its preview is dropped
        _exitPost(e);
    }

    function _exitPre() internal returns (ExitPre memory e) {
        e.who = _peekActor();
        (e.st, e.db,,,,, e.pr, e.py,,,,,,) = staking.getUserInfo(e.who);
        e.tsB = staking.totalStaked();
        e.tdB = staking.totalDebt();
        e.pot = token.balanceOf(address(staking));
        e.balB = token.balanceOf(e.who);
        e.settledB = settled;
        if (staking.emergencyMode()) {
            address[] memory one = new address[](1);
            one[0] = e.who;
            e.q = _settleQuote(one);
        }
        e.resB = staking.rewardReserve();
        e.protB = staking.protocolReserve();
    }

    function _exitPost(ExitPre memory e) internal {
        nExits++;
        settlePreviewPaid += e.q.paid; settlePreviewToReserve += e.q.toReserve; settlePreviewDistDown += e.q.distDown;
        settlePreviewPureToReserve += e.q.pureToReserve; settlePreviewClaims += e.q.claims;
        reserveReturned += staking.rewardReserve() - e.resB;
        pureReturned    += staking.protocolReserve() - e.protB;
        forfeitEmission += e.pr;
        forfeitPure     += e.py;
        principalSum    += e.st > e.db ? e.st - e.db : 0;
        potSum          += e.pot;
        uint256 paid = token.balanceOf(e.who) - e.balB;
        paidSum += paid;
        console2.log("EXIT i pr paid", curI, e.pr, paid);
        uint256 dTS = e.tsB - staking.totalStaked();
        uint256 dTD = e.tdB - staking.totalDebt();
        if (dTD > dTS) { underwaterExits++; return; }   // eroded or under water: payout 0
        uint256 payout = dTS - dTD;                     // principal - debt after the exit's own accrual
        payoutPostSum += payout;
        if (payout == 0) return;
        // eCorr = totalPositiveEquity - u.trackedEquity + payout; the exit's _applyBoost(u, 0, 0)
        // removes exactly u.trackedEquity from the total, so E_after + payout is eCorr.
        uint256 eCorr = staking.totalPositiveEquity() + payout;
        uint256 expected = payout;
        if (e.pot < eCorr) { nHaircutExits++; expected = _mulDiv(payout, e.pot, eCorr); }
        haircutFormula += payout - expected;
        haircutDebited += payout - paid;
        if (expected != paid) console2.log("EXIT-MISMATCH", curI, expected, paid);
    }

    /// Snapshot; if the pot is below owed() (an injected loss), top it up to owed() so the
    /// emergency can be lifted; cancel the emergency, unpause, let each holder claim, read the
    /// deltas, revert. Nothing survives but the returned quote; the keccak chain is untouched.
    function _settleQuote(address[] memory who) internal returns (Quote memory q) {
        uint256 snap = vm.snapshotState();
        uint256 owedNow = staking.owed();
        if (token.balanceOf(address(staking)) < owedNow) deal(address(token), address(staking), owedNow);
        vm.prank(admin); try staking.cancelEmergency() {} catch {}
        vm.prank(admin); try staking.unpause() {} catch {}
        // the claim settles the open window too; an emergency keeps lastRewardTime at now, so the
        // window is empty and the deltas are the holders' earned slices alone
        uint256 distB = staking.totalRewardDistributed();
        uint256 resB  = staking.rewardReserve();
        uint256 paidB = staking.totalRewardsPaid();
        uint256 protB = staking.protocolReserve();
        for (uint256 n = 0; n < who.length; n++) {
            vm.prank(who[n]);
            try staking.claimRewards() { q.claims++; } catch {}
        }
        q.paid = staking.totalRewardsPaid() - paidB;
        q.toReserve = staking.rewardReserve() - resB;
        q.distDown = distB - staking.totalRewardDistributed();
        q.pureToReserve = staking.protocolReserve() - protB;
        vm.revertToState(snap);
    }

    /// The same preview over every holder that still has a position or a quote, at the end of the replay.
    function _liveQuote() internal returns (Quote memory q, uint256 holders) {
        address[] memory live = new address[](nActors);
        for (uint256 a = 0; a < nActors; a++) {
            (uint256 st, uint256 db,,,,, uint256 pr, uint256 py,,,,,,) = staking.getUserInfo(actors[a]);
            if (st + db + pr + py > 0) live[holders++] = actors[a];
        }
        assembly ("memory-safe") { mstore(live, holders) }   // shrink the array to the holders found
        q = _settleQuote(live);
    }

    function _mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b) / c;   // the operands are below 2^128, no phantom overflow here
    }

    function _runTo(uint256 k, uint256 j, uint256 stop) internal {
        curK = k; curJ = j;
        _fresh(k, j);
        for (uint256 i = 0; i <= stop; i++) {
            curI = i;
            uint256 a = _rnd() % NACT;
            _act(a);
            _check(k, j, i, a);
        }
    }

    function _sumPending() internal view returns (uint256 e, uint256 p) {
        for (uint256 a = 0; a < nActors; a++) {
            e += _pending(actors[a]);
            (,,,,,,, uint256 py,,,,,,) = staking.getUserInfo(actors[a]);
            p += py;
        }
    }

    function _diffNow() internal view returns (uint256 diff, bool lhsHigh) {
        uint256 lhs = token.balanceOf(address(staking)) + staking.totalBadDebt() + lossInjected;
        uint256 staked = staking.totalStaked();
        uint256 debt = staking.totalDebt();
        uint256 netP = staked >= debt ? staked - debt : 0;
        uint256 dist = staking.totalRewardDistributed();
        uint256 paid = staking.totalRewardsPaid();
        uint256 rhs = netP + staking.rewardReserve() + staking.protocolReserve() + (dist >= paid ? dist - paid : 0) + donated;
        diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        lhsHigh = lhs > rhs;
    }

    /// The maximiser of R in docs/MONTE_CARLO.md: (k=6, j=10, i=144), R = 54,901,398,773,243,618,847,130,956.
    /// One emergency exit (i=144) inside a breached emergency, paid in full, and one holder left.
    /// R = the exiter's forfeited emission + the live holder's pure yield + the live holder's
    /// stale-weight excess (emission and pure) + a rest pinned as a literal, not decomposed further.
    /// Pins `_settleEmission` through the hatch's own move to `rewardReserve` and the preview's.
    function test_RD_residue_6_10_144_isTheForfeitOfOneEmergencyExitPlusTheLiveHolderPureYieldAndStaleExcess() public {
        _runTo(6, 10, 144);
        (uint256 sumE, uint256 sumP) = _sumPending();
        int256 R = int256(staking.totalRewardDistributed()) - int256(staking.totalRewardsPaid()) - int256(sumE);
        (Quote memory L, uint256 holders) = _liveQuote();
        console2.log("R", uint256(R));
        console2.log("distributed paid sumPendingRewards", staking.totalRewardDistributed(), staking.totalRewardsPaid(), sumE);
        console2.log("sumPendingPure rewardReserve protocolReserve", sumP, staking.rewardReserve(), staking.protocolReserve());
        console2.log("exits forfeitEmission forfeitPure", nExits, forfeitEmission, forfeitPure);
        console2.log("exit preview paid toReserve distDown", settlePreviewPaid, settlePreviewToReserve, settlePreviewDistDown);
        console2.log("exit preview pureToReserve claims; hatch reserveReturned", settlePreviewPureToReserve, settlePreviewClaims, reserveReturned);
        console2.log("live holders claims paid", holders, L.claims, L.paid);
        console2.log("live toReserve pureToReserve distDown", L.toReserve, L.pureToReserve, L.distDown);
        console2.log("lossInjected haircutExits underwater", lossInjected, nHaircutExits, underwaterExits);
        uint256 explained = forfeitEmission + forfeitPure + sumP + L.distDown;
        console2.log("R - explained (abs, R above)", uint256(R) > explained ? uint256(R) - explained : explained - uint256(R), uint256(R) >= explained);

        // the campaign's number, byte for byte
        assertEq(uint256(R), 54901398773243618847130956, "R of (6,10,144) as docs/MONTE_CARLO.md reports it");
        assertEq(nActors, 3, "three stakers drawn");
        assertEq(nExits, 1, "one emergency exit");
        assertGt(lossInjected, 0, "a breached emergency: the injected loss stands");
        assertEq(nHaircutExits + underwaterExits, 0, "the exit was above water and the pot covered eCorr: paid in full");
        assertEq(paidSum, payoutPostSum, "paid == the equity the book debited");
        // 1) the one holder left (an expired lock): its claim pays its two quotes and moves its
        //    stale-weight excess out of distributed; both are counted in distributed - paid and
        //    neither in sumE
        assertEq(holders, 1, "one holder left");
        assertEq(L.claims, 1, "the live holder's settle preview went through");
        assertEq(L.paid, sumE + sumP, "the live claim pays pendingRewards + pendingPureYield");
        assertGt(sumP, DUST, "the live pure yield is a real amount here");
        assertEq(L.distDown, L.toReserve + L.pureToReserve, "the live excess moves distributed to the two reserves, nothing else");
        // 2) the exiter's claim in the exit's own block (the loss covered so the emergency can be
        //    lifted) also sweeps the live holder's expired lock, which an emergency leaves frozen
        //    until the exit: the preview is the exiter's settle plus the live settle of step 1
        assertEq(settlePreviewClaims, 1, "the exit's settle preview went through");
        assertEq(forfeitPure, 0, "the exiter quoted no pure yield");
        assertEq(settlePreviewPaid, forfeitEmission + forfeitPure + L.paid, "the settle pays what the hatch forfeited (quote == execution), plus the swept live holder");
        // 3) the exiter's stale-weight excess (LOCK-STALE, P1-C) left distributed - paid with the
        //    hatch itself (fix1112), the same wei a settle would have moved, so it is not in R
        assertEq(settlePreviewDistDown, settlePreviewToReserve + settlePreviewPureToReserve, "LOCK-STALE moves distributed to the two reserves, nothing else");
        assertGt(reserveReturned, DUST, "the exiter's stale excess is a real amount here, not rounding");
        assertEq(settlePreviewToReserve, reserveReturned + L.toReserve, "the hatch returns exactly the emission excess a settle would have returned");
        assertEq(settlePreviewPureToReserve, pureReturned + L.pureToReserve, "_settlePure: the hatch returns the pure excess a settle would have returned");
        // 4) R = forfeit + live pure yield + live stale excess + rest; the rest is below DUST and
        //    not decomposed further
        assertGe(uint256(R), explained, "rounding is pro-protocol: never below the explained sum");
        assertEq(uint256(R) - explained, 26494901, "rest of R, below DUST, not decomposed further");
        assertGe(staking.owed(), uint256(R), "owed() reads high by R: counted with no position to claim it");
    }

    /// The maximiser of MC-CONSERVE in docs/MONTE_CARLO.md: (k=5, j=21, i=138).
    /// One holder, one exit inside a breached emergency whose injected loss left one wei in the
    /// pot: the hatch pays that wei and the book debits the whole net equity. diff is the H-05
    /// haircut of that exit, payout - mulDiv(payout, pot, eCorr), wei for wei.
    function test_RD_conserveDiff_5_21_138_isTheHaircutOfOneExitAgainstAOneWeiPot() public {
        _runTo(5, 21, 138);
        (uint256 diff, bool lhsHigh) = _diffNow();
        console2.log("diff lhsHigh", diff, lhsHigh);
        console2.log("exits haircutExits underwater", nExits, nHaircutExits, underwaterExits);
        console2.log("payoutPost paid principalQuoted", payoutPostSum, paidSum, principalSum);
        console2.log("haircutFormula haircutDebited harnessGhost", haircutFormula, haircutDebited, haircutRetained);
        console2.log("potAtExit lossInjected backingAtEmg", potSum, lossInjected, backingAtEmergency);
        console2.log("owed backing badDebt", staking.owed(), staking.backing(), staking.totalBadDebt());

        assertEq(diff, 26445994592660851827356800, "MC-CONSERVE diff of (5,21,138) as the campaign logged it");
        assertTrue(lhsHigh, "the pot (with the loss ghost) reads above the book: the book debited more than it paid");
        assertEq(nActors, 1, "one holder");
        assertEq(nExits, 1, "one exit");
        assertEq(nHaircutExits, 1, "the one exit was scaled: pot < eCorr");
        assertEq(underwaterExits, 0, "the exit was above water");
        // the pot the exit found: the walk's boundary loss cut (pot - 1) left one wei of the
        // backing the emergency opened with
        assertEq(potSum, 1, "one wei in the pot at the exit");
        assertEq(backingAtEmergency - lossInjected, potSum, "the injected loss took all but one wei of the backing at entry");
        assertEq(paidSum, 1, "the hatch paid the one wei the pot held");
        assertEq(payoutPostSum, principalSum, "the book debited the net equity getUserInfo quoted before the exit");
        // the whole difference is the H-05 haircut, principal * (1 - pot / eCorr), wei for wei:
        // the quoted net equity minus the wei paid, the equity the book debited minus what the
        // hatch paid, the formula read from the contract's own inputs (pot before the exit,
        // totalPositiveEquity after it + payout), and the walk's own A3 ghost
        assertEq(diff, principalSum - paidSum, "diff == quoted net equity - paid");
        assertEq(diff, haircutDebited, "diff == equity debited - paid");
        assertEq(diff, haircutFormula, "diff == payout - mulDiv(payout, pot, eCorr)");
        assertEq(diff, haircutRetained, "diff == the walk's own A3 ghost");
        assertEq(staking.totalBadDebt(), 0, "no bad debt booked: the exit was above water");
        assertEq(staking.backing(), 0, "the pot is empty after the exit");
    }
}
