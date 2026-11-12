// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// fix1112, third part: the pure-yield channel. `_settlePendingPureYield` returned the lapsed-lock
// excess of a pure position (LOCK-STALE) to `protocolReserve` on every settle, but the emergency
// hatch only ran `_settleEmission`: the pure excess of the exiter's last window stayed inside
// `totalRewardDistributed` as if it were forfeited yield, while a settle in the same block would
// have returned it. Red at 301d1e5: `protocolReserve` did not move on the hatch. The window is
// now read by `_settlePure`, shared by the settle and the hatch ("two callers, one question"),
// clamped as `_settleEmission` so the last door never closes on broken pure arithmetic (I4), and
// mirrored on the 3326 anchor through the same `moved` as the emission excess.
//
// Matrix: range (one exit, every exit, fuzzed lock length and elapsed time) x vector (lapsed lock
// of a pure holder beside a borrower, corrupted tracked pure weight, corrupted distributed side)
// x dimension (unit, fuzz, fault injection by vm.store, snapshot preview of the settle).
// Mutants (.github/scripts/mutants.py): "_settlePure: the lapsed excess stays owed instead of
// returning to protocolReserve", "_settlePure: the live-weight share is a checked subtraction",
// "_settlePure: the excess leaves the distributed side unclamped", "emergencyWithdraw: the hatch
// keeps the pure stale excess with the forfeit". The residue decomposition
// (test/montecarlo/ResidueDecomposition.t.sol) reads the same move wei for wei.

import {Base} from "../BlazePhoenixStaking.t.sol";

