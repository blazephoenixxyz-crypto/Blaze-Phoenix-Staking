// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  Blind Monte Carlo over the eight-year emission: random books walked through the programme,
//  every settle compared with a schedule written here from literals.
//
//  PRE-REGISTERED in docs/MONTE_CARLO_EMISSION.md: seeds, sampling, invariants, tolerances
//  and failure criteria were committed before the first run. Seeds are not chosen: batch k uses
//  keccak256(SEED_COMMIT, k), SEED_COMMIT being the short hash of the commit that introduced
//  the schedule. A failing case is (batch k, sequence j, action i) and replays with
//  ECW_BATCH=k ECW_SEQ=j.
//
//  ORACLE: the schedule as stated (60M flat over 8 years; 16M, 8M, 4M, 2M over four 2-year
//  periods), the throttle (weight / 1_000e18 below the mark) and the reserve cap, in this
//  file's own arithmetic. The contract's constants are never read to build an expectation.
//
//  Knobs (volume, not tolerances): ECW_BATCHES (in-suite 1; campaign 4 local), ECW_SEQS (3; 24),
//  ECW_ACTIONS (60; 160), ECW_FIRST_BATCH, ECW_BATCH / ECW_SEQ (replay one case).
//  Run: forge test --match-contract EmissionCurveWalk -vv
// =============================================================================

import {console2} from "forge-std/console2.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";

