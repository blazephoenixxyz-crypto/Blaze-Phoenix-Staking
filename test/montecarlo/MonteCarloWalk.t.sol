// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  MONTE CARLO WALK — blind, pre-registered, reproducible.
//
//  docs/MONTE_CARLO.md holds the pre-registration (seeds, sampling, invariants,
//  tolerances, failure criteria), written and committed before the first run.
//  This file is the instrument. It does not use the forge fuzzer: the random
//  walk is driven by its own keccak chain so a failing case is identified by
//  (batch k, sequence j, action i) and replays with `MC_BATCH=k MC_SEQ=j`.
//
//  Run:   forge test --match-contract MonteCarloWalk -vv
//  Knobs: MC_BATCHES (default 4), MC_SEQS (24), MC_ACTIONS (160),
//         MC_BATCH / MC_SEQ (replay one case), MC_FIRST_BATCH (offset for CI shards).
//  Every line printed as `S\t...` or `R\t...` is a sample that
//  test/montecarlo/report.mjs turns into docs/MONTE_CARLO.md.
//
//  Mutants (see .github/scripts/mutants.py, "montecarlo"):
//    test_MC_blindWalk — kills `totalRewardDistributed` over-crediting, a
//    monotonicity break of accRewardPerShare, and a conservation hole.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {MockERC20} from "../BlazePhoenixStaking.t.sol";