contract HatchReturnsPureStaleExcessTest is Base {
    uint256 internal constant USERS_SLOT = 36;
    uint256 internal constant DIST_SLOT  = 17;   // totalRewardDistributed

    function setUp() public override {
        super.setUp();
        vm.prank(admin); staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
    }

    function _userSlot(address a, uint256 field) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(a, USERS_SLOT))) + field);
    }

    /// carol holds a pure position (no debt) under a `lockDays` lock; alice borrows, so interest
    /// feeds `accPureYieldPerShare`; emission is funded; `elapsed` passes; the GUARDIAN halts.
    function _pureBesideBorrower(uint16 lockDays, uint256 elapsed) internal {
        vm.prank(carol); staking.deposit(1_000_000e18, lockDays);
        vm.prank(alice); staking.deposit(1_000_000e18, 365);
        vm.prank(admin); staking.fundEmission(1_000_000e18);
        vm.roll(block.number + 20);
        vm.prank(alice); staking.borrow(400_000e18);
        vm.warp(block.timestamp + elapsed); vm.roll(block.number + 20);
        vm.prank(keeper); staking.declareEmergency();
    }

    /// What a settle of `who` in this very block would move to `protocolReserve`: snapshot,
    /// cancel the emergency, unpause, claim the pure yield, read the delta, revert. Nothing
    /// survives but the return. Only the protocol side is read: the claim also sweeps the other
    /// positions (`_autoMaintain`) and settles the emission window, so the reward reserve moves
    /// by more than the exiter's own excess there (test/fix1112/HatchKeepsCancelOpen.t.sol pins
    /// that side).
    function _previewPureSettle(address who) internal returns (uint256 toProtocol) {
        uint256 snap = vm.snapshotState();
        uint256 p0 = staking.protocolReserve();
        vm.prank(admin); staking.cancelEmergency();
        vm.prank(admin); staking.unpause();
        vm.prank(who);   staking.claimPureYield();
        toProtocol = staking.protocolReserve() - p0;
        vm.revertToState(snap);
    }

    function _hatch(address who) internal returns (uint256 dDist, uint256 dRes, uint256 dProt, uint256 got) {
        uint256 d0 = staking.totalRewardDistributed();
        uint256 r0 = staking.rewardReserve();
        uint256 p0 = staking.protocolReserve();
        uint256 b0 = token.balanceOf(who);
        vm.prank(who); staking.emergencyWithdraw();
        got   = token.balanceOf(who) - b0;
        dDist = d0 - staking.totalRewardDistributed();
        dRes  = staking.rewardReserve() - r0;
        dProt = staking.protocolReserve() - p0;
    }

    /// Property: the hatch returns the pure-yield excess of a lapsed lock to `protocolReserve`,
    /// exactly the wei a settle in the same block returns (`_settlePure`), and the book stays
    /// cancellable.
    function test_HatchReturnsThePureStaleExcessASettleWouldReturn() public {
        _pureBesideBorrower(90, 200 days);
        uint256 previewProt = _previewPureSettle(carol);
        assertGt(previewProt, 0, "setup: the lapsed lock left a real pure-yield excess");
        (uint256 dDist, uint256 dRes, uint256 dProt, uint256 got) = _hatch(carol);
        assertEq(dProt, previewProt, "_settlePure: the hatch returns what the settle would have returned");
        assertEq(dDist, dRes + dProt, "distributed falls by the emission excess plus the pure excess, nothing else");
        assertEq(got, 1_000_000e18, "a solvent exit pays the principal");
        assertTrue(staking.isSolvent(), "book is solvent");
        vm.prank(admin); staking.cancelEmergency();
        assertFalse(staking.emergencyMode(), "the emergency is cancelled");
    }

    /// Range: every position leaves before the cancel (the borrower included).
    function test_CancelAfterEveryHatchWithPureExcess() public {
        _pureBesideBorrower(90, 200 days);
        (,, uint256 p1,) = _hatch(carol);
        (,, uint256 p2,) = _hatch(alice);
        assertGt(p1, 0, "setup: the pure holder's exit carries a pure-yield excess");
        assertEq(p2, 0, "the borrower has no pure weight: nothing moves to protocolReserve");
        assertTrue(staking.isSolvent(), "book is solvent");
        vm.prank(admin); staking.cancelEmergency();
        assertFalse(staking.emergencyMode());
    }

    /// Fuzz over the pure holder's lock length and the time elapsed before the halt: whatever the
    /// window shape (lock lapsed inside it or still running), the hatch moves exactly the settle's
    /// wei and a solvent exit never locks the cancel.
    function testFuzz_HatchReturnsThePureStaleExcess(uint16 lockDays, uint32 elapsed) public {
        lockDays = uint16(bound(lockDays, 90, staking.maxLockDaysAvailable()));
        elapsed  = uint32(bound(elapsed, 1 days, 1000 days));
        _pureBesideBorrower(lockDays, elapsed);
        uint256 previewProt = _previewPureSettle(carol);
        (uint256 dDist, uint256 dRes, uint256 dProt,) = _hatch(carol);
        assertEq(dProt, previewProt, "_settlePure: the hatch returns what the settle would have returned");
        assertEq(dDist, dRes + dProt, "distributed falls by the two excesses, nothing else");
        assertTrue(staking.isSolvent(), "book is solvent");
        vm.prank(admin); staking.cancelEmergency();
        assertFalse(staking.emergencyMode());
    }

    /// Fault injection: the tracked pure weight is corrupted below the live one (impossible by
    /// derivation, so only vm.store reaches it). The hatch pays the principal instead of reverting
    /// on `earned - paid`; the pure window is forfeited at the accrued amount, nothing moves.
    function test_HatchPaysThePositionWhenTheLivePureWeightReadsAboveTracked() public {
        _pureBesideBorrower(90, 200 days);
        bytes32 wSlot = _userSlot(carol, 7);                 // trackedBoostedPure
        uint256 w = uint256(vm.load(address(staking), wSlot));
        assertGt(w, 0, "setup: a tracked pure weight exists");
        vm.store(address(staking), wSlot, bytes32(w / 2));
        vm.store(address(staking), _userSlot(carol, 3), bytes32(0));   // pureYieldDebt: the window is the whole accrual
        (,, uint256 dProt, uint256 got) = _hatch(carol);
        assertEq(got, 1_000_000e18, "the hatch pays the principal on a corrupted pure weight");
        assertEq(dProt, 0, "a live share above the accrued window moves nothing");
    }

    /// Fault injection: the distributed side is corrupted below the exiter's pure excess. The
    /// hatch pays the principal instead of reverting on `totalRewardDistributed -= excess`; the
    /// move is clamped to what is booked.
    function test_HatchPaysThePositionWhenThePureExcessReadsAboveDistributed() public {
        _pureBesideBorrower(90, 200 days);
        uint256 previewProt = _previewPureSettle(carol);
        assertGt(previewProt, 0, "setup: a real pure-yield excess to clamp");
        vm.store(address(staking), bytes32(DIST_SLOT), bytes32(0));
        assertEq(staking.totalRewardDistributed(), 0, "setup: the slot is totalRewardDistributed");
        uint256 p0 = staking.protocolReserve();
        (,,, uint256 got) = _hatch(carol);
        assertEq(got, 1_000_000e18, "the hatch pays the principal on a corrupted distributed side");
        assertEq(staking.totalRewardDistributed(), 0, "the move is clamped to what is booked");
        assertEq(staking.protocolReserve(), p0, "protocolReserve receives only what left the distributed side");
    }
}