contract EmissionCurveWalkTest is Base {
    string  internal constant SEED_COMMIT = "385b297";               // the commit that introduced the schedule
    uint256 internal constant YEAR     = 365 days;
    uint256 internal constant PERIOD   = 63_072_000;
    uint256 internal constant LENGTH   = 252_288_000;
    uint256 internal constant ALL      = 90_000_000e18;
    uint256 internal constant BASE     = 60_000_000e18;
    uint256 internal constant MIN_W    = 1_000e18;
    uint256 internal constant WAD      = 1e18;
    uint256 internal constant CAP      = 30_000_000e18;
    uint256 internal constant FLOOR_DUST = 229_184_000;              // 197_376_000 + 31_808_000 (derived)
    address internal constant STRANGER = address(0x57A6E);

    BlazePhoenixStaking internal s;
    uint256 internal rng;
    uint256 internal start;
    uint256 internal end;
    address[] internal actors;

    // shadow of one sequence
    uint256 internal lastShadow;        // the settle clock, kept by this file
    uint256 internal funded;            // what fundEmission accepted
    uint256 internal gross;             // sum of the releases this file expected
    bool    internal clean;             // no window so far ran empty, throttled or reserve-capped
    uint256 internal reserveSeen;       // reserve after the last action

    // campaign statistics (per batch)
    uint256 internal nActions; uint256 internal nReverts; uint256 internal nSettles; uint256 internal nSplits;
    uint256 internal nCleanFull; uint256 internal nSeqs;
    uint256 internal worstGap;   uint256 internal worstGapJ;   uint256 internal worstGapI;
    uint256 internal worstUnder; uint256 internal worstUnderJ; uint256 internal worstUnderI;
    uint256 internal worstSplit; uint256 internal worstSplitJ; uint256 internal worstSplitI;

    // ── generator ───────────────────────────────────────────────────────────────────────────
    function _seedOf(uint256 k, uint256 j) internal pure returns (uint256) {
        uint256 seedK = uint256(keccak256(abi.encodePacked(SEED_COMMIT, k)));
        return uint256(keccak256(abi.encodePacked(seedK, j)));
    }
    function _draw() internal returns (uint256) {
        rng = uint256(keccak256(abi.encodePacked(rng)));
        return rng;
    }
    function _uniform(uint256 lo, uint256 hi) internal returns (uint256) {
        return hi <= lo ? lo : lo + _draw() % (hi - lo + 1);
    }
    /// log-uniform on [lo, hi]: a uniform bit-length, then uniform inside it
    function _logUniform(uint256 lo, uint256 hi) internal returns (uint256 v) {
        if (hi <= lo) return lo;
        uint256 bits;
        for (uint256 x = hi; x != 0; x >>= 1) ++bits;
        uint256 b = 1 + _draw() % bits;
        v = _draw() & ((uint256(1) << b) - 1);
        if (v < lo) v = lo;
        if (v > hi) v = hi;
    }
    /// the pre-registered mixture: 1 in 5 boundary, 2 in 5 log-uniform, 2 in 5 uniform
    function _mix(uint256[] memory edge, uint256 lo, uint256 hi) internal returns (uint256) {
        uint256 m = _draw() % 5;
        if (m == 0) return edge[_draw() % edge.length];
        return m < 3 ? _logUniform(lo, hi) : _uniform(lo, hi);
    }

    // ── the literal schedule ────────────────────────────────────────────────────────────────
    function _bonus(uint256 p) internal pure returns (uint256) {
        if (p == 0) return 16_000_000e18;
        if (p == 1) return 8_000_000e18;
        if (p == 2) return 4_000_000e18;
        return 2_000_000e18;
    }
    function _oracle(uint256 t) internal view returns (uint256 e) {
        if (t <= start) return 0;
        if (t >= end) return ALL;
        uint256 dt = t - start;
        e = (BASE / LENGTH) * dt;
        uint256 p;
        while (dt >= PERIOD) { e += _bonus(p); dt -= PERIOD; ++p; }
        e += (_bonus(p) / PERIOD) * dt;
    }
    /// the exact line, floored twice (so at most 2 wei under the rational value)
    function _line(uint256 t) internal view returns (uint256 n) {
        if (t <= start) return 0;
        if (t >= end) return ALL;
        uint256 dt = t - start;
        n = BASE * dt / LENGTH;
        uint256 p;
        while (dt >= PERIOD) { n += _bonus(p); dt -= PERIOD; ++p; }
        n += _bonus(p) * dt / PERIOD;
    }
    function _rate(uint256 t) internal view returns (uint256) {
        if (t >= end) return 0;
        return BASE / LENGTH + _bonus((t - start) / PERIOD) / PERIOD;
    }

    // ── the shadow settle: what one settle at the present second must release ───────────────
    function _expect(uint256 tbe, uint256 reserve) internal returns (uint256 release) {
        uint256 nowT = vm.getBlockTimestamp();
        if (tbe == 0) { if (nowT > lastShadow && lastShadow < end) clean = false; lastShadow = nowT; return 0; }
        uint256 t = nowT < end ? nowT : end;
        if (t <= lastShadow) return 0;
        release = _oracle(t) - _oracle(lastShadow);
        if (tbe < MIN_W) { release = release * tbe / MIN_W; clean = false; }
        if (release > reserve) { release = reserve; clean = false; }
        lastShadow = nowT;
    }

    /// Runs `call_` (already pranked by the caller of this helper), then holds every invariant.
    function _settled(bool ok, uint256 tbeBefore, uint256 accBefore, uint256 resBefore, uint256 addFunds, uint256 j, uint256 i)
        internal
    {
        ++nActions;
        if (!ok) { ++nReverts; _holds(j, i); return; }
        uint256 release = _expect(tbeBefore, resBefore);
        if (release != 0) ++nSettles;
        gross += release;
        funded += addFunds;
        // EC-3  one settle releases exactly the schedule's window, throttled and reserve-capped
        uint256 want = release == 0 ? 0 : release * WAD / tbeBefore;
        if (s.accRewardPerShare() - accBefore != want) _fail("EC-3 release", j, i);
        // EC-4  the settle clock is where this file keeps it
        if (s.lastRewardTime() != lastShadow) _fail("EC-4 clock", j, i);
        _holds(j, i);
    }

    function _holds(uint256 j, uint256 i) internal {
        uint256 nowT = vm.getBlockTimestamp();
        uint256 e = s.emittedAt(nowT);
        // EC-1  the curve and the rate are the stated schedule
        if (e != _oracle(nowT)) _fail("EC-1 curve", j, i);
        if (s.currentRewardPerSec() != _rate(nowT)) _fail("EC-1 rate", j, i);
        // EC-2  never above the exact line, never further under it than the derived floor dust
        uint256 line = _line(nowT);
        if (e > line + 2) _fail("EC-2 above the line", j, i);
        if (line > e && line - e > FLOOR_DUST) _fail("EC-2 floor dust", j, i);
        if (line > e && line - e > worstUnder) { worstUnder = line - e; worstUnderJ = j; worstUnderI = i; }
        // EC-5  ceiling: what stands distributed never passes the schedule nor the funding
        uint256 dist = s.totalRewardDistributed();
        uint256 res  = s.rewardReserve();
        if (dist > _oracle(nowT)) _fail("EC-5 over the schedule", j, i);
        if (dist > gross) _fail("EC-5 over the expected releases", j, i);
        if (gross > _oracle(nowT)) _fail("EC-5 releases over the schedule", j, i);
        // EC-6  the emission budget is conserved between the two sides
        if (dist + res != funded) _fail("EC-6 budget", j, i);
        // EC-7  every quoted reward is backed by tokens the contract holds outside stake and reserve
        uint256 quoted;
        for (uint256 a; a < actors.length; ++a) quoted += s.pendingRewards(actors[a]);
        uint256 held = token.balanceOf(address(s));
        if (held < s.totalStaked() + res) { _fail("EC-7 pot under stake + reserve", j, i); return; }
        held -= s.totalStaked() + res;
        if (quoted > held) { _fail("EC-7 unbacked quote", j, i); return; }
        if (held - quoted > worstGap) { worstGap = held - quoted; worstGapJ = j; worstGapI = i; }
        reserveSeen = res;
    }

    function _fail(string memory what, uint256 j, uint256 i) internal {
        console2.log("ECW FAIL", what);
        console2.log("  sequence / action", j, i);
        fail();
    }

    // ── actions ─────────────────────────────────────────────────────────────────────────────
    function _snap() internal view returns (uint256 tbe, uint256 acc, uint256 res) {
        return (s.totalBoostedEffective(), s.accRewardPerShare(), s.rewardReserve());
    }

    function _poke(uint256 j, uint256 i) internal {
        (uint256 tbe, uint256 acc, uint256 res) = _snap();
        vm.prank(STRANGER);
        try s.claimRewards() { _settled(true, tbe, acc, res, 0, j, i); } catch { _settled(false, tbe, acc, res, 0, j, i); }
    }

    function _deposit(uint256 j, uint256 i) internal {
        address who = actors[_draw() % actors.length];
        uint256[] memory amtEdge = new uint256[](10);
        amtEdge[0] = 1; amtEdge[1] = 2; amtEdge[2] = 1e18 - 1; amtEdge[3] = 1e18; amtEdge[4] = MIN_W - 1;
        amtEdge[5] = MIN_W; amtEdge[6] = MIN_W + 1; amtEdge[7] = CAP - 1; amtEdge[8] = CAP; amtEdge[9] = CAP + 1;
        uint256 amount = _mix(amtEdge, 1, CAP);
        uint256 maxNow = s.maxLockDaysAvailable();
        uint256[] memory dayEdge = new uint256[](9);
        dayEdge[0] = 90; dayEdge[1] = 91; dayEdge[2] = 2554; dayEdge[3] = 2555; dayEdge[4] = maxNow == 0 ? 0 : maxNow - 1;
        dayEdge[5] = maxNow; dayEdge[6] = maxNow + 1; dayEdge[7] = 0; dayEdge[8] = 89;
        uint256 lockDays = _mix(dayEdge, 90, maxNow < 90 ? 90 : maxNow);
        (uint256 tbe, uint256 acc, uint256 res) = _snap();
        vm.prank(who);
        try s.deposit(amount, lockDays) { _settled(true, tbe, acc, res, 0, j, i); } catch { _settled(false, tbe, acc, res, 0, j, i); }
    }

    function _claim(uint256 j, uint256 i) internal {
        address who = actors[_draw() % actors.length];
        (uint256 tbe, uint256 acc, uint256 res) = _snap();
        uint256 quote = s.pendingRewards(who);
        uint256 stakeBefore = s.totalStaked();
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        try s.claimRewards() {
            // EC-8  the quote read in the block is what the claim in that block pays
            if (s.totalStaked() == stakeBefore && token.balanceOf(who) - before != quote) _fail("EC-8 quote", j, i);
            _settled(true, tbe, acc, res, 0, j, i);
        } catch { _settled(false, tbe, acc, res, 0, j, i); }
    }

    function _fund(uint256 j, uint256 i) internal {
        uint256 room = ALL - funded;
        uint256[] memory edge = new uint256[](5);
        edge[0] = 1; edge[1] = room == 0 ? 0 : room - 1; edge[2] = room; edge[3] = room + 1; edge[4] = 0;
        uint256 amount = _mix(edge, 1, room == 0 ? 1 : room);
        (uint256 tbe, uint256 acc, uint256 res) = _snap();
        vm.prank(admin);
        try s.fundEmission(amount) { _settled(true, tbe, acc, res, amount, j, i); } catch { _settled(false, tbe, acc, res, 0, j, i); }
    }

    function _withdraw(uint256 j, uint256 i) internal {
        address who = actors[_draw() % actors.length];
        (uint256 staked,,,,,,,,,,,,,) = s.getUserInfo(who);
        uint256[] memory edge = new uint256[](4);
        edge[0] = 1; edge[1] = staked == 0 ? 0 : staked - 1; edge[2] = staked; edge[3] = staked + 1;
        uint256 amount = _mix(edge, 1, staked == 0 ? 1 : staked);
        (uint256 tbe, uint256 acc, uint256 res) = _snap();
        vm.prank(who);
        try s.withdraw(amount) { _settled(true, tbe, acc, res, 0, j, i); } catch { _settled(false, tbe, acc, res, 0, j, i); }
    }

    function _pokeLock(uint256 j, uint256 i) internal {
        address who = actors[_draw() % actors.length];
        (uint256 tbe, uint256 acc, uint256 res) = _snap();
        vm.prank(STRANGER);
        try s.pokeExpiredLock(who) { _settled(true, tbe, acc, res, 0, j, i); } catch { _settled(false, tbe, acc, res, 0, j, i); }
    }

    /// One time jump from the pre-registered mixture. One jump in four is ALSO walked in pieces on
    /// a snapshot first (EC-9): settling a window in k pieces releases the same as settling it once.
    function _passTime(uint256 j, uint256 i) internal {
        uint256 nowT = vm.getBlockTimestamp();
        uint256[] memory edge = new uint256[](11);
        uint256 turn = nowT < end ? start + ((nowT - start) / PERIOD + 1) * PERIOD : end;      // the next turn, or the close
        edge[0] = 1;
        edge[1] = turn > nowT + 1 ? turn - 1 - nowT : 1; edge[2] = turn > nowT ? turn - nowT : 1; edge[3] = turn + 1 > nowT ? turn + 1 - nowT : 1;
        edge[4] = end > nowT + 1 ? end - 1 - nowT : 1;   edge[5] = end > nowT ? end - nowT : 1;   edge[6] = end + 1 > nowT ? end + 1 - nowT : 1;
        (,,,,,,,,,, uint256 unlock,,,) = s.getUserInfo(actors[_draw() % actors.length]);
        edge[7] = unlock > nowT + 1 ? unlock - 1 - nowT : 1; edge[8] = unlock > nowT ? unlock - nowT : 1; edge[9] = unlock + 1 > nowT ? unlock + 1 - nowT : 1;
        edge[10] = nowT < end ? YEAR - (nowT - start) % YEAR : 1;                                // the next year mark
        uint256 m = _draw() % 5;
        uint256 jump = m == 0 ? edge[_draw() % edge.length] : (m < 3 ? _logUniform(1, 400 days) : _uniform(1 hours, 60 days));

        uint256 k = _draw() % 4 == 0 ? 2 + _draw() % 4 : 1;        // 2..5 pieces, one jump in four
        uint256 once;
        uint256 rBefore = s.rewardReserve();
        uint256 tbe0 = s.totalBoostedEffective();
        bool comparable;
        if (k > 1 && jump >= k) {
            uint256 id = vm.snapshotState();
            vm.warp(nowT + jump);
            vm.roll(vm.getBlockNumber() + 20);
            vm.prank(STRANGER);
            s.claimRewards();
            once = rBefore - s.rewardReserve();
            comparable = s.totalBoostedEffective() == tbe0;
            vm.revertToState(id);
        } else {
            k = 1;
        }
        for (uint256 q = 1; q <= k; ++q) {
            vm.warp(q == k ? nowT + jump : nowT + q * (jump / k));
            vm.roll(vm.getBlockNumber() + 20);
            _poke(j, i);
        }
        // Comparable only when no lock was normalised inside the window on either path: a
        // normalisation moves the weight and hands its stale excess back to the reserve.
        if (k > 1 && comparable && s.totalBoostedEffective() == tbe0) {
            ++nSplits;
            uint256 pieces = rBefore - s.rewardReserve();
            // EC-9  pieces never release more than the whole, and less only by the throttle's floors
            if (pieces > once) { _fail("EC-9 pieces released more", j, i); return; }
            if (once - pieces >= k) _fail("EC-9 pieces lost more than their floors", j, i);
            if (tbe0 >= MIN_W && pieces != once) _fail("EC-9 unthrottled pieces differ", j, i);
            if (once - pieces > worstSplit) { worstSplit = once - pieces; worstSplitJ = j; worstSplitI = i; }
        }
    }

    // ── one sequence ────────────────────────────────────────────────────────────────────────
    function _sequence(uint256 k, uint256 j, uint256 actions) internal {
        rng = _seedOf(k, j);
        // every sequence opens from the same clock, so a replayed case is the campaign's case
        vm.warp(1_800_000_000 + _draw() % 30 days);
        vm.roll(1_000_000);
        vm.prank(admin);
        s = new BlazePhoenixStaking(address(token), treasury);
        start = s.emissionStart();
        end   = s.emissionEnd();
        lastShadow = s.lastRewardTime();
        funded = 0; gross = 0; clean = true; reserveSeen = 0;
        token.mint(admin, ALL);
        vm.prank(admin);
        token.approve(address(s), type(uint256).max);
        delete actors;
        uint256 n = 1 + _draw() % 6;
        for (uint256 a; a < n; ++a) {
            address who = address(uint160(uint256(keccak256(abi.encodePacked("ecw-actor", k, j, a)))));
            actors.push(who);
            token.mint(who, 2 * CAP);
            vm.prank(who);
            token.approve(address(s), type(uint256).max);
        }
        // One sequence in four is a SCHEDULE sequence: fully funded and staked above the mark in
        // the opening second, positions never reduced, so the whole 90M has to come out.
        bool schedule = _draw() % 4 == 0;
        if (schedule) {
            (uint256 tbe, uint256 acc, uint256 res) = _snap();
            vm.prank(admin);
            s.fundEmission(ALL);
            _settled(true, tbe, acc, res, ALL, j, 0);
            (tbe, acc, res) = _snap();
            vm.prank(actors[0]);
            s.deposit(_uniform(MIN_W, CAP), _uniform(90, 2555));
            _settled(true, tbe, acc, res, 0, j, 0);
        }
        for (uint256 i = 1; i <= actions; ++i) {
            uint256 a = _draw() % (schedule ? 6 : 8);
            if (a < 2) _passTime(j, i);
            else if (a == 2) _deposit(j, i);
            else if (a == 3) _claim(j, i);
            else if (a == 4) _poke(j, i);
            else if (a == 5) _fund(j, i);
            else if (a == 6) _withdraw(j, i);
            else _pokeLock(j, i);
        }
        // the forced close: past the end, one settle, then the sweep
        if (vm.getBlockTimestamp() <= end) { vm.warp(end + 1 + _draw() % 400 days); vm.roll(vm.getBlockNumber() + 20); }
        _poke(j, actions + 1);
        // EC-10  the close: the releases never pass the budget (a stale excess handed back to the
        //        reserve may be released again, so the funding is not their ceiling); a clean,
        //        fully funded sequence has released the whole 90M to the wei
        if (gross > ALL) _fail("EC-10 released over the budget", j, actions + 1);
        if (schedule && !clean) _fail("EC-10 a schedule sequence was not clean", j, actions + 1);
        if (clean && funded == ALL && schedule) {
            if (gross != ALL) _fail("EC-10 a clean full sequence did not release 90M", j, actions + 1);
            ++nCleanFull;
        }
        uint256 residue = s.rewardReserve();
        uint256 tBefore = token.balanceOf(treasury);
        vm.prank(admin);
        try s.sweepUndistributedEmission() {
            if (token.balanceOf(treasury) - tBefore != residue) _fail("EC-10 the sweep moved something else than the reserve", j, actions + 2);
            if (s.rewardReserve() != 0) _fail("EC-10 the sweep left a reserve", j, actions + 2);
        } catch {
            if (residue != 0) _fail("EC-10 a residue could not be swept", j, actions + 2);
        }
        ++nSeqs;
    }

    function test_ECW_blindWalk() public {
        uint256 batches = vm.envOr("ECW_BATCHES", uint256(1));     // in-suite default; the campaign sets 4
        uint256 first   = vm.envOr("ECW_FIRST_BATCH", uint256(0));
        uint256 seqs    = vm.envOr("ECW_SEQS", uint256(3));        // in-suite default; the campaign sets 24
        uint256 actions = vm.envOr("ECW_ACTIONS", uint256(60));    // in-suite default; the campaign sets 160
        bool replay = vm.envOr("ECW_BATCH", uint256(type(uint256).max)) != type(uint256).max;
        if (replay) { _sequence(vm.envUint("ECW_BATCH"), vm.envUint("ECW_SEQ"), actions); return; }
        for (uint256 k = first; k < first + batches; ++k) {
            nActions = 0; nReverts = 0; nSettles = 0; nSplits = 0; nCleanFull = 0; nSeqs = 0;
            worstGap = 0; worstUnder = 0; worstSplit = 0;
            for (uint256 j; j < seqs; ++j) _sequence(k, j, actions);
            // TSV: batch, sequences, actions, reverts, settles, splits, clean full closes,
            //      worst backing gap (wei, seq, action), worst deficit under the line, worst split loss
            console2.log(string.concat(
                "ECW\t", vm.toString(k), "\t", vm.toString(nSeqs), "\t", vm.toString(nActions), "\t", vm.toString(nReverts), "\t",
                vm.toString(nSettles), "\t", vm.toString(nSplits), "\t", vm.toString(nCleanFull)));
            console2.log(string.concat(
                "ECW-WORST\t", vm.toString(k), "\tgap\t", vm.toString(worstGap), "\t", vm.toString(worstGapJ), "\t", vm.toString(worstGapI),
                "\tunder\t", vm.toString(worstUnder), "\t", vm.toString(worstUnderJ), "\t", vm.toString(worstUnderI)));
            console2.log(string.concat(
                "ECW-SPLIT\t", vm.toString(k), "\t", vm.toString(worstSplit), "\t", vm.toString(worstSplitJ), "\t", vm.toString(worstSplitI)));
        }
    }
}
