// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Axis Y (pause regime). Every mutating external entry point, called under PAUSED (not
///         emergency) and under EMERGENCY (which always implies paused: declareEmergency/tripBreaker
///         pause at src 522/532 and unpause is whenNotEmergency at src 502), asserting exactly the
///         outcome its modifiers dictate. "body" means the modifiers let the call through and the
///         revert (if any) comes from the function body, which proves the regime does not block it.
///
///   function (src line)               modifiers                                    paused             emergency
///   fundEmission (446)                nonReentrant onlyRole(ADMIN) conserves       ok                 ok
///   withdrawReserve (462)             ... onlyRole(ADMIN) whenNotEmergency          ok                 EmergencyActive
///   sweepUndistributedEmission (489)  ... onlyRole(ADMIN) whenNotEmergency          ok (body)          EmergencyActive
///   pause (501)                       onlyRole(GUARDIAN)                            EnforcedPause      EnforcedPause
///   unpause (502)                     onlyRole(ADMIN) whenNotEmergency              ok                 EmergencyActive
///   tripBreaker (517)                 none (body: EmergencyActive, NoBreach)        ok/NoBreach (body) EmergencyActive (body)
///   declareEmergency (528)            onlyRole(GUARDIAN) (body: EmergencyActive)    ok                 EmergencyActive (body)
///   cancelEmergency (538)             onlyRole(ADMIN) (body: EmergencyNotActive)    EmergencyNotActive ok
///   emergencyWithdraw (555)           nonReentrant (body: EmergencyNotActive)       EmergencyNotActive ok
///   deposit (637)                     nonReentrant whenNotPaused whenNotEmergency   EnforcedPause      EnforcedPause
///   borrow (707)                      nonReentrant whenNotPaused whenNotEmergency   EnforcedPause      EnforcedPause
///   repay (741)                       nonReentrant whenNotEmergency conserves       ok                 EmergencyActive
///   withdraw (770)                    nonReentrant whenNotEmergency conserves       ok                 EmergencyActive
///   claimRewards (808)                nonReentrant whenNotEmergency conserves       ok                 EmergencyActive
///   claimPureYield (818)              nonReentrant whenNotEmergency conserves       ok                 EmergencyActive
///   lock (836)                        nonReentrant whenNotPaused whenNotEmergency   EnforcedPause      EnforcedPause
///   pokeExpiredLock (880)             nonReentrant whenNotEmergency conserves       ok                 EmergencyActive
///   pokeExpiredLocks (897)            nonReentrant whenNotEmergency conserves       ok                 EmergencyActive
///   liquidate (928)                   nonReentrant whenNotPaused whenNotEmergency   EnforcedPause      EnforcedPause
///   maintStep (1119)                  self-only (body: NotSelf)                     NotSelf            NotSelf
///   lockStep (1148)                   self-only (body: NotSelf)                     NotSelf            NotSelf
///   touchAuditSnapshot (1714)         none                                          ok                 ok
///   grantRole / revokeRole /          AccessControl (OZ 5.1), no pause guard        ok                 ok
///   renounceRole (inherited)
///
///   In emergency, whenNotPaused fires before whenNotEmergency, so the four entry points that carry
///   both report EnforcedPause, not EmergencyActive. Restoration: unpause after pause, and
///   cancelEmergency + unpause after emergency, reopen every entry point (last two tests).
contract PauseRegimeTest is Base {
    bytes32 constant GUARDIAN = keccak256("GUARDIAN_ROLE");
    address guardian = address(0x6A2D);
    address dave = address(0xDA7E);
    uint256 internal T;
    uint256 internal B;

    function setUp() public override {
        super.setUp();
        T = block.timestamp;
        B = block.number;
        vm.prank(admin);
        staking.grantRole(GUARDIAN, guardian);
        vm.prank(admin);
        staking.fundEmission(1_000_000e18);
        _stake(alice, 10_000e18);
        _stake(bob, 10_000e18);
        _stake(carol, 10_000e18);
        B += 11; vm.roll(B);
        vm.prank(alice);
        staking.borrow(1_000e18);
        T += 91 days; vm.warp(T);                  // every lock expired, none normalised yet
    }

    function _stake(address u, uint256 a) internal {
        vm.prank(u);
        staking.deposit(a, 90);
    }

    function _pause() internal {
        vm.prank(guardian);
        staking.pause();
        assertTrue(staking.paused() && !staking.emergencyMode(), "regime: paused only");
    }

    function _emergency() internal {
        vm.prank(guardian);
        staking.declareEmergency();
        assertTrue(staking.paused() && staking.emergencyMode(), "regime: emergency");
    }

    function _one(address u) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = u;
    }

    bytes4 internal immutable PAUSED = Pausable.EnforcedPause.selector;
    bytes4 internal immutable EMG = BlazePhoenixStaking.Staking__EmergencyActive.selector;

    // ── fundEmission ────────────────────────────────────────────────────────────────────────
    function test_Y_fundEmission_paused() public { _pause(); vm.prank(admin); staking.fundEmission(1e18); }
    function test_Y_fundEmission_emergency() public { _emergency(); vm.prank(admin); staking.fundEmission(1e18); }

    // ── withdrawReserve ─────────────────────────────────────────────────────────────────────
    function test_Y_withdrawReserve_paused() public { _pause(); vm.prank(admin); staking.withdrawReserve(1); }
    function test_Y_withdrawReserve_emergency() public {
        _emergency(); vm.prank(admin); vm.expectRevert(EMG); staking.withdrawReserve(1);
    }

    // ── sweepUndistributedEmission ──────────────────────────────────────────────────────────
    function test_Y_sweepUndistributedEmission_paused_reaches_body() public {
        _pause();
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmissionNotEnded.selector);
        staking.sweepUndistributedEmission();
        T = staking.emissionEnd(); vm.warp(T);
        vm.prank(admin);
        staking.fundEmission(1e18);                // the programme drained the reserve; leave a residue
        vm.prank(admin);
        staking.sweepUndistributedEmission();
        assertEq(staking.rewardReserve(), 0);
    }
    function test_Y_sweepUndistributedEmission_emergency() public {
        _emergency();
        T = staking.emissionEnd(); vm.warp(T);
        vm.prank(admin); vm.expectRevert(EMG); staking.sweepUndistributedEmission();
    }

    // ── pause / unpause ─────────────────────────────────────────────────────────────────────
    function test_Y_pause_paused() public { _pause(); vm.prank(guardian); vm.expectRevert(PAUSED); staking.pause(); }
    function test_Y_pause_emergency() public { _emergency(); vm.prank(guardian); vm.expectRevert(PAUSED); staking.pause(); }
    function test_Y_unpause_paused() public { _pause(); vm.prank(admin); staking.unpause(); assertFalse(staking.paused()); }
    function test_Y_unpause_emergency() public { _emergency(); vm.prank(admin); vm.expectRevert(EMG); staking.unpause(); }

    // ── tripBreaker ─────────────────────────────────────────────────────────────────────────
    function test_Y_tripBreaker_paused() public {
        _pause();
        vm.prank(carol);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoBreach.selector);
        staking.tripBreaker();
        deal(address(token), address(staking), token.balanceOf(address(staking)) - 1_000e18);
        vm.prank(carol);
        staking.tripBreaker();                     // a breach can still be declared while paused
        assertTrue(staking.emergencyMode() && staking.paused());
    }
    function test_Y_tripBreaker_emergency() public { _emergency(); vm.prank(carol); vm.expectRevert(EMG); staking.tripBreaker(); }

    // ── declareEmergency / cancelEmergency ──────────────────────────────────────────────────
    function test_Y_declareEmergency_paused() public {
        _pause(); vm.prank(guardian); staking.declareEmergency(); assertTrue(staking.emergencyMode());
    }
    function test_Y_declareEmergency_emergency() public {
        _emergency(); vm.prank(guardian); vm.expectRevert(EMG); staking.declareEmergency();
    }
    function test_Y_cancelEmergency_paused() public {
        _pause();
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmergencyNotActive.selector);
        staking.cancelEmergency();
    }
    function test_Y_cancelEmergency_emergency() public {
        _emergency(); vm.prank(admin); staking.cancelEmergency();
        assertFalse(staking.emergencyMode()); assertTrue(staking.paused(), "cancel leaves the pause");
    }

    // ── emergencyWithdraw ───────────────────────────────────────────────────────────────────
    function test_Y_emergencyWithdraw_paused() public {
        _pause();
        vm.prank(bob);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmergencyNotActive.selector);
        staking.emergencyWithdraw();
    }
    function test_Y_emergencyWithdraw_emergency() public { _emergency(); vm.prank(bob); staking.emergencyWithdraw(); }

    // ── deposit / borrow / lock / liquidate: closed in both regimes ─────────────────────────
    function test_Y_deposit_paused() public { _pause(); vm.prank(dave); vm.expectRevert(PAUSED); staking.deposit(1e18, 90); }
    function test_Y_deposit_emergency() public { _emergency(); vm.prank(dave); vm.expectRevert(PAUSED); staking.deposit(1e18, 90); }
    function test_Y_borrow_paused() public { _pause(); vm.prank(alice); vm.expectRevert(PAUSED); staking.borrow(1e18); }
    function test_Y_borrow_emergency() public { _emergency(); vm.prank(alice); vm.expectRevert(PAUSED); staking.borrow(1e18); }
    function test_Y_lock_paused() public { _pause(); vm.prank(carol); vm.expectRevert(PAUSED); staking.lock(180); }
    function test_Y_lock_emergency() public { _emergency(); vm.prank(carol); vm.expectRevert(PAUSED); staking.lock(180); }
    function test_Y_liquidate_paused() public { _pause(); vm.prank(keeper); vm.expectRevert(PAUSED); staking.liquidate(alice); }
    function test_Y_liquidate_emergency() public { _emergency(); vm.prank(keeper); vm.expectRevert(PAUSED); staking.liquidate(alice); }

    // ── exits and maintenance: open under pause, closed under emergency ─────────────────────
    function test_Y_repay_paused() public { _pause(); vm.prank(alice); staking.repay(100e18); }
    function test_Y_repay_emergency() public { _emergency(); vm.prank(alice); vm.expectRevert(EMG); staking.repay(100e18); }
    function test_Y_withdraw_paused() public { _pause(); vm.prank(bob); staking.withdraw(1e18); }
    function test_Y_withdraw_emergency() public { _emergency(); vm.prank(bob); vm.expectRevert(EMG); staking.withdraw(1e18); }
    function test_Y_claimRewards_paused() public { _pause(); vm.prank(carol); staking.claimRewards(); }
    function test_Y_claimRewards_emergency() public { _emergency(); vm.prank(carol); vm.expectRevert(EMG); staking.claimRewards(); }
    function test_Y_claimPureYield_paused() public { _pause(); vm.prank(bob); staking.claimPureYield(); }
    function test_Y_claimPureYield_emergency() public { _emergency(); vm.prank(bob); vm.expectRevert(EMG); staking.claimPureYield(); }
    function test_Y_pokeExpiredLock_paused() public { _pause(); vm.prank(keeper); staking.pokeExpiredLock(carol); }
    function test_Y_pokeExpiredLock_emergency() public {
        _emergency(); vm.prank(keeper); vm.expectRevert(EMG); staking.pokeExpiredLock(carol);
    }
    function test_Y_pokeExpiredLocks_paused() public { _pause(); vm.prank(keeper); staking.pokeExpiredLocks(_one(carol)); }
    function test_Y_pokeExpiredLocks_emergency() public {
        _emergency(); address[] memory a = _one(carol);
        vm.prank(keeper); vm.expectRevert(EMG); staking.pokeExpiredLocks(a);
    }

    // ── self-only steps ─────────────────────────────────────────────────────────────────────
    function test_Y_maintStep_paused() public {
        _pause(); vm.expectRevert(BlazePhoenixStaking.Staking__NotSelf.selector); staking.maintStep(alice, keeper);
    }
    function test_Y_maintStep_emergency() public {
        _emergency(); vm.expectRevert(BlazePhoenixStaking.Staking__NotSelf.selector); staking.maintStep(alice, keeper);
    }
    function test_Y_lockStep_paused() public {
        _pause(); vm.expectRevert(BlazePhoenixStaking.Staking__NotSelf.selector); staking.lockStep(carol, keeper);
    }
    function test_Y_lockStep_emergency() public {
        _emergency(); vm.expectRevert(BlazePhoenixStaking.Staking__NotSelf.selector); staking.lockStep(carol, keeper);
    }

    // ── unguarded ───────────────────────────────────────────────────────────────────────────
    function test_Y_touchAuditSnapshot_paused() public { _pause(); staking.touchAuditSnapshot(); }
    function test_Y_touchAuditSnapshot_emergency() public { _emergency(); staking.touchAuditSnapshot(); }

    function _roles() internal {
        vm.prank(admin); staking.grantRole(GUARDIAN, dave);
        vm.prank(admin); staking.revokeRole(GUARDIAN, dave);
        vm.prank(guardian); staking.renounceRole(GUARDIAN, guardian);
        assertFalse(staking.hasRole(GUARDIAN, dave) || staking.hasRole(GUARDIAN, guardian));
    }
    function test_Y_roles_paused() public { _pause(); _roles(); }
    function test_Y_roles_emergency() public { _emergency(); _roles(); }

    // ── restoration ─────────────────────────────────────────────────────────────────────────
    function _allOpen() internal {
        vm.prank(keeper); staking.pokeExpiredLock(carol);
        vm.prank(bob); staking.claimPureYield();
        vm.prank(bob); staking.withdraw(1e18);
        vm.prank(carol); staking.claimRewards();
        vm.prank(alice); staking.repay(100e18);
        vm.prank(keeper); staking.deposit(1_000e18, 90);
        vm.prank(alice); staking.borrow(100e18);
        vm.prank(carol); staking.lock(180);
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NotLiquidatable.selector);
        staking.liquidate(alice);                  // modifiers pass; healthy position
        vm.prank(admin); staking.withdrawReserve(1);
    }

    function test_Y_unpause_after_pause_restores_every_entry_point() public {
        _pause();
        vm.prank(admin); staking.unpause();
        _allOpen();
    }

    function test_Y_cancel_then_unpause_after_emergency_restores_every_entry_point() public {
        _emergency();
        vm.prank(admin); staking.cancelEmergency();
        // still paused after cancel: entries are closed, exits open
        vm.prank(keeper); vm.expectRevert(PAUSED); staking.deposit(1e18, 90);
        vm.prank(alice); staking.repay(10e18);
        vm.prank(admin); staking.unpause();
        _allOpen();
    }
}
