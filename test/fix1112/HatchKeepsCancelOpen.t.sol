// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// fix1112, second part. The emergency hatch returns the exiter's stale-weight excess to the
// reserve through `_settleEmission`, which lowers `totalRewardDistributed`; `cancelEmergency`
// requires that quantity frozen since the trip (3326 meta-guard). Red at 80db7e9: one solvent
// exit with excess > 0 locked the cancel for good (Staking__InvariantBreached). The hatch now
// mirrors the move on the anchor, and the two reward subtractions it inherited from the settle are
// clamped so the last door never closes on broken reward arithmetic (I4, the measured side wins).
//
// Matrix: range (one exit, every exit, fuzzed lock length and elapsed time) x vector (lapsed lock,
// borrower stale by interest, corrupted tracked weight, corrupted distributed side) x dimension
// (unit, fuzz, fault injection by vm.store, gas print).
// Mutants (.github/scripts/mutants.py): "emergencyWithdraw: the hatch moves distributed but not the
// 3326 anchor", "_settleEmission: the live-weight share is a checked subtraction",
// "_settleEmission: the excess leaves the distributed side unclamped". The atq observer
// (`cancelRefusedSolvent` in test/atq/AtqEmergencySurface.invariant.t.sol) pairs with the first
// mutant through its scripted solvent sequence.

import {console2} from "forge-std/Test.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";

