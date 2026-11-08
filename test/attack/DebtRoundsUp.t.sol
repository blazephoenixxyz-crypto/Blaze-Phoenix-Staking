// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {EmissionShareHandler} from "./EmissionShareInvariant.t.sol";

/// @notice I7 for the reward debts: `_checkpoint` rounds `rewardDebt` and `pureYieldDebt` UP.
///
/// A floored debt hands the position the dropped fraction (< 1 wei) at every resync. The
/// accumulator's own floor leaves a cushion of (R·WAD mod tbe) / WAD per window, under 1 wei once
/// the weight is dust (tbe < 1e18), so with dust weights the sum paid could pass the sum
/// distributed, and the wei came out of the balance that backs principal and reserves: the last
/// exit came up short. Rounded up, each constant-weight segment pays
/// floor(w·A1) − ceil(w·A0) <= w·(A1 − A0), so Σ paid <= Σ distributed, in both channels.
///
/// RED at 1f54743 (debts floored), GREEN with the debts rounded up.
contract DebtRoundsUpTest is Base {
    uint256 constant WAD = 1e18;
    /// Slot of the private `_users` mapping, as in BlazePhoenixStaking.t.sol. Every read checks
    /// the staked word against `getUserInfo`, so a layout change fails loudly.
    uint256 constant USERS_SLOT = 36;
    uint256 constant OFF_REWARD_DEBT = 2;
    uint256 constant OFF_PURE_DEBT = 3;
    uint256 constant OFF_BE = 6;   // trackedBoostedEffective
    uint256 constant OFF_BP = 7;   // trackedBoostedPure

    EmissionShareHandler h;
    address[] syb;
    uint256 clk;
    uint256 bn;   // own clock: via_ir caches block.timestamp / block.number inside a test

    function _word(address a, uint256 off) internal view returns (uint256) {
        uint256 base = uint256(keccak256(abi.encode(a, USERS_SLOT)));
        (uint256 st,,,,,,,,,,,,,) = staking.getUserInfo(a);
        assertEq(uint256(vm.load(address(staking), bytes32(base))), st, "USERS_SLOT: staked word moved");
        return uint256(vm.load(address(staking), bytes32(base + off)));
    }

    /// Σ paid <= Σ distributed, and the balance still backs principal plus both reserves (the
    /// over-paid wei left from there). Only for books without debt: a loan leaves the balance.
    function _assertWhole(string memory tag) internal view {
        assertLe(staking.totalRewardsPaid(), staking.totalRewardDistributed(), string.concat(tag, ": paid above distributed"));
        assertGe(
            token.balanceOf(address(staking)),
            staking.totalStaked() + staking.rewardReserve() + staking.protocolReserve(),
            string.concat(tag, ": balance below principal plus reserves")
        );
    }

    // ── the shrunk sequence (invariant_ATK_INV_paidLeDistributedLeCurveLeCap, dust tbe 3.2e9) ──

    function _replay() internal {
        vm.prank(admin);
        staking.fundEmission(90_000_000e18);
        h = new EmissionShareHandler(staking, token);
        h.stake(20405, 7904);
        h.warp(2512104316065048546728235137552254);
        h.claim(11);
        h.warp(3100);
        h.warp(90);
        h.stake(24075, 6067);
        h.stake(22179, 24404);
        h.warp(600);
        h.claim(8669);
        h.warp(11000);
        h.warp(69120000);
        h.unstake(917014145060871325680039935, 822030486856125219702111194921492861426133);
        h.warp(5666);
        h.stake(2043, 3153600000);
        h.unstake(2917, 12500);
    }

    /// With floored debts the 15th call paid 1 wei above distributed (522543379 > 522543378).
    function test_I7_rewardDebt_shrunkSequencePaysNoMoreThanDistributed() public {
        _replay();
        _assertWhole("I7");
    }

    function _toTheEnd() internal {
        vm.warp(staking.emissionEnd() + 400 days);
        vm.roll(block.number + 1000);
    }

    function _claimAll() internal {
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(h.actors(i));
            staking.claimRewards();
        }
    }

    /// Every remaining principal leaves whole: the wallet receives exactly its stake.
    function _withdrawAllExact() internal {
        for (uint256 i = 0; i < 4; i++) {
            address a = h.actors(i);
            (uint256 st,,,,,,,,,,,,,) = staking.getUserInfo(a);
            if (st == 0) continue;
            uint256 b0 = token.balanceOf(a);
            vm.prank(a);
            staking.withdraw(st);
            assertEq(token.balanceOf(a) - b0, st, "I7: a principal left short");
        }
    }

    function _sweep() internal {
        vm.prank(admin);
        staking.sweepUndistributedEmission();
    }

    /// Floored: the last withdraw reverted TransferFailed, its principal 2 wei short of the balance.
    function test_I7_lastExit_claimSweepWithdraw_everyPrincipalLeavesWhole() public {
        _replay();
        _toTheEnd();
        _claimAll();
        _sweep();
        _withdrawAllExact();
        _assertWhole("I7 claim-sweep-withdraw");
    }

    /// Floored: the sweep after the exits reverted TransferFailed (reserve 2 wei above the balance).
    function test_I7_lastExit_withdrawThenSweep_theSweepSucceeds() public {
        _replay();
        _toTheEnd();
        _claimAll();
        _withdrawAllExact();
        _sweep();
        _assertWhole("I7 withdraw-sweep");
    }

    /// Floored: the exits passed, but the reserve that came back after the sweep sat 2 wei above
    /// the balance.
    function test_I7_lastExit_sweepThenExit_theReserveStaysBacked() public {
        _replay();
        _toTheEnd();
        _sweep();
        _claimAll();
        _withdrawAllExact();
        _assertWhole("I7 sweep-exit");
    }

    // ── an optimising attacker: dust sybils resync every window on the best fraction ──────────

    function _tick(uint256 dt, uint256 db) internal {
        clk += dt;
        bn += db;
        vm.warp(clk);
        vm.roll(bn);
    }

    function _sybils(uint256 n, uint256 seed) internal {
        clk = block.timestamp;
        bn = block.number;
        for (uint256 i = 0; i < n; i++) {
            address a = address(uint160(0x5000 + i));
            token.mint(a, 1e30);
            vm.prank(a);
            token.approve(address(staking), type(uint256).max);
            vm.prank(a);
            staking.deposit(seed + i * 7, 90);
            syb.push(a);
        }
    }

    /// One window per step; each sybil resyncs once, with the deposit in [1, grind] whose fresh
    /// debt drops the largest fraction (picked off-chain style, on a snapshot). Then all settle.
    function _grind(uint256 windows, uint256 grind, uint256 dt, bool pureChannel) internal {
        for (uint256 k = 0; k < windows; k++) {
            _tick(dt, 11);
            for (uint256 i = 0; i < syb.length; i++) {
                uint256 best = 1;
                uint256 bestF;
                for (uint256 d = 1; d <= grind; d++) {
                    uint256 snap = vm.snapshotState();
                    vm.prank(syb[i]);
                    staking.deposit(d, 90);
                    uint256 f = pureChannel
                        ? mulmod(_word(syb[i], OFF_BP), staking.accPureYieldPerShare(), WAD)
                        : mulmod(_word(syb[i], OFF_BE), staking.accRewardPerShare(), WAD);
                    vm.revertToStateAndDelete(snap);
                    if (f > bestF) {
                        bestF = f;
                        best = d;
                    }
                }
                vm.prank(syb[i]);
                staking.deposit(best, 90);
            }
        }
        _tick(0, 11);
        for (uint256 i = 0; i < syb.length; i++) {
            vm.prank(syb[i]);
            staking.claimRewards();
        }
    }

    /// Emission channel, 2 sybils × 100 windows of 12 s: floored, paid ended 49 wei above distributed.
    function test_I7_rewardDebt_grindingSybilsCannotPayAboveDistributed() public {
        vm.prank(admin);
        staking.fundEmission(90_000_000e18);
        _sybils(2, 1000);
        _grind(100, 8, 12, false);
        _assertWhole("I7 emission grind");
    }

    /// Pure-yield channel: no emission is funded, so every count is pure yield; a borrower's
    /// interest feeds dust pure weights. A loan leaves the balance, so only the counters are read.
    function test_I7_pureYieldDebt_grindingSybilsCannotPayAboveDistributed() public {
        vm.prank(bob);
        staking.deposit(10_000_000e18, 90);
        vm.prank(bob);
        staking.borrow(4_000_000e18);
        _sybils(2, 1000);
        _grind(100, 8, 1 days, true);
        assertGt(staking.totalRewardsPaid(), 0, "the pure channel paid nothing, so nothing was measured");
        assertLe(staking.totalRewardsPaid(), staking.totalRewardDistributed(), "I7 pure grind: paid above distributed");
    }

    // ── the rounding itself: the ceiling, and nothing above it ───────────────────────────────

    /// Oracle in plain checked arithmetic (not the contract's mulDiv): ceil(w·acc / WAD).
    function _assertCeil(address a, uint256 offW, uint256 offD, uint256 acc, string memory tag) internal view {
        uint256 p = _word(a, offW) * acc;
        assertEq(_word(a, offD), p / WAD + (p % WAD == 0 ? 0 : 1), tag);
    }

    /// Both checkpointed debts are the ceiling of weight·acc/WAD, for any weight and accumulator.
    function testFuzz_I7_checkpointRoundsBothDebtsUp(uint256 first, uint256 amt, uint256 dt) public {
        // Bounded so both accumulators move (with acc == 0 floor and ceiling coincide): a weight
        // of at least one token and a day of a 4M loan's interest; the top-up may be dust.
        first = bound(first, 1e18, 1_000_000e18);
        amt = bound(amt, 1, 1_000_000e18);
        dt = bound(dt, 1 days, 3000 days);
        vm.prank(admin);
        staking.fundEmission(90_000_000e18);
        vm.prank(bob);
        staking.deposit(10_000_000e18, 90);
        vm.prank(bob);
        staking.borrow(4_000_000e18);
        vm.prank(alice);
        staking.deposit(first, 90);
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 11);
        vm.prank(alice);
        staking.deposit(amt, 90);
        assertGt(staking.accRewardPerShare(), 0, "no emission accrued");
        assertGt(staking.accPureYieldPerShare(), 0, "no pure yield accrued");
        _assertCeil(alice, OFF_BE, OFF_REWARD_DEBT, staking.accRewardPerShare(), "I7: rewardDebt is not the ceiling");
        _assertCeil(alice, OFF_BP, OFF_PURE_DEBT, staking.accPureYieldPerShare(), "I7: pureYieldDebt is not the ceiling");
    }

    /// No fixed bump: when weight·acc is an exact multiple of WAD (here acc == 0, the first
    /// depositor) the debt is the exact product, 0, not 1.
    function test_I7_anExactProductAddsNothing() public {
        vm.prank(admin);
        staking.fundEmission(90_000_000e18);
        vm.prank(alice);
        staking.deposit(1_000e18, 90);
        assertEq(staking.accRewardPerShare(), 0, "the accumulator already moved");
        assertEq(_word(alice, OFF_REWARD_DEBT), 0, "I7: rewardDebt rounded an exact product up");
        assertEq(_word(alice, OFF_PURE_DEBT), 0, "I7: pureYieldDebt rounded an exact product up");
        assertGt(_word(alice, OFF_BE), 0, "no weight, so nothing was measured");
    }
}
