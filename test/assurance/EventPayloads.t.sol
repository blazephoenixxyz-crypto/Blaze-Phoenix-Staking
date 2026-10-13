// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice Axis E (event payloads). Every event of BlazePhoenixStaking, at every emit site, driven
///         through the real entry point and checked with
///         `vm.expectEmit(true, true, true, true, address(staking))` against a value derived
///         independently from state read BEFORE the call (never copied from the emitted log).
///
///         Event                       emit site(s) in src/BlazePhoenixStaking.sol
///         EmissionFunded              457
///         ReserveWithdrawn            469
///         UndistributedEmissionSwept  498
///         EmergencyDeclared           523 (tripBreaker), 533 (declareEmergency)
///         EmergencyCancelled          547
///         EmergencyWithdrawn          624
///         LockSet                     675 (deposit, new lock), 698 (deposit, inherited lock), 869 (lock)
///         Deposited                   703
///         Borrowed                    736
///         Repaid                      762
///         Withdrawn                   804
///         Liquidated                  991 (via liquidate and via maintStep)
///         MaintenanceSwept            1126
///         LockSwept                   1164 (via pokeExpiredLock, pokeExpiredLocks, autonomous sweep)
///         RewardClaimed               1345
///         PureYieldClaimed            1357
///         InterestAccrued             1507
///         LockExpired                 1592
///
///         Oracles are written from the formulas, not from the contract's own helpers: `_boost` is
///         the curve stated at src line 162, `_rate` the kinked curve of lines 175-180, `_slice`
///         the per-slice interest of `_interestSlice` (healthy branch only; the oracle refuses the
///         clamp branch rather than model it). Time and block number are tracked in storage
///         because via-IR may rematerialise `block.timestamp` after `vm.warp`.
contract EventPayloadsTest is Base {
    uint256 constant T0 = 1_900_000_000;
    uint256 constant S = 10_000_000e18;
    bytes32 constant GUARDIAN = keccak256("GUARDIAN_ROLE");
    address guardian = address(0x6A2D);

    uint256 internal T;
    uint256 internal B;

    function setUp() public override {
        super.setUp();
        T = T0;
        B = block.number;
        vm.prank(admin);
        staking.grantRole(GUARDIAN, guardian);
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────────
    function _warp(uint256 dt) internal { T += dt; vm.warp(T); }
    function _roll(uint256 n) internal { B += n; vm.roll(B); }

    function _stake(address u, uint256 a, uint256 d) internal {
        vm.prank(u);
        staking.deposit(a, d);
    }

    function _st(address u) internal view returns (uint256 s, uint256 d) {
        (s, d,,,,,,,,,,,,) = staking.getUserInfo(u);
    }

    function _expect() internal {
        vm.expectEmit(true, true, true, true, address(staking));
    }

    function _steal(uint256 x) internal {
        deal(address(token), address(staking), token.balanceOf(address(staking)) - x);
    }

    /// boost(d) = 10000 + 750·d/365 + 250·d²/365²  [bps], each term floored (src line 162).
    function _boost(uint256 d) internal pure returns (uint256) {
        if (d == 0) return 10_000;
        return 10_000 + (750 * d) / 365 + (250 * d * d) / (365 * 365);
    }

    /// Kinked annual rate [bps] at utilisation td/ts (src lines 175-180, 1597-1611).
    function _rate(uint256 td, uint256 ts) internal pure returns (uint256) {
        if (ts == 0 && td == 0) return 100;
        uint256 u = ts == 0 ? 1e18 : (td * 1e18) / ts;
        if (u > 1e18) u = 1e18;
        return u <= 0.8e18 ? 100 + (u * 500) / 1e18 : 500 + ((u - 0.8e18) * 72_500) / 1e18;
    }

    /// Per-debt index advance [WAD] and global slice [token-wei] over `elapsed` seconds.
    function _slice(uint256 td, uint256 ts, uint256 elapsed) internal pure returns (uint256 delta, uint256 slice) {
        delta = ((1e18 * _rate(td, ts)) / 10_000) * elapsed / 365 days;
        slice = (td * delta) / 1e18;
        require(slice <= ts, "oracle: clamp branch not modelled");
    }

    // ── EmissionFunded (457) ────────────────────────────────────────────────────────────────
    function test_E_EmissionFunded_payload() public {
        uint256 a = 1_234_567e18;
        _expect();
        emit BlazePhoenixStaking.EmissionFunded(admin, a);
        vm.prank(admin);
        staking.fundEmission(a);
    }

    // ── ReserveWithdrawn (469): amount is the clamped value actually sent ─────────────────
    function test_E_ReserveWithdrawn_payload_is_clamped_amount() public {
        _stake(alice, 10_000e18, 90);
        _roll(11);
        vm.prank(alice);
        staking.borrow(4_000e18);
        _warp(365 days);
        vm.prank(alice);
        staking.repay(1e18);                       // runs the index: interest lands in protocolReserve
        uint256 pr = staking.protocolReserve();
        assertGt(pr, 0, "setup: reserve must be non-zero");
        _expect();
        emit BlazePhoenixStaking.ReserveWithdrawn(treasury, pr);
        vm.prank(admin);
        staking.withdrawReserve(pr + 1e18);
    }

    // ── UndistributedEmissionSwept (498) ────────────────────────────────────────────────────
    function test_E_UndistributedEmissionSwept_empty_pool() public {
        uint256 a = 5_000_000e18;
        vm.prank(admin);
        staking.fundEmission(a);
        T = staking.emissionEnd();
        vm.warp(T);
        _expect();
        emit BlazePhoenixStaking.UndistributedEmissionSwept(treasury, a);
        vm.prank(admin);
        staking.sweepUndistributedEmission();
    }

    function test_E_UndistributedEmissionSwept_halving_tail() public {
        vm.prank(admin);
        staking.fundEmission(180_000_000e18);
        _stake(alice, 10_000e18, 90);              // sole weight from emissionStart to emissionEnd
        T = staking.emissionEnd();
        vm.warp(T);
        // Σ emitted over the whole programme = TOTAL − TOTAL>>8, so the residue is TOTAL>>8.
        _expect();
        emit BlazePhoenixStaking.UndistributedEmissionSwept(treasury, uint256(180_000_000e18) >> 8);
        vm.prank(admin);
        staking.sweepUndistributedEmission();
    }

    // ── EmergencyDeclared (523, 533) and EmergencyCancelled (547) ───────────────────────────
    function test_E_EmergencyDeclared_tripBreaker_permissionless() public {
        _stake(alice, 10_000e18, 90);
        _steal(1_000e18);
        _expect();
        emit BlazePhoenixStaking.EmergencyDeclared(carol, T, true);
        vm.prank(carol);
        staking.tripBreaker();
    }

    function test_E_EmergencyDeclared_guardian() public {
        _expect();
        emit BlazePhoenixStaking.EmergencyDeclared(guardian, T, false);
        vm.prank(guardian);
        staking.declareEmergency();
    }

    function test_E_EmergencyCancelled_payload() public {
        vm.prank(guardian);
        staking.declareEmergency();
        _warp(1 hours);
        _expect();
        emit BlazePhoenixStaking.EmergencyCancelled(admin, T);
        vm.prank(admin);
        staking.cancelEmergency();
    }

    // ── EmergencyWithdrawn (624): three regimes of the payout ───────────────────────────────
    function test_E_EmergencyWithdrawn_solvent_no_debt() public {
        _stake(alice, 10_000e18, 90);
        vm.prank(guardian);
        staking.declareEmergency();
        _expect();
        emit BlazePhoenixStaking.EmergencyWithdrawn(alice, 10_000e18);
        vm.prank(alice);
        staking.emergencyWithdraw();
    }

    function test_E_EmergencyWithdrawn_solvent_net_of_debt_and_interest() public {
        _stake(alice, 10_000e18, 90);
        _roll(11);
        vm.prank(alice);
        staking.borrow(2_000e18);
        _warp(30 days);
        (uint256 s, uint256 d) = _st(alice);
        (, uint256 slice) = _slice(staking.totalDebt(), staking.totalStaked(), T - staking.lastInterestTime());
        assertGt(slice, 0, "setup: interest must be due");
        vm.prank(guardian);
        staking.declareEmergency();                // charges the slice up to the halt
        // Sole borrower: its charge equals the global slice; payout = stake − interest − debt.
        _expect();
        emit BlazePhoenixStaking.EmergencyWithdrawn(alice, s - slice - d);
        vm.prank(alice);
        staking.emergencyWithdraw();
    }

    function test_E_EmergencyWithdrawn_breached_haircut() public {
        _stake(alice, 10_000e18, 90);
        _stake(bob, 10_000e18, 90);
        _steal(1_000e18);
        vm.prank(carol);
        staking.tripBreaker();
        uint256 pot = token.balanceOf(address(staking));
        uint256 tpe = staking.totalPositiveEquity();
        assertLt(pot, tpe, "setup: haircut must engage");
        // eCorr = tpe − tracked + payout = tpe (alice untouched since her deposit, no debt).
        _expect();
        emit BlazePhoenixStaking.EmergencyWithdrawn(alice, (uint256(10_000e18) * pot) / tpe);
        vm.prank(alice);
        staking.emergencyWithdraw();
    }

    // ── LockSet (675) + Deposited (703) ─────────────────────────────────────────────────────
    function test_E_LockSet_and_Deposited_new_lock() public {
        _expect();
        emit BlazePhoenixStaking.LockSet(alice, 365, T + 365 days, _boost(365));
        _expect();
        emit BlazePhoenixStaking.Deposited(alice, 100e18, 100e18);
        _stake(alice, 100e18, 365);
    }

    // ── LockSet (698) + Deposited (703): top-up inherits the longer lock ──────────────────
    function test_E_LockSet_and_Deposited_topup_inherits_lock() public {
        _stake(alice, 100e18, 365);
        uint256 unlock = T + 365 days;
        _warp(10 days + 5 hours);
        uint256 rem = (unlock - T) / 1 days;      // 354
        _expect();
        emit BlazePhoenixStaking.LockSet(alice, rem, unlock, _boost(rem));
        _expect();
        emit BlazePhoenixStaking.Deposited(alice, 50e18, 150e18);
        _stake(alice, 50e18, 90);
    }

    // ── LockSet (869) ───────────────────────────────────────────────────────────────────────
    function test_E_LockSet_lock_extension() public {
        _stake(alice, 100e18, 90);
        _roll(11);
        _warp(1 days);
        _expect();
        emit BlazePhoenixStaking.LockSet(alice, 400, T + 400 days, _boost(400));
        vm.prank(alice);
        staking.lock(400);
    }

    // ── Borrowed (736): rate is the one in force after the borrow ─────────────────────────
    function test_E_Borrowed_first_borrow() public {
        _stake(alice, 10_000e18, 90);
        _roll(11);
        uint256 ts = staking.totalStaked();
        uint256 td = staking.totalDebt();
        _expect();
        emit BlazePhoenixStaking.Borrowed(alice, 3_000e18, 3_000e18, _rate(td + 3_000e18, ts));
        vm.prank(alice);
        staking.borrow(3_000e18);
    }

    function test_E_Borrowed_second_borrow_after_interest() public {
        _stake(alice, 10_000e18, 90);
        _roll(11);
        vm.prank(alice);
        staking.borrow(2_000e18);
        _warp(30 days);
        uint256 ts = staking.totalStaked();
        uint256 td = staking.totalDebt();
        (, uint256 slice) = _slice(td, ts, T - staking.lastInterestTime());
        assertGt(slice, 0, "setup: interest must be due");
        // Interest debits stake, never debt: u.debt = 2000 + 1000; totalStaked drops by the slice.
        _expect();
        emit BlazePhoenixStaking.Borrowed(alice, 1_000e18, 3_000e18, _rate(td + 1_000e18, ts - slice));
        vm.prank(alice);
        staking.borrow(1_000e18);
    }

    // ── Repaid (762) ────────────────────────────────────────────────────────────────────────
    function test_E_Repaid_partial() public {
        _stake(alice, 10_000e18, 90);
        _roll(11);
        vm.prank(alice);
        staking.borrow(3_000e18);
        _warp(30 days);
        (, uint256 d) = _st(alice);
        _expect();
        emit BlazePhoenixStaking.Repaid(alice, 1_000e18, d - 1_000e18);
        vm.prank(alice);
        staking.repay(1_000e18);
    }

    function test_E_Repaid_full_clamps_to_debt() public {
        _stake(alice, 10_000e18, 90);
        _roll(11);
        vm.prank(alice);
        staking.borrow(3_000e18);
        _warp(30 days);
        (, uint256 d) = _st(alice);
        _expect();
        emit BlazePhoenixStaking.Repaid(alice, d, 0);
        vm.prank(alice);
        staking.repay(1e30);
    }

    // ── LockExpired (1592) + Withdrawn (804) ────────────────────────────────────────────────
    function test_E_LockExpired_and_Withdrawn() public {
        _stake(alice, 100e18, 90);
        _warp(91 days);
        _roll(11);
        _expect();
        emit BlazePhoenixStaking.LockExpired(alice);
        _expect();
        emit BlazePhoenixStaking.Withdrawn(alice, 40e18, 0, 0, 40e18);
        vm.prank(alice);
        staking.withdraw(40e18);
    }

    // ── InterestAccrued (1507) ──────────────────────────────────────────────────────────────
    function test_E_InterestAccrued_payload() public {
        _stake(bob, 10_000e18, 90);
        _roll(11);
        vm.prank(bob);
        staking.borrow(5_000e18);
        _warp(30 days);
        (uint256 s, uint256 d) = _st(bob);
        (uint256 delta,) = _slice(staking.totalDebt(), staking.totalStaked(), T - staking.lastInterestTime());
        uint256 interest = (d * delta) / 1e18;    // checkpoint == index at borrow; idxDelta == delta
        assertGt(interest, 0, "setup: interest must be due");
        _expect();
        emit BlazePhoenixStaking.InterestAccrued(bob, interest, s - interest);
        vm.prank(bob);
        staking.claimRewards();
    }

    // ── RewardClaimed (1345) ────────────────────────────────────────────────────────────────
    function test_E_RewardClaimed_payload() public {
        vm.prank(admin);
        staking.fundEmission(10_000_000e18);
        _stake(alice, 10_000e18, 365);
        _warp(1 days);
        uint256 tbe = staking.totalBoostedEffective();
        assertEq(tbe, (uint256(10_000e18) * _boost(365)) / 10_000, "sole weight");
        uint256 acc0 = staking.accRewardPerShare();
        uint256 lrt = staking.lastRewardTime();
        // Period 0 of the halving curve: R0 = 90M / (2·365 days) wei/s, linear in time.
        uint256 reward = (uint256(90_000_000e18) / (2 * 365 days)) * (T - lrt);
        uint256 rr = staking.rewardReserve();
        if (reward > rr) reward = rr;
        uint256 acc1 = acc0 + (reward * 1e18) / tbe;
        uint256 due = (tbe * acc1) / 1e18 - (tbe * acc0) / 1e18;
        assertGt(due, 0, "setup: reward must be due");
        _expect();
        emit BlazePhoenixStaking.RewardClaimed(alice, due);
        vm.prank(alice);
        staking.claimRewards();
    }

    // ── PureYieldClaimed (1357) ─────────────────────────────────────────────────────────────
    function test_E_PureYieldClaimed_payload() public {
        _stake(alice, 10_000e18, 90);
        _stake(bob, 10_000e18, 90);
        _roll(11);
        vm.prank(bob);
        staking.borrow(5_000e18);
        _warp(30 days);
        uint256 tbp = staking.totalBoostedPure();
        assertEq(tbp, (uint256(10_000e18) * _boost(90)) / 10_000, "alice is the only pure weight");
        uint256 a0 = staking.accPureYieldPerShare();
        (, uint256 slice) = _slice(staking.totalDebt(), staking.totalStaked(), T - staking.lastInterestTime());
        uint256 toPool = slice - (slice * 300) / 10_000;
        uint256 a1 = a0 + (toPool * 1e18) / tbp;  // tbp >= MIN_EMISSION_WEIGHT: no damping
        uint256 due = (tbp * a1) / 1e18 - (tbp * a0) / 1e18;
        assertGt(due, 0, "setup: yield must be due");
        _expect();
        emit BlazePhoenixStaking.PureYieldClaimed(alice, due);
        vm.prank(alice);
        staking.claimPureYield();
    }

    // ── Liquidated (991) and MaintenanceSwept (1126) ────────────────────────────────────────
    /// Lands the stake at ~1.025·debt (liquidatable with a positive surplus), then lets the owner
    /// settle its own accrual in a separate tx so the payload oracle reads the final stake.
    function _underwater(address u, uint256 extraYears) internal {
        _stake(u, S, 90);
        _roll(11);
        uint256 d = S / 2;
        vm.prank(u);
        staking.borrow(d);
        uint256 rate = staking.currentInterestRateBps();
        uint256 interest = S - (d * 1025) / 1000;
        _warp(interest * 10_000 * 365 days / (d * rate) + extraYears * 365 days);
        vm.prank(u);
        staking.claimRewards();
    }

    struct Liq { uint256 seized; uint256 debt; uint256 bonus; uint256 leftover; uint256 uncovered; }

    function _liqOracle(address u) internal view returns (Liq memory l) {
        (uint256 st, uint256 dt) = _st(u);
        uint256 pr = staking.protocolReserve();
        l.debt = dt;
        l.seized = dt + (dt * 500) / 10_000;
        if (l.seized > st) l.seized = st;
        l.leftover = st > l.seized ? st - l.seized : 0;
        l.bonus = l.seized > dt ? l.seized - dt : 0;
        uint256 bad = dt > st ? dt - st : 0;
        uint256 cov = bad > pr ? pr : bad;
        l.uncovered = bad - cov;
    }

    function test_E_Liquidated_by_keeper_surplus() public {
        _underwater(alice, 0);
        Liq memory l = _liqOracle(alice);
        assertGt(l.bonus, 0, "regime: positive surplus");
        _expect();
        emit BlazePhoenixStaking.Liquidated(alice, keeper, l.seized, l.debt, l.bonus, l.leftover, l.uncovered);
        vm.prank(keeper);
        staking.liquidate(alice);
    }

    function test_E_Liquidated_by_keeper_bad_debt() public {
        _underwater(alice, 100);
        Liq memory l = _liqOracle(alice);
        assertEq(l.bonus, 0, "regime: stake below debt");
        assertEq(l.leftover, 0, "regime: nothing left");
        _expect();
        emit BlazePhoenixStaking.Liquidated(alice, keeper, l.seized, l.debt, l.bonus, l.leftover, l.uncovered);
        vm.prank(keeper);
        staking.liquidate(alice);
    }

    /// Self-liquidation: the surplus stays in protocolReserve (`_executeLiquidation`) and the caller receives
    /// nothing, so the keeper bonus the event reports must be the 0 the keeper actually got.
    function test_E_Liquidated_self_reports_bonus_actually_paid() public {
        _underwater(alice, 0);
        Liq memory l = _liqOracle(alice);
        assertGt(l.bonus, 0, "regime: positive surplus");
        _expect();
        emit BlazePhoenixStaking.Liquidated(alice, alice, l.seized, l.debt, 0, l.leftover, l.uncovered);
        vm.prank(alice);
        staking.liquidate(alice);
    }

    function test_E_Liquidated_and_MaintenanceSwept_via_sweep() public {
        _stake(bob, 100e18, 90);                   // carrier position; deposit is closed after the warp
        _underwater(alice, 0);
        Liq memory l = _liqOracle(alice);
        assertGt(l.bonus, 0, "regime: positive surplus");
        _expect();
        emit BlazePhoenixStaking.Liquidated(alice, bob, l.seized, l.debt, l.bonus, l.leftover, l.uncovered);
        _expect();
        emit BlazePhoenixStaking.MaintenanceSwept(bob, alice, l.bonus);
        vm.prank(bob);
        staking.claimRewards();                    // carries the borrower window (budget 1 -> alice)
    }

    // ── LockSwept (1164) + LockExpired (1592) ───────────────────────────────────────────────
    function test_E_LockSwept_pokeExpiredLock() public {
        _stake(alice, 10_000e18, 90);
        _warp(91 days);
        uint256 tracked = (uint256(10_000e18) * _boost(90)) / 10_000;
        assertEq(staking.totalBoostedEffective(), tracked, "sole effective weight");
        assertEq(staking.totalBoostedPure(), tracked, "sole pure weight");
        _expect();
        emit BlazePhoenixStaking.LockExpired(alice);
        _expect();
        emit BlazePhoenixStaking.LockSwept(keeper, alice, tracked - 10_000e18, tracked - 10_000e18);
        vm.prank(keeper);
        staking.pokeExpiredLock(alice);
    }

    function test_E_LockSwept_pokeExpiredLocks_batch() public {
        _stake(bob, 10_000e18, 90);
        _stake(carol, 20_000e18, 120);
        _warp(121 days);
        uint256 tb = (uint256(10_000e18) * _boost(90)) / 10_000;
        uint256 tc = (uint256(20_000e18) * _boost(120)) / 10_000;
        _expect();
        emit BlazePhoenixStaking.LockSwept(keeper, bob, tb - 10_000e18, tb - 10_000e18);
        _expect();
        emit BlazePhoenixStaking.LockSwept(keeper, carol, tc - 20_000e18, tc - 20_000e18);
        address[] memory us = new address[](2);
        us[0] = bob;
        us[1] = carol;
        vm.prank(keeper);
        staking.pokeExpiredLocks(us);
    }

    function test_E_LockSwept_autonomous_sweep() public {
        _stake(alice, 10_000e18, 90);
        _warp(91 days);
        uint256 tracked = (uint256(10_000e18) * _boost(90)) / 10_000;
        _expect();
        emit BlazePhoenixStaking.LockSwept(bob, alice, tracked - 10_000e18, tracked - 10_000e18);
        _stake(bob, 100e18, 90);                   // carries the locker window; cursor 0 -> alice
    }
}