contract HatchKeepsCancelOpenTest is Base {
    uint256 internal constant USERS_SLOT = 36;
    uint256 internal constant DIST_SLOT  = 17;   // totalRewardDistributed

    function setUp() public override {
        super.setUp();
        vm.prank(admin); staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
    }

    function _userSlot(address a, uint256 field) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(a, USERS_SLOT))) + field);
    }

    /// Two 90-day locks, emission funded, 200 days pass (both locks lapse inside the window),
    /// then the GUARDIAN halts. `who` leaves through the hatch; returns what the hatch moved.
    function _lapsedLockHalt() internal {
        vm.prank(alice); staking.deposit(1_000_000e18, 90);
        vm.prank(bob);   staking.deposit(1_000_000e18, 90);
        vm.prank(admin); staking.fundEmission(1_000_000e18);
        vm.warp(block.timestamp + 200 days); vm.roll(block.number + 20);
        vm.prank(keeper); staking.declareEmergency();
    }

    function _hatch(address who) internal returns (uint256 dDist, uint256 dRes, uint256 got, uint256 gas) {
        uint256 d0 = staking.totalRewardDistributed();
        uint256 r0 = staking.rewardReserve();
        uint256 b0 = token.balanceOf(who);
        vm.prank(who);
        uint256 g0 = gasleft();
        staking.emergencyWithdraw();
        gas = g0 - gasleft();
        got = token.balanceOf(who) - b0;
        dDist = d0 - staking.totalRewardDistributed();
        dRes = staking.rewardReserve() - r0;
    }

    /// Property: a solvent emergency in which one staker used the hatch can still be cancelled.
    function test_CancelAfterHatchOnSolventBook() public {
        _lapsedLockHalt();
        (uint256 dDist, uint256 dRes, uint256 got, uint256 gas) = _hatch(alice);
        console2.log("hatch gas (lapsed lock, excess > 0)", gas);
        assertGt(dRes, 0, "setup: the exit carries a stale-weight excess");
        assertEq(dDist, dRes, "the excess moves from distributed to the reserve, nothing else");
        assertEq(got, 1_000_000e18, "a solvent exit pays the principal");
        assertTrue(staking.isSolvent(), "book is solvent");
        vm.prank(admin); staking.cancelEmergency();
        assertFalse(staking.emergencyMode(), "the emergency is cancelled");
    }

    /// Range: every position leaves before the cancel.
    function test_CancelAfterEveryHatchOnSolventBook() public {
        _lapsedLockHalt();
        (, uint256 r1,,) = _hatch(alice);
        (, uint256 r2,,) = _hatch(bob);
        assertGt(r1 + r2, 0, "setup: the exits carry a stale-weight excess");
        assertTrue(staking.isSolvent(), "book is solvent");
        vm.prank(admin); staking.cancelEmergency();
        assertFalse(staking.emergencyMode());
    }

    /// Vector: a borrower whose tracked weight is stale-high by the interest charged since its last
    /// touch (P1-C), the lock still running at the trip.
    function test_CancelAfterBorrowerHatchOnSolventBook() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 365);
        vm.prank(bob);   staking.deposit(1_000_000e18, 365);
        vm.prank(admin); staking.fundEmission(1_000_000e18);
        vm.roll(block.number + 20);
        vm.prank(alice); staking.borrow(400_000e18);
        vm.warp(block.timestamp + 120 days); vm.roll(block.number + 20);
        vm.prank(keeper); staking.declareEmergency();
        (, uint256 dRes,,) = _hatch(alice);
        assertGt(dRes, 0, "setup: interest left the tracked weight stale-high");
        assertTrue(staking.isSolvent(), "book is solvent");
        vm.prank(admin); staking.cancelEmergency();
        assertFalse(staking.emergencyMode());
    }

    /// Fuzz over the lock length (MIN_LOCK_DAYS..730) and the time elapsed before the halt:
    /// whatever the window shape (lock lapsed inside it or still running), a solvent exit never
    /// locks the cancel.
    function testFuzz_CancelAfterHatchOnSolventBook(uint16 lockDays, uint32 elapsed) public {
        lockDays = uint16(bound(lockDays, 90, 730));
        elapsed  = uint32(bound(elapsed, 1 days, 1000 days));
        vm.prank(alice); staking.deposit(1_000_000e18, lockDays);
        vm.prank(bob);   staking.deposit(1_000_000e18, 90);
        vm.prank(admin); staking.fundEmission(1_000_000e18);
        vm.warp(block.timestamp + elapsed); vm.roll(block.number + 20);
        vm.prank(keeper); staking.declareEmergency();
        (uint256 dDist, uint256 dRes,,) = _hatch(alice);
        assertEq(dDist, dRes, "the excess moves from distributed to the reserve, nothing else");
        assertTrue(staking.isSolvent(), "book is solvent");
        vm.prank(admin); staking.cancelEmergency();
        assertFalse(staking.emergencyMode());
    }

    /// Fault injection: the tracked weight is corrupted below the live one (impossible by
    /// derivation, so only vm.store reaches it). The hatch pays the principal instead of reverting
    /// on `earned - paid`; the window is forfeited at the accrued amount, nothing moves.
    function test_HatchPaysThePositionWhenTheLiveWeightReadsAboveTracked() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 365);
        vm.prank(admin); staking.fundEmission(1_000_000e18);
        vm.warp(block.timestamp + 100 days); vm.roll(block.number + 20);
        vm.prank(keeper); staking.declareEmergency();
        bytes32 wSlot = _userSlot(alice, 6);                 // trackedBoostedEffective
        uint256 w = uint256(vm.load(address(staking), wSlot));
        assertGt(w, 0, "setup: a tracked weight exists");
        vm.store(address(staking), wSlot, bytes32(w / 2));
        vm.store(address(staking), _userSlot(alice, 2), bytes32(0));   // rewardDebt: the window is the whole accrual
        (uint256 dDist, uint256 dRes, uint256 got,) = _hatch(alice);
        assertEq(got, 1_000_000e18, "the hatch pays the principal on a corrupted weight");
        assertEq(dDist, 0, "a live share above the accrued window moves nothing");
        assertEq(dRes, 0, "a live share above the accrued window moves nothing");
    }

    /// Fault injection: the distributed side is corrupted below the exiter's excess. The hatch
    /// pays the principal instead of reverting on `totalRewardDistributed -= excess`; the move is
    /// clamped to what is booked.
    function test_HatchPaysThePositionWhenTheExcessReadsAboveDistributed() public {
        _lapsedLockHalt();
        assertGt(staking.totalRewardDistributed(), 0, "setup: emission was distributed");
        vm.store(address(staking), bytes32(DIST_SLOT), bytes32(0));
        assertEq(staking.totalRewardDistributed(), 0, "setup: the slot is totalRewardDistributed");
        uint256 r0 = staking.rewardReserve();
        (,, uint256 got,) = _hatch(alice);
        assertEq(got, 1_000_000e18, "the hatch pays the principal on a corrupted distributed side");
        assertEq(staking.totalRewardDistributed(), 0, "the move is clamped to what is booked");
        assertEq(staking.rewardReserve(), r0, "the reserve receives only what left the distributed side");
    }
}
