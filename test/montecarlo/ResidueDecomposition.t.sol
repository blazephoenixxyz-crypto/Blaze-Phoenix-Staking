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
//  (the (k, j, i) coordinates and the R / S lines are the same).
// =============================================================================

import {console2} from "forge-std/Test.sol";
import {MonteCarloWalkTest} from "./MonteCarloWalk.t.sol";

contract ResidueDecompositionTest is MonteCarloWalkTest {
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
    // what a settle in the exit's own block would have done with the exiter's earned emission
    // (snapshot, cancel the emergency, claim, revert): paid to the holder / returned to the reserve
    uint256 internal settlePreviewPaid;
    uint256 internal settlePreviewToReserve;
    uint256 internal settlePreviewDistDown;
    uint256 internal settlePreviewPureToReserve;   // protocolReserve moved by the settle preview (pure LOCK-STALE)
    uint256 internal reserveReturned;   // rewardReserve moved by the hatches themselves (fix1112)
    uint256 internal pureReturned;      // protocolReserve moved by the hatches themselves (fix1112, `_settlePure`)
    uint256 internal previewCancelReverted; uint256 internal previewUnpauseReverted; uint256 internal previewClaimReverted;

    function _peekActor() internal view returns (address) {
        return actors[uint256(keccak256(abi.encodePacked(rng))) % nActors];
    }

    function _act(uint256 a) internal override returns (bool ok) {
        if (a != 15) return super._act(a);
        address who = _peekActor();
        (uint256 st, uint256 db,,,,, uint256 pr, uint256 py,,,,,,) = staking.getUserInfo(who);
        uint256 tsB = staking.totalStaked();
        uint256 tdB = staking.totalDebt();
        uint256 eB  = staking.totalPositiveEquity();
        uint256 pot = token.balanceOf(address(staking));
        uint256 balB = token.balanceOf(who);
        uint256 settledB = settled;
        if (staking.emergencyMode()) _previewSettle(who);
        uint256 resB = staking.rewardReserve();
        uint256 protB = staking.protocolReserve();
        ok = super._act(a);
        if (settled == settledB) return ok;   // the exit reverted
        nExits++;
        reserveReturned += staking.rewardReserve() - resB;
        pureReturned    += staking.protocolReserve() - protB;
        forfeitEmission += pr;
        forfeitPure     += py;
        uint256 paid = token.balanceOf(who) - balB;
        paidSum += paid;
        uint256 dTS = tsB - staking.totalStaked();
        uint256 dTD = tdB - staking.totalDebt();
        if (dTD > dTS) { underwaterExits++; return ok; }   // eroded or under water: payout 0
        uint256 payout = dTS - dTD;                        // principal - debt after the exit's own accrual
        payoutPostSum += payout;
        if (payout == 0) return ok;
        // eCorr = totalPositiveEquity - u.trackedEquity + payout; the exit's _applyBoost(u, 0, 0)
        // removes exactly u.trackedEquity from the total, so E_after + payout is eCorr.
        uint256 eCorr = staking.totalPositiveEquity() + payout;
        uint256 expected = payout;
        if (pot < eCorr) { nHaircutExits++; expected = _mulDiv(payout, pot, eCorr); }
        haircutFormula += payout - expected;
        haircutDebited += payout - paid;
        if (expected != paid) {
            console2.log("EXIT-MISMATCH", curI, expected, paid);
        }
        st; db;
    }

    /// Snapshot, lift the emergency, settle the holder's emission, read the deltas, revert.
    /// Nothing survives but the ghosts; the keccak chain is untouched.
    function _previewSettle(address who) internal {
        uint256 snap = vm.snapshotState();
        uint256 distB = staking.totalRewardDistributed();
        uint256 resB  = staking.rewardReserve();
        uint256 paidB = staking.totalRewardsPaid();
        uint256 protB = staking.protocolReserve();
        vm.prank(admin); try staking.cancelEmergency() {} catch { previewCancelReverted++; }
        vm.prank(admin); try staking.unpause() {} catch { previewUnpauseReverted++; }
        vm.prank(who);   try staking.claimRewards() {} catch { previewClaimReverted++; }
        // the claim settles the open window too; an emergency keeps lastRewardTime at now, so the
        // window is empty and the deltas are the holder's earned slice alone
        uint256 p = staking.totalRewardsPaid() - paidB;
        uint256 r = staking.rewardReserve() - resB;
        uint256 d = distB - staking.totalRewardDistributed();
        uint256 q = staking.protocolReserve() - protB;
        uint256 c1 = previewCancelReverted; uint256 c2 = previewUnpauseReverted; uint256 c3 = previewClaimReverted;
        vm.revertToState(snap);   // reverts this contract's storage too: the ghosts are written after
        settlePreviewPaid += p; settlePreviewToReserve += r; settlePreviewDistDown += d; settlePreviewPureToReserve += q;
        previewCancelReverted = c1; previewUnpauseReverted = c2; previewClaimReverted = c3;
    }

    function _mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b) / c;   // the operands are below 2^128, no phantom overflow here
    }

    function _runTo(uint256 k, uint256 j, uint256 stop) internal {
        curK = k; curJ = j;
        _fresh(k, j);
        forfeitEmission = 0; forfeitPure = 0; nExits = 0; nHaircutExits = 0; payoutPostSum = 0;
        paidSum = 0; haircutFormula = 0; haircutDebited = 0; underwaterExits = 0; reserveReturned = 0; pureReturned = 0;
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

    /// The maximiser of R in docs/MONTE_CARLO.md: (k=1, j=21, i=104), R = 55,437,465,372,907,153,741,701,104.
    /// Pins `_settleEmission`: the excess it returns to `rewardReserve` is the gap this test measures;
    /// mutants 67 and 339 on those lines turn it red.
    function test_RD_residue_1_21_104_isTheForfeitOfEmergencyExitsPlusLivePureYield() public {
        _runTo(1, 21, 104);
        uint256 dist = staking.totalRewardDistributed();
        uint256 paid = staking.totalRewardsPaid();
        (uint256 sumE, uint256 sumP) = _sumPending();
        int256 R = int256(dist) - int256(paid) - int256(sumE);
        console2.log("R", uint256(R));
        console2.log("distributed paid sumPendingRewards", dist, paid, sumE);
        console2.log("sumPendingPure rewardReserve funded", sumP, staking.rewardReserve(), staking.totalEmissionFunded());
        console2.log("emittedAt(now) lossInjected emergency", staking.emittedAt(block.timestamp), lossInjected, emergencyOpen);
        console2.log("exits forfeitEmission forfeitPure", nExits, forfeitEmission, forfeitPure);
        console2.log("nActors stakers settled", nActors, settled);
        int256 rest = R - int256(forfeitEmission) - int256(forfeitPure) - int256(sumP);
        console2.log("rest = R - forfeitE - forfeitP - livePure (abs, sign)", rest < 0 ? uint256(-rest) : uint256(rest), rest < 0 ? 0 : 1);
        console2.log("owed backing", staking.owed(), staking.backing());
        console2.log("protocolReserve totalBadDebt", staking.protocolReserve(), staking.totalBadDebt());
        (uint256 diff,) = _diffNow();
        console2.log("MC-CONSERVE diff here", diff);
        console2.log("settlePreview paid toReserve distDown", settlePreviewPaid, settlePreviewToReserve, settlePreviewDistDown);
        console2.log("settlePreview pureToReserve / hatch pureReturned", settlePreviewPureToReserve, pureReturned);
        console2.log("lastRewardTime now", staking.lastRewardTime(), block.timestamp);
        console2.log("preview reverts cancel unpause claim", previewCancelReverted, previewUnpauseReverted, previewClaimReverted);

        // the campaign's number, byte for byte, less the stale-weight excess the hatch now returns
        // (fix1112): 55437465372907153741701104 was R while the hatch did no reward maths
        assertEq(uint256(R) + settlePreviewToReserve, 55437465372907153741701104, "R of (1,21,104) as docs/MONTE_CARLO.md reports it, before fix1112");
        assertEq(nActors, 1, "one holder, who exits through the hatch");
        assertEq(nExits, 1, "one emergency exit");
        assertEq(lossInjected, 0, "a guardian emergency, no loss");
        // 1) the holder's earned emission, forfeited by the hatch: a settle in the same block pays
        //    exactly the quote the hatch discarded (quote == execution)
        assertEq(settlePreviewPaid, forfeitEmission, "the settle pays what the hatch forfeited");
        // 2) the stale-weight excess a settle returns to the reserves (LOCK-STALE, P1-C): the hatch
        //    moves the same wei itself (fix1112: `_settleEmission` to `rewardReserve`, `_settlePure`
        //    to `protocolReserve`), so it leaves distributed - paid. One holder without debt and no
        //    interest here, so the pure side is zero on both legs; the identity is pinned all the same.
        assertEq(settlePreviewDistDown, settlePreviewToReserve + settlePreviewPureToReserve, "LOCK-STALE moves distributed to the two reserves, nothing else");
        assertGt(settlePreviewToReserve, DUST, "the stale excess is a real amount here, not rounding");
        assertEq(reserveReturned, settlePreviewToReserve, "the hatch returns exactly the excess a settle would have returned");
        assertEq(reserveReturned + pureReturned, settlePreviewToReserve + settlePreviewPureToReserve, "_settlePure: the hatch returns the pure excess a settle would have returned");
        // 3) the rest is rounding, under the dust
        uint256 explained = forfeitEmission + sumP;
        assertLe(uint256(R) - explained, DUST, "R = forfeited emission + live pure yield, up to dust");
        assertGe(uint256(R), explained, "rounding is pro-protocol: never below the explained sum");
        assertLe(staking.owed(), staking.backing() + DUST, "no breach: the pot holds the forfeit that owed() still counts");
        assertGe(staking.owed(), uint256(R), "owed() reads high by R: counted with no position to claim it");
    }

    /// The maximiser of MC-CONSERVE in batch 3: (k=3, j=12, i=153).
    function test_RD_conserveDiff_3_12_153_isTheHaircutRetainedByBreachedExits() public {
        _runTo(3, 12, 153);
        (uint256 diff, bool lhsHigh) = _diffNow();
        console2.log("diff lhsHigh", diff, lhsHigh);
        console2.log("exits haircutExits underwater", nExits, nHaircutExits, underwaterExits);
        console2.log("payoutPost paid", payoutPostSum, paidSum);
        console2.log("haircutFormula haircutDebited harnessGhost", haircutFormula, haircutDebited, haircutRetained);
        console2.log("lossInjected emergency backingAtEmg", lossInjected, emergencyOpen, backingAtEmergency);
        console2.log("owed backing badDebt", staking.owed(), staking.backing(), staking.totalBadDebt());

        assertEq(diff, 129735866308897606758176, "MC-CONSERVE diff of (3,12,153) as the campaign logged it");
        assertTrue(lhsHigh, "the pot (with the loss ghost) reads above the book: the book debited more than it paid");
        assertEq(nExits, 1, "one exit");
        assertEq(nHaircutExits, 1, "the one exit was scaled: pot < eCorr");
        // the whole difference is the H-05 haircut, principal * (1 - pot / eCorr), wei for wei:
        // the equity the book debited minus what the hatch paid, and the formula read from the
        // contract's own inputs (pot before the exit, totalPositiveEquity after it + payout)
        assertEq(diff, haircutDebited, "diff == equity debited - paid");
        assertEq(diff, haircutFormula, "diff == payout - mulDiv(payout, pot, eCorr)");
        assertEq(diff, haircutRetained, "diff == the walk's own A3 ghost");
        assertEq(staking.totalBadDebt(), 0, "no bad debt booked: the exit was above water, nothing was interest");
    }
}
