// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  HYPOTHESIS GRID — the named layer on top of the blind walk (docs/MONTE_CARLO.md).
//
//  Each test states one hypothesis of the grid (number of stakers, amounts from dust
//  to the cap, lock durations, halving and programme boundaries, loss and emergency
//  exit, the reward-debt rebase) and asserts a named invariant against a closed form
//  written here from the schedule as documented (12M a year for five years, then 6M a
//  year for five years, 90M in all), never read back from the contract.
//
//  Run: forge test --match-path test/montecarlo/Hypotheses.t.sol -vv
//  Mutants: .github/scripts/mutants.py, "montecarlo" block, one per test.
// =============================================================================

import {Base} from "../BlazePhoenixStaking.t.sol";

contract HypothesesTest is Base {
    uint256 internal constant DUST = 1e10;
    uint256 internal constant T0 = 1_900_000_000;
    uint256 internal constant P = 5 * 365 days;
    uint256 internal constant S = 120_000_000e18;
    uint256 internal constant R0 = (S / 2) / P;
    uint256 internal constant TOTAL = 90_000_000e18;
    uint256 internal constant MINW = 1_000e18;
    uint256 internal constant CAP = 30_000_000e18;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        staking.fundEmission(TOTAL);
    }

    /// The schedule as documented: period 0 at R0, period 1 at R0/2, closed at 90M.
    function _closed(uint256 ts) internal pure returns (uint256) {
        if (ts <= T0) return 0;
        uint256 dt = ts - T0;
        if (dt >= 2 * P) return TOTAL;
        uint256 p = dt / P;
        return (S - (S >> p)) + (R0 >> p) * (dt - p * P);
    }

    function _settle(address who) internal {
        vm.prank(who);
        staking.claimRewards();
    }

    // ── H1: one staker above MIN weight, ten years, every boundary ±1 s ──────
    /// MC-CLOSED with D == 0: a lone staker whose weight is above the damping mark is paid the
    /// closed form exactly at every halving and programme boundary, and 90M at the close.
    function test_H1_oneStakerAboveMinWeight_distributedEqualsTheClosedFormAtEveryBoundary() public {
        vm.prank(alice);
        staking.deposit(10_000e18, 90);
        uint256[11] memory at = [
            T0 + 1, T0 + 90 days, T0 + P - 1, T0 + P, T0 + P + 1, T0 + P + 400 days,
            T0 + 2 * P - 1, T0 + 2 * P, T0 + 2 * P + 1, T0 + 2 * P + 365 days, T0 + 3 * P
        ];
        for (uint256 i = 0; i < at.length; i++) {
            vm.warp(at[i]);
            _settle(alice);
            assertEq(staking.totalRewardDistributed(), _closed(at[i]), "H1: distributed != closed form");
            uint256 paid = staking.totalRewardsPaid();
            assertLe(paid, staking.totalRewardDistributed(), "H1: paid above distributed");
            assertLe(staking.totalRewardDistributed() - paid, DUST, "H1: rounding residue above DUST");
            assertEq(staking.auditInvariants(), 0, "H1: auditInvariants not zero");
        }
        assertEq(staking.totalRewardDistributed(), TOTAL, "H1: the programme did not close at 90M");
        assertEq(staking.rewardReserve(), 0, "H1: reserve left after a fully absorbed programme");
    }

    // ── H2: dust staker is damped by weight / MIN_EMISSION_WEIGHT ────────────
    function test_H2_dustStakerBelowMinWeight_isPaidTheClosedFormScaledByWeightOverMin() public {
        // The lock outlives every window read here: a lapsed lock is priced against the clock
        // (v3.1), so the weight the damping reads would otherwise change inside a window.
        vm.prank(alice);
        staking.deposit(1e18, 2555);
        uint256 tbe = staking.totalBoostedEffective();
        assertLt(tbe, MINW, "H2: fixture is not below the mark");
        uint256[4] memory at = [T0 + 1, T0 + 30 days, T0 + P + 1, T0 + 2555 days - 1];
        uint256 expected = 0;
        uint256 last = T0;
        for (uint256 i = 0; i < at.length; i++) {
            vm.warp(at[i]);
            uint256 w = staking.totalBoostedEffective();
            assertEq(w, tbe, "H2: the weight moved inside the lock");
            expected += (_closed(at[i]) - _closed(last)) * w / MINW;
            _settle(alice);
            last = at[i];
            assertEq(staking.totalRewardDistributed(), expected, "H2: damped emission != closed form * w / MIN");
        }
        assertLt(staking.totalRewardDistributed(), TOTAL / 100, "H2: dust absorbed more than 1% of the programme");
        assertEq(staking.auditInvariants(), 0, "H2: auditInvariants not zero");
    }

    // ── H3: N stakers, amounts from dust to the cap, random locks and claims ─
    /// MC-SHARE: paid + pending never exceeds distributed, and the residue is pro-protocol.
    function testFuzz_H3_nStakers_paidPlusPendingNeverExceedsDistributed(uint256 seed, uint8 nRaw, uint32 jump) public {
        uint256 n = bound(uint256(nRaw), 1, 100);
        uint256 dt = bound(uint256(jump), 1, 2 * P + 1 days);
        address[] memory who = new address[](n);
        uint256 rng = seed;
        for (uint256 i = 0; i < n; i++) {
            who[i] = address(uint160(uint256(keccak256(abi.encodePacked("h3", seed, i)))));
            token.mint(who[i], CAP);
            vm.prank(who[i]); token.approve(address(staking), type(uint256).max);
            rng = uint256(keccak256(abi.encodePacked(rng)));
            uint256 bits = 1 + rng % 85;                       // log-uniform 1 wei .. ~3.8e25
            uint256 amt = (uint256(1) << (bits - 1)) | (rng >> 128) & ((uint256(1) << (bits - 1)) - 1);
            if (amt > CAP) amt = CAP;
            uint256 ld = 90 + (rng >> 200) % 2466;             // 90..2555
            vm.prank(who[i]);
            staking.deposit(amt, ld);
        }
        vm.warp(T0 + dt);
        for (uint256 i = 0; i < n; i++) {
            rng = uint256(keccak256(abi.encodePacked(rng)));
            if (rng % 2 == 0) { vm.prank(who[i]); try staking.claimRewards() {} catch {} }
        }
        uint256 sum = 0;
        for (uint256 i = 0; i < n; i++) sum += staking.pendingRewards(who[i]);
        uint256 dist = staking.totalRewardDistributed();
        uint256 paid = staking.totalRewardsPaid();
        assertLe(paid + sum, dist + DUST, "H3: paid + pending above distributed");
        assertLe(dist, _closed(T0 + dt), "H3: distributed above the schedule");
        assertEq(staking.rewardReserve() + dist, TOTAL, "H3: reserve + distributed != funded");
        assertEq(staking.auditInvariants() & 0x1D, 0, "H3: auditInvariants raised (bit 1 excluded)");
    }

    // ── H4: a window that straddles the halving boundary ─────────────────────
    function testFuzz_H4_windowAcrossTheHalvingBoundary_equalsTheClosedFormDelta(uint32 pre, uint32 post) public {
        uint256 t1 = T0 + P - bound(uint256(pre), 0, 400 days);
        uint256 t2 = T0 + P + bound(uint256(post), 0, 400 days);
        vm.prank(alice);
        staking.deposit(10_000e18, 2555);
        vm.warp(t1); _settle(alice);
        uint256 d1 = staking.totalRewardDistributed();
        vm.warp(t2); _settle(alice);
        uint256 d2 = staking.totalRewardDistributed();
        assertEq(d1, _closed(t1), "H4: distributed at t1 != closed form");
        assertEq(d2 - d1, _closed(t2) - _closed(t1), "H4: window across the boundary != closed-form delta");
    }

    // ── H5: a loss, the breaker, and every emergency exit ────────────────────
    /// MC-EMG: no exit pays above the position, and the exits never exceed the backing at entry.
    function test_H5_lossThenBreaker_everyEmergencyExitIsBoundedByThePositionAndTheBacking() public {
        address[10] memory who = [alice, bob, carol, keeper, address(0x51), address(0x52), address(0x53), address(0x54), address(0x55), address(0x56)];
        for (uint256 i = 4; i < 10; i++) _fund(who[i]);
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(who[i]); staking.deposit(1_000e18 * (i + 1), 90 + 200 * i);
            if (i % 3 == 0) { vm.prank(who[i]); staking.borrow(100e18 * (i + 1)); }
        }
        vm.warp(T0 + 400 days);
        uint256 pot = token.balanceOf(address(staking));
        deal(address(token), address(staking), pot - pot * 30 / 100);
        vm.prank(keeper);
        staking.tripBreaker();
        assertTrue(staking.emergencyMode(), "H5: breaker did not open the emergency");
        uint256 backingAtEntry = token.balanceOf(address(staking));
        for (uint256 i = 0; i < 10; i++) staking.syncEquity(who[i]);
        uint256 paidSum = 0;
        for (uint256 i = 0; i < 10; i++) {
            (uint256 st,,,,,, uint256 pr, uint256 py,,,,,,) = staking.getUserInfo(who[i]);
            uint256 before = token.balanceOf(who[i]);
            vm.prank(who[i]);
            try staking.emergencyWithdraw() {} catch {}
            uint256 paid = token.balanceOf(who[i]) - before;
            assertLe(paid, st + pr + py + DUST, "H5: an exit paid above the position");
            paidSum += paid;
        }
        assertLe(paidSum, backingAtEntry, "H5: exits above the backing at entry");
    }

    // ── H6: the reward-debt rebase (lock extension, top-up) moves no reward ──
    function test_H6_lockExtensionAndTopUp_rebaseTheRewardDebtWithoutMovingPendingRewards() public {
        vm.prank(alice); staking.deposit(10_000e18, 90);
        vm.prank(bob);   staking.deposit(10_000e18, 90);
        vm.warp(T0 + 60 days); vm.roll(block.number + 11);
        uint256 p0 = staking.pendingRewards(alice);
        assertGt(p0, 0, "H6: nothing pending to rebase");
        // a settle pays or defers the pending credit; the rebase must neither create nor destroy it
        uint256 b0 = token.balanceOf(alice);
        vm.prank(alice); staking.lock(365);                   // rebase onto the new weight
        uint256 c1 = staking.pendingRewards(alice) + (token.balanceOf(alice) - b0);
        assertLe(p0 > c1 ? p0 - c1 : c1 - p0, DUST, "H6: lock extension moved the reward credit");
        vm.roll(block.number + 11);
        uint256 q1 = staking.pendingRewards(alice);
        uint256 b1 = token.balanceOf(alice);
        vm.prank(alice); staking.deposit(5_000e18, 365);      // top-up rebases again
        uint256 c2 = staking.pendingRewards(alice) + (token.balanceOf(alice) + 5_000e18 - b1);
        assertLe(q1 > c2 ? q1 - c2 : c2 - q1, DUST, "H6: top-up moved the reward credit");
        uint256 p2 = staking.pendingRewards(alice);
        vm.warp(T0 + 61 days); vm.roll(block.number + 11);
        assertGt(staking.pendingRewards(alice), p2, "H6: the rebased position stopped earning");
        assertEq(staking.auditInvariants(), 0, "H6: auditInvariants not zero");
    }
}
