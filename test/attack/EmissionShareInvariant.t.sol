// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Base, MockERC20} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice Stateful handler: stake / unstake / claim / warp over four debt-free actors, amounts from
///         1 wei to 5M, time from 0 s to 400 days a step, across the whole curve and past it.
///         Ghost fair share: each window's literal-curve emission split by the weights in force
///         during it (weights move only inside a call, and the ghost integrates before each call),
///         with the MIN_EMISSION_WEIGHT floor in the denominator.
contract EmissionShareHandler is Test {
    uint256 internal constant S = 120_000_000e18;
    uint256 internal constant P = 5 * 365 days;
    uint256 internal constant R0 = (S / 2) / P;
    uint256 internal constant MINW = 1_000e18;

    BlazePhoenixStaking public staking;
    MockERC20 public token;
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    uint256[4] public share;   // ghost fair share, wei
    uint256[4] public windows; // windows integrated while the actor had weight (rounding slack)
    uint256 public calls;      // handler calls: each settles at most the four actors
    uint256 public clock;
    uint256 public blk;
    uint256 internal t0;
    uint256 internal ghostT;
    uint256 internal constant START_BAL = 100_000_000e18;

    constructor(BlazePhoenixStaking s, MockERC20 t) {
        staking = s; token = t;
        t0 = s.emissionStart(); clock = block.timestamp; blk = block.number; ghostT = clock;
        for (uint256 i = 0; i < 4; i++) {
            t.mint(actors[i], START_BAL);
            vm.prank(actors[i]); t.approve(address(s), type(uint256).max);
        }
    }

    function curve(uint256 x) public view returns (uint256) {
        if (x <= t0) return 0;
        uint256 dt = x - t0;
        if (dt >= 2 * P) return S - (S >> 2);
        uint256 p = dt / P;
        return (S - (S >> p)) + (R0 >> p) * (dt - p * P);
    }

    function _weight(address a) internal view returns (uint256) {
        (uint256 st, , , , , , , , , uint256 ld, , , , ) = staking.getUserInfo(a);
        return st * staking.boostByDays(ld) / 10000;
    }

    /// Integrates the window since the last call at the weights it ran with.
    function _accrue() internal {
        calls++;
        uint256 d = curve(clock) - curve(ghostT);
        ghostT = clock;
        uint256 tbe = staking.totalBoostedEffective();
        if (d == 0 || tbe == 0) return;
        uint256 den = tbe < MINW ? MINW : tbe;
        for (uint256 i = 0; i < 4; i++) {
            uint256 w = _weight(actors[i]);
            if (w == 0) continue;
            share[i] += d * w / den;
            windows[i]++;
        }
    }

    function gain(uint256 i) public view returns (uint256) {
        (uint256 st, , , , , , , , , , , , , ) = staking.getUserInfo(actors[i]);
        return token.balanceOf(actors[i]) + st - START_BAL;
    }

    function stake(uint256 who, uint256 amt) external {
        _accrue();
        address a = actors[who % 4];
        amt = who % 3 == 0 ? bound(amt, 1, 2_000e18) : bound(amt, 1, 5_000_000e18);
        (uint256 st, , , , , , , , , , , , , ) = staking.getUserInfo(a);
        if (st + amt > 30_000_000e18 || clock >= staking.emissionEnd() || staking.maxLockDaysAvailable() < 90) return;
        vm.prank(a); staking.deposit(amt, 90);
    }

    function unstake(uint256 who, uint256 amt) external {
        _accrue();
        address a = actors[who % 4];
        (uint256 st, , , , , , , , , uint256 ld, uint256 ut, , , ) = staking.getUserInfo(a);
        if (st == 0 || (ld > 0 && clock < ut)) return;
        blk += 11; vm.roll(blk);
        vm.prank(a); staking.withdraw(bound(amt, 1, st));
    }

    function claim(uint256 who) external {
        _accrue();
        vm.prank(actors[who % 4]); staking.claimRewards();
    }

    function warp(uint256 dt) external {
        _accrue();
        clock += bound(dt, 0, 400 days);
        blk += 11;
        vm.warp(clock); vm.roll(blk);
    }
}

contract EmissionShareInvariantTest is Base {
    EmissionShareHandler h;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        staking.fundEmission(90_000_000e18);
        h = new EmissionShareHandler(staking, token);
        targetContract(address(h));
    }

    /// Σ paid ≤ distributed ≤ literal curve(now) ≤ TOTAL_REWARDS, and backing covers owed.
    /// Paid may sit above distributed by < 1 wei per settle (≤ 4 per call): `rewardDebt` is
    /// floored at each resync, and with dust weights the accumulator floor leaves no cushion
    /// (the I7 class, out of scope here; the strict form is red at fdc9a3f, kept out of the suite).
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    function invariant_ATK_INV_paidLeDistributedLeCurveLeCap() public view {
        uint256 paid = staking.totalRewardsPaid();
        uint256 dist = staking.totalRewardDistributed();
        uint256 c = h.curve(h.clock());
        assertLe(paid, dist + 4 * h.calls(), "ATK-INV: paid above distributed beyond the per-settle floor");
        assertLe(dist, c, "ATK-INV: distributed above the literal curve");
        assertLe(c, staking.TOTAL_REWARDS(), "ATK-INV: curve above the cap");
        assertGe(token.balanceOf(address(staking)) + 1e10, staking.owed(), "ATK-INV: backing below owed");
    }

    /// No actor ever receives more than its time-weighted share of the literal curve. Slack
    /// [derived]: the ghost floor loses < 1 wei a window; the payout telescopes per constant-weight
    /// segment and its floor can sit < 1 wei above the exact share per segment (≤ windows + 1).
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    function invariant_ATK_INV_noActorAboveItsShare() public view {
        for (uint256 i = 0; i < 4; i++) {
            assertLe(h.gain(i), h.share(i) + 2 * h.windows(i) + 2, "ATK-INV: an actor received above its share");
        }
    }
}