contract MonteCarloWalkTest is Test {
    uint256 internal constant DUST = 1e10;                  // CONSERVATION_DUST
    uint256 internal constant CAP  = 30_000_000e18;         // MAX_STAKE_PER_WALLET
    uint256 internal constant MINW = 1_000e18;              // MIN_EMISSION_WEIGHT
    uint256 internal constant T0   = 1_900_000_000;
    uint256 internal constant SHARE_EVERY = 8;
    uint256 internal constant EMERGENCY_AFTER = 40;
    uint256 internal constant NACT = 18;

    address internal admin    = address(0xA11CE);
    address internal treasury = address(0x713A5);

    BlazePhoenixStaking internal staking;
    MockERC20 internal token;
    address[] internal actors;

    // ── per-sequence ghosts ──────────────────────────────────────────────────
    uint256 internal rng;
    uint256 internal donated;
    uint256 internal lossInjected;
    uint256 internal scheduled;          // ghost sum of the closed-form windows (before damping and cap)
    uint256 internal emitted;            // ghost sum of the windows as the contract prices them (A2)
    uint256 internal settled;
    uint256 internal lastAcc;
    uint256 internal lastAccPure;
    bool    internal emergencyOpen;
    uint256 internal backingAtEmergency;
    uint256 internal exitsPaid;
    uint256 internal haircutRetained;    // what breached-emergency exits left in the pot (A3)
    uint256 internal bit1Count;
    uint256 internal nActors;
    uint256 internal fails;

    // ── per-sequence maximisers ──────────────────────────────────────────────
    uint256 internal maxDiff; uint256 internal maxDiffAt;
    uint256 internal maxD;    uint256 internal maxDAt;
    int256  internal maxR;    uint256 internal maxRAt;
    int256  internal minR;

    // ── randomness: keccak chain, seeded as pre-registered ───────────────────
    function _seedOf(uint256 k, uint256 j) internal pure returns (uint256) {
        uint256 seedK = uint256(keccak256(abi.encodePacked("82ac0d0", k)));
        return uint256(keccak256(abi.encodePacked(seedK, j)));
    }
    function _rnd() internal returns (uint256) {
        rng = uint256(keccak256(abi.encodePacked(rng)));
        return rng;
    }
    function _uni(uint256 lo, uint256 hi) internal returns (uint256) {
        if (hi <= lo) return lo;
        return lo + _rnd() % (hi - lo + 1);
    }
    /// log-uniform on [lo, hi]: a uniform bit-length, then uniform inside it.
    function _logu(uint256 lo, uint256 hi) internal returns (uint256) {
        if (hi <= lo) return lo;
        uint256 bl = 0; uint256 x = lo; while (x > 0) { x >>= 1; bl++; }
        uint256 bh = 0; x = hi; while (x > 0) { x >>= 1; bh++; }
        uint256 b = _uni(bl, bh);
        uint256 v = b == 0 ? 0 : ((1 << (b - 1)) | (_rnd() & ((1 << (b - 1)) - 1)));
        if (v < lo) v = lo; if (v > hi) v = hi;
        return v;
    }
    /// The pre-registered mixture: one draw in five boundary, two in five log-uniform, two in five uniform.
    function _mix(uint256[] memory boundary, uint256 lo, uint256 hi) internal returns (uint256) {
        uint256 r = _rnd() % 10;
        if (r < 2 && boundary.length > 0) return boundary[_rnd() % boundary.length];
        if (r < 6) return _logu(lo, hi);
        return _uni(lo, hi);
    }
    function _actor() internal returns (address) { return actors[_rnd() % nActors]; }

    // ── fixture per sequence ─────────────────────────────────────────────────
    function _fresh(uint256 k, uint256 j) internal {
        vm.warp(T0);
        vm.roll(1);
        token = new MockERC20();
        vm.prank(admin);
        staking = new BlazePhoenixStaking(address(token), treasury);
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), address(this));
        token.mint(admin, 90_000_000e18);
        vm.prank(admin); token.approve(address(staking), type(uint256).max);
        vm.prank(admin); staking.fundEmission(90_000_000e18);

        rng = _seedOf(k, j);
        uint256[] memory nb = new uint256[](4); nb[0] = 1; nb[1] = 2; nb[2] = 100; nb[3] = 200;
        nActors = _mix(nb, 1, 200);
        delete actors;
        for (uint256 a = 0; a < nActors; a++) {
            address who = address(uint160(uint256(keccak256(abi.encodePacked("mc-actor", k, j, a)))));
            actors.push(who);
            token.mint(who, CAP + 1e18);
            vm.prank(who); token.approve(address(staking), type(uint256).max);
        }
        donated = 0; lossInjected = 0; scheduled = 0; emitted = 0; settled = 0;
        lastAcc = 0; lastAccPure = 0; emergencyOpen = false; backingAtEmergency = 0;
        exitsPaid = 0; haircutRetained = 0; bit1Count = 0;
        maxDiff = 0; maxDiffAt = 0; maxD = 0; maxDAt = 0; maxR = type(int256).min; maxRAt = 0; minR = type(int256).max;

        // whale-versus-dust, 10% of sequences
        if (_rnd() % 10 == 0 && nActors > 1) {
            vm.prank(actors[0]);
            try staking.deposit(CAP - 1e18, 365) {} catch {}
            for (uint256 a = 1; a < nActors; a++) {
                vm.prank(actors[a]);
                try staking.deposit(_uni(1, 1e18), 90) {} catch {}
            }
        }
    }

    // ── draws ────────────────────────────────────────────────────────────────
    function _amount() internal returns (uint256) {
        uint256[] memory b = new uint256[](10);
        b[0] = 1; b[1] = 2; b[2] = 1e18 - 1; b[3] = 1e18; b[4] = MINW - 1; b[5] = MINW; b[6] = MINW + 1;
        b[7] = CAP - 1; b[8] = CAP; b[9] = CAP + 1;
        return _mix(b, 1, CAP);
    }
    function _lockDays(uint256 maxNow) internal returns (uint256) {
        uint256[] memory b = new uint256[](9);
        b[0] = 90; b[1] = 91; b[2] = 2554; b[3] = 2555; b[4] = maxNow > 0 ? maxNow - 1 : 0; b[5] = maxNow;
        b[6] = maxNow + 1; b[7] = 0; b[8] = 89;
        return _mix(b, 90, maxNow < 90 ? 90 : maxNow);
    }
    function _quoted(uint256 max) internal returns (uint256) {
        uint256[] memory b = new uint256[](5);
        b[0] = 0; b[1] = 1; b[2] = max > 0 ? max - 1 : 0; b[3] = max; b[4] = max + 1;
        return _mix(b, 1, max);
    }
    function _timeJump() internal returns (uint256) {
        uint256 now_ = block.timestamp;
        uint256 start = staking.emissionStart();
        uint256 period = staking.HALVING_PERIOD();
        uint256 endT = staking.emissionEnd();
        uint256[] memory b = new uint256[](10);
        b[0] = 1;
        uint256 h1 = start + period;
        b[1] = h1 > now_ + 1 ? h1 - 1 - now_ : 1; b[2] = h1 > now_ ? h1 - now_ : 1; b[3] = h1 + 1 > now_ ? h1 + 1 - now_ : 1;
        b[4] = endT > now_ + 1 ? endT - 1 - now_ : 1; b[5] = endT > now_ ? endT - now_ : 1; b[6] = endT + 1 > now_ ? endT + 1 - now_ : 1;
        (,,,,,,,,, uint256 ld, uint256 ut,,,) = staking.getUserInfo(actors[_rnd() % nActors]);
        if (ld == 0) ut = now_;
        b[7] = ut > now_ + 1 ? ut - 1 - now_ : 1; b[8] = ut > now_ ? ut - now_ : 1; b[9] = ut + 1 > now_ ? ut + 1 - now_ : 1;
        uint256 r = _rnd() % 10;
        if (r < 2) return b[_rnd() % 10];
        if (r < 6) return _logu(1, 400 days);
        return _uni(1 hours, 60 days);
    }
    function _lossCut(uint256 pot) internal returns (uint256) {
        uint256[] memory b = new uint256[](4);
        b[0] = 1; b[1] = pot * 500 / 10_000; b[2] = pot * 6000 / 10_000; b[3] = pot > 0 ? pot - 1 : 0;
        uint256 r = _rnd() % 10;
        if (r < 2) return b[_rnd() % 4];
        if (r < 6) return pot * _logu(1, 6000) / 10_000;      // 0.01%..60%
        return pot * _uni(50, 6000) / 10_000;                 // 0.5%..60%
    }

    // ── one action ───────────────────────────────────────────────────────────
    function _act(uint256 a) internal returns (bool ok) {
        address who = _actor();
        uint256 lrt = staking.lastRewardTime();
        uint256 tbe = staking.totalBoostedEffective();
        uint256 reserveBefore = staking.rewardReserve();
        bool emgBefore = staking.emergencyMode();
        ok = false;
        if (a == 0) {
            (,,,,,,,,,,,,, uint256 maxNow) = staking.getUserInfo(who);
            uint256 d = _lockDays(maxNow);
            vm.prank(who);
            try staking.deposit(_amount(), d) { ok = true; } catch {}
        } else if (a == 1) {
            (,,, uint256 maxB,,,,,,,,,,) = staking.getUserInfo(who);
            vm.prank(who);
            try staking.borrow(_quoted(maxB)) { ok = true; } catch {}
        } else if (a == 2) {
            (, uint256 debt,,,,,,,,,,,,) = staking.getUserInfo(who);
            vm.prank(who);
            try staking.repay(_quoted(debt)) { ok = true; } catch {}
        } else if (a == 3) {
            (uint256 st,,,,,,,,,,,,,) = staking.getUserInfo(who);
            vm.prank(who);
            try staking.withdraw(_quoted(st)) { ok = true; } catch {}
        } else if (a == 4) {
            vm.prank(who);
            try staking.claimRewards() { ok = true; } catch {}
        } else if (a == 5) {
            vm.prank(who);
            try staking.claimPureYield() { ok = true; } catch {}
        } else if (a == 6) {
            (,,,,,,,,,,,,, uint256 maxNow) = staking.getUserInfo(who);
            vm.prank(who);
            try staking.lock(_lockDays(maxNow)) { ok = true; } catch {}
        } else if (a == 7) {
            vm.prank(who);
            try staking.pokeExpiredLock(_actor()) { ok = true; } catch {}
        } else if (a == 8) {
            uint256 n = _uni(1, nActors < 8 ? nActors : 8);
            address[] memory batch = new address[](n);
            for (uint256 i = 0; i < n; i++) batch[i] = _actor();
            vm.prank(who);
            try staking.pokeExpiredLocks(batch) { ok = true; } catch {}
        } else if (a == 9) {
            vm.prank(who);
            try staking.liquidate(_actor()) { ok = true; } catch {}
        } else if (a == 10) {
            if (emergencyOpen) return false;
            uint256 amt = _uni(1, 100_000e18);
            if (token.balanceOf(who) < amt) return false;
            vm.prank(who); token.transfer(address(staking), amt);
            donated += amt; ok = true;
        } else if (a == 11) {
            if (settled < EMERGENCY_AFTER || lossInjected > 0) return false;
            uint256 pot = token.balanceOf(address(staking));
            uint256 cut = _lossCut(pot);
            if (cut == 0 || cut > pot) return false;
            deal(address(token), address(staking), pot - cut);
            lossInjected += cut; ok = true;
        } else if (a == 12) {
            vm.prank(who);
            try staking.tripBreaker() { ok = true; } catch {}
        } else if (a == 13) {
            if (settled < EMERGENCY_AFTER) return false;
            try staking.declareEmergency() { ok = true; } catch {}
        } else if (a == 14) {
            try staking.syncEquity(_actor()) { ok = true; } catch {}
        } else if (a == 15) {
            (uint256 st, uint256 db,,,,, uint256 pr, uint256 py,,,,,,) = staking.getUserInfo(who);
            uint256 before = token.balanceOf(who);
            vm.prank(who);
            try staking.emergencyWithdraw() {
                ok = true;
                uint256 paid = token.balanceOf(who) - before;
                exitsPaid += paid;
                uint256 principal = st > db ? st - db : 0;
                if (paid < principal) haircutRetained += principal - paid;
                if (paid > st + pr + py + DUST) _fail("MC-EMG exit paid above the position");
            } catch {}
        } else if (a == 16) {
            staking.touchAuditSnapshot(); ok = true;
        } else {
            uint256 dt = _timeJump();
            vm.warp(block.timestamp + dt);
            vm.roll(block.number + 1 + dt / 12);
            ok = true;
        }
        if (ok) settled++;
        // MC-CLOSED / MC-EMIT-CAL ghosts: a window the contract settled, read from the clock it
        // moved, priced as `_windowReward` prices it (closed-form delta, damped below the mark,
        // capped by the reserve). Amendment A2 in docs/MONTE_CARLO.md.
        if (ok && tbe > 0 && !emgBefore && staking.lastRewardTime() != lrt) {
            uint256 w = staking.emittedAt(block.timestamp) - staking.emittedAt(lrt);
            scheduled += w;
            if (tbe < MINW) w = w * tbe / MINW;
            if (w > reserveBefore) w = reserveBefore;
            emitted += w;
        }
        if (!emergencyOpen && staking.emergencyMode()) {
            emergencyOpen = true;
            backingAtEmergency = token.balanceOf(address(staking));
        }
        // MC-SHARE for the actor touched, read at a settled instant only (amendment A1 in
        // docs/MONTE_CARLO.md: a quote projects the open window, the counters do not).
        if (_settledNow()) {
            uint256 pend = _pending(who);
            uint256 dist_ = staking.totalRewardDistributed(); uint256 paid_ = staking.totalRewardsPaid();
            uint256 unpaid = dist_ >= paid_ ? dist_ - paid_ : 0;
            if (pend > unpaid + DUST) _fail("MC-SHARE actor pending above the unpaid pot");
        }
    }

    function _settledNow() internal view returns (bool) {
        return staking.lastRewardTime() == block.timestamp && staking.lastInterestTime() == block.timestamp;
    }
    function _pending(address who) internal view returns (uint256 p) {
        try staking.pendingRewards(who) returns (uint256 v) { p = v; } catch { p = 0; }
    }

    uint256 internal curK; uint256 internal curJ; uint256 internal curI;
    function _fail(string memory why) internal {
        fails++;
        console2.log(string.concat("F\t", vm.toString(curK), "\t", vm.toString(curJ), "\t", vm.toString(curI), "\t", why));
    }

    // ── the invariants, after every action ───────────────────────────────────
    function _check(uint256 k, uint256 j, uint256 i, uint256 act) internal {
        uint256 lhs = token.balanceOf(address(staking)) + staking.totalBadDebt() + lossInjected;
        uint256 staked = staking.totalStaked();
        uint256 debt = staking.totalDebt();
        uint256 netP = staked >= debt ? staked - debt : 0;
        uint256 dist = staking.totalRewardDistributed();
        uint256 paid = staking.totalRewardsPaid();
        uint256 rhs = netP + staking.rewardReserve() + staking.protocolReserve() + (dist >= paid ? dist - paid : 0) + donated;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        // A3: inside a BREACHED emergency the haircut exits are governed by MC-EMG and MC-SOLVENT;
        // the identity's drift is recorded in the S line and in the maximiser, not asserted.
        bool breached = emergencyOpen && lossInjected > 0;
        if (diff > DUST && !breached) {
            _fail("MC-CONSERVE identity broken beyond DUST");
            uint256[] memory t = new uint256[](12);
            t[0] = token.balanceOf(address(staking)); t[1] = staking.totalBadDebt(); t[2] = lossInjected; t[3] = staked; t[4] = debt;
            t[5] = staking.rewardReserve(); t[6] = staking.protocolReserve(); t[7] = dist; t[8] = paid; t[9] = donated; t[10] = haircutRetained;
            t[11] = lhs > rhs ? 1 : 0;
            console2.log(string.concat("X\t", _tsv(t)));
        }
        if (diff > maxDiff) { maxDiff = diff; maxDiffAt = i; }

        if (lhs + DUST < staking.owed()) _fail("MC-SOLVENT backing + bad debt + loss < owed");
        if (paid > dist + DUST) _fail("MC-PAID totalRewardsPaid above totalRewardDistributed (INV-16 as the repository states it)");

        uint256 released = staking.totalEmissionFunded() - staking.rewardReserve();
        if (released > staking.emittedAt(block.timestamp)) _fail("MC-EMIT-CAL emission released above the schedule");
        if (released > emitted) _fail("MC-EMIT-CAL funded - reserve above the mirrored windows");
        if (staking.rewardReserve() > staking.TOTAL_REWARDS()) _fail("MC-EMIT-CAL reserve above TOTAL_REWARDS");

        uint8 bits = staking.auditInvariants();
        if (bits & 0x1C != 0) _fail("MC-AUDIT bits 2..4 raised");
        if (lossInjected == 0 && bits & 1 != 0) _fail("MC-AUDIT bit 0 raised without a loss");
        if (bits & 2 != 0) bit1Count++;

        uint256 acc = staking.accRewardPerShare(); uint256 accP = staking.accPureYieldPerShare();
        if (acc < lastAcc || accP < lastAccPure) _fail("MC-MONO accumulator decreased");
        lastAcc = acc; lastAccPure = accP;

        if (emergencyOpen && exitsPaid > backingAtEmergency) _fail("MC-EMG exits above the backing at entry");

        if (scheduled < released) _fail("MC-CLOSED emission released above the scheduled ghost");
        uint256 D = scheduled - released;
        if (D > maxD) { maxD = D; maxDAt = i; }

        uint256[] memory v = new uint256[](7);
        v[0] = k; v[1] = j; v[2] = i; v[3] = act; v[4] = diff; v[5] = D; v[6] = uint256(bits);
        console2.log(string.concat("S\t", _tsv(v)));

        if ((i % SHARE_EVERY == 0 || i + 1 == _actions()) && _settledNow()) _checkShare(k, j, i, dist, paid);
    }

    function _checkShare(uint256 k, uint256 j, uint256 i, uint256 dist, uint256 paid) internal {
        uint256 sum = 0;
        for (uint256 a = 0; a < nActors; a++) {
            sum += _pending(actors[a]);
            (uint256 st, uint256 db,,,,,,,,,,,,) = staking.getUserInfo(actors[a]);
            if (db > st + DUST) _fail("MC-DEBT debt above stake");
        }
        if (paid + sum > dist + DUST) _fail("MC-SHARE paid + pending above distributed");
        int256 R = int256(dist) - int256(paid) - int256(sum);
        if (R < -int256(DUST)) _fail("MC-SHARE rounding residue below -DUST");
        if (R > maxR) { maxR = R; maxRAt = i; }
        if (R < minR) minR = R;
        console2.log(string.concat("R\t", vm.toString(k), "\t", vm.toString(j), "\t", vm.toString(i), "\t", vm.toString(R)));
    }

    function _tsv(uint256[] memory v) internal pure returns (string memory out) {
        for (uint256 x = 0; x < v.length; x++) out = string.concat(out, x == 0 ? "" : "\t", vm.toString(v[x]));
    }
    function _logQ(uint256 k, uint256 j) internal view {
        uint256[] memory v = new uint256[](10);
        v[0] = k; v[1] = j; v[2] = _seedOf(k, j); v[3] = nActors; v[4] = settled; v[5] = maxDiff; v[6] = maxDiffAt;
        v[7] = maxD; v[8] = maxDAt; v[9] = bit1Count;
        string memory a = _tsv(v);
        uint256[] memory w = new uint256[](3);
        w[0] = lossInjected; w[1] = emergencyOpen ? 1 : 0; w[2] = block.timestamp - T0;
        console2.log(string.concat("Q\t", a, "\t", vm.toString(maxR), "\t", vm.toString(maxRAt), "\t", vm.toString(minR), "\t", _tsv(w)));
    }

    function _actions() internal view returns (uint256) { return vm.envOr("MC_ACTIONS", uint256(160)); }

    // ── the campaign ─────────────────────────────────────────────────────────
    uint256 internal totalActions;

    /// One sequence in its own call frame: the EVM memory of a sequence is released when the
    /// call returns, so a long campaign does not pay the quadratic memory cost of one frame
    /// (the deep CI job ran out of gas near the 120th sequence in a single frame). External so
    /// `this.runSequence` opens the frame; the ghosts and the counters live in storage.
    function runSequence(uint256 k, uint256 j) external {
        require(msg.sender == address(this), "MC: internal driver");
        curK = k; curJ = j;
        _fresh(k, j);
        uint256 nAct = _actions();
        for (uint256 i = 0; i < nAct; i++) {
            curI = i;
            uint256 a = _rnd() % NACT;
            _act(a);
            _check(k, j, i, a);
            totalActions++;
        }
        _logQ(k, j);
    }

    function test_MC_blindWalk() public {
        uint256 batches = vm.envOr("MC_BATCHES", uint256(1));   // in-suite default; the campaign sets 4 (local) or 16 (CI)
        uint256 first = vm.envOr("MC_FIRST_BATCH", uint256(0));
        uint256 seqs = vm.envOr("MC_SEQS", uint256(3));   // in-suite default; the campaign sets 24
        bool replay = vm.envOr("MC_BATCH", uint256(type(uint256).max)) != type(uint256).max;
        for (uint256 k = first; k < first + batches; k++) {
            for (uint256 j = 0; j < seqs; j++) {
                if (replay && (k != vm.envUint("MC_BATCH") || j != vm.envUint("MC_SEQ"))) continue;
                this.runSequence(k, j);
            }
        }
        console2.log(string.concat("T\t", vm.toString(totalActions), "\t", vm.toString(fails)));
        assertEq(fails, 0, "Monte Carlo walk: pre-registered invariant violated (see F lines)");
    }
}
