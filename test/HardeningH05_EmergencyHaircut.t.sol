// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// H-05 regression suite — pro-rata solvency haircut on `emergencyWithdraw`.
//
// THE HOLE. Pre-fix, `emergencyWithdraw` paid every exiter their FULL net equity
// (staked - debt) straight out of the physical pot. But the one state the function exists
// for — a BREACHED emergency — is exactly the state where the pot holds LESS than the sum
// of net equities. Full payout there is a first-come-first-served drain: early exiters are
// made whole with money that partially belongs to later ones, and once the pot is empty the
// remaining exiters' transfers revert Staking__TransferFailed — mempool priority, not the
// ledger, decided who ate the loss and who got zero.
//
// THE FIX. When pot < claims (pot = real BZPX balance, claims = totalStaked - totalDebt =
// the sum of all remaining net equities), the payout is scaled: payout = equity * pot/claims.
// The fraction pot/claims is ORDER-INVARIANT across exits — each exit removes `payout` from
// the numerator and its own `equity` from the denominator in the same ratio — so first and
// last exiter receive the SAME fraction of their equity and the pot empties exactly to zero.
// When pot >= claims the branch never engages and full net equity is paid, as before.
//
// REACHING THE STATE, deterministically. A healthy book always has pot == claims here
// (deposits add to both sides, borrows remove from both sides, no emission is funded in
// these tests), so the shortfall must be a real loss of backing: the mock token exposes
// `burn(from, amount)` and we burn part of the contract's balance — the on-chain shape of
// a theft/bug, the precondition H-05 is about. `isSolvent()` flips false, the GUARDIAN
// halts (same grantRole + declareEmergency sequence as BlazePhoenixStaking.t.sol's
// test_Emergency), and everyone exits through the pull-only path. Round numbers throughout
// (fractions 1/2 and 3/5 over e18-scaled powers of ten) so mulDiv is exact and every
// assertion is to-the-wei equality, no tolerances. No warp between borrow and exit, so
// `_accrueInterestFor` contributes exactly zero and equities stay the literal constants.
//
// Same harness as BlazePhoenixStaking.t.sol / HardeningH04_UtilCap.t.sol; mock renamed
// (and extended with `burn`) to avoid artifact-name ambiguity.
//
//   forge test --match-contract HardeningH05 -vvv

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract MockERC20H05 {
    string public name = "BlazePhoenix"; string public symbol = "BZPX"; uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    /// @dev the H-05 lever: destroy part of an address's balance to model a real loss of
    ///      backing (theft/bug). Burning from the staking contract is what turns a healthy
    ///      pot == claims book into the breached pot < claims state the haircut exists for.
    function burn(address from, uint256 a) external { balanceOf[from] -= a; totalSupply -= a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal"); balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a, "bal");
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a, "allow"); allowance[f][msg.sender] = al - a; }
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract HardeningH05EmergencyHaircutTest is Test {
    BlazePhoenixStaking staking;
    MockERC20H05 token;
    address admin = address(0xA11CE);
    address treasury = address(0x713A5);
    address alice = address(0x1);
    address bob = address(0x2);
    address carol = address(0x3);
    address keeper = address(0x4);

    function _fund(address u) internal {
        token.mint(u, 500_000_000e18);
        vm.prank(u);
        token.approve(address(staking), type(uint256).max);
    }

    function setUp() public {
        vm.warp(1_900_000_000);
        token = new MockERC20H05();
        vm.prank(admin);
        staking = new BlazePhoenixStaking(address(token), treasury);
        _fund(admin); _fund(alice); _fund(bob); _fund(carol); _fund(keeper);
    }

    /// Same emergency entry as BlazePhoenixStaking.t.sol::test_Emergency — guardian halt.
    function _declareEmergency() internal {
        vm.prank(admin); staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(keeper); staking.declareEmergency();
        assertTrue(staking.emergencyMode());
    }

    /// Pull-only exit; returns exactly what the exiter was paid.
    function _exit(address who) internal returns (uint256 got) {
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        staking.emergencyWithdraw();
        got = token.balanceOf(who) - before;
    }

    /// Two pure stakers (600k/400k), then HALF the backing is stolen: pot 500k against 1M of
    /// claims → the invariant fraction is exactly 1/2. Asserts the breach is real before the
    /// halt, so the haircut is exercised in the only state it may engage in.
    function _setupShortPotPureStakers() internal {
        vm.prank(alice); staking.deposit(600_000e18, 90);
        vm.prank(bob);   staking.deposit(400_000e18, 90);
        vm.roll(block.number + 2);

        token.burn(address(staking), 500_000e18);          // the theft: half the pot is gone

        // Preconditions the whole regression rests on — assert them, don't assume them.
        assertEq(staking.backing(), 500_000e18, "pot after theft");
        assertEq(staking.totalStaked() - staking.totalDebt(), 1_000_000e18, "claims");
        assertFalse(staking.isSolvent(), "the haircut may only engage on a real breach");

        _declareEmergency();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // (a) ORDER-INVARIANCE, leg 1: alice (600k equity) exits BEFORE bob (400k equity).
    // Pot 500k, claims 1M → both must be paid exactly half their equity. Pre-fix, this leg
    // paid alice her FULL 600k... except the pot only held 500k, so her transfer reverted
    // and the "first-come" scramble began. Post-fix: 300k + 200k, pot empties to zero.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_H05_ShortPot_ExitOrder_AliceFirst_BothPaidSameFraction() public {
        _setupShortPotPureStakers();

        uint256 aliceGot = _exit(alice);
        uint256 bobGot   = _exit(bob);

        assertEq(aliceGot, 300_000e18, "early exiter: exactly half of 600k equity");
        assertEq(bobGot,   200_000e18, "late exiter: exactly half of 400k equity");
        // payout_i / equity_i identical, asserted without division:
        // aliceGot * bobEquity == bobGot * aliceEquity.
        assertEq(aliceGot * 400_000e18, bobGot * 600_000e18, "same fraction for both exiters");

        assertEq(staking.backing(), 0, "the pot empties exactly — nothing stranded");
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.owed(), 0, "every claim settled");
        assertEq(staking.activeLockerCount(), 0, "no ghost registry entries left behind");
        assertTrue(staking.isSolvent(), "0 held vs 0 owed: the exit itself resolves the breach");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // (a) ORDER-INVARIANCE, leg 2: the SAME book, exits in the OPPOSITE order. Every
    // assertion is the same constant as leg 1 — together the two legs prove exit order is
    // irrelevant to who gets what. Pre-fix this leg was the actual drain: bob's full 400k
    // fit inside the 500k pot, so he left whole and alice's 600k transfer reverted against
    // the 100k remainder — she was stuck with ZERO while holding 60% of the claims.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_H05_ShortPot_ExitOrder_BobFirst_BothPaidSameFraction() public {
        _setupShortPotPureStakers();

        uint256 bobGot   = _exit(bob);
        uint256 aliceGot = _exit(alice);

        assertEq(bobGot,   200_000e18, "early exiter: exactly half of 400k equity");
        assertEq(aliceGot, 300_000e18, "late exiter: exactly half of 600k equity");
        assertEq(aliceGot * 400_000e18, bobGot * 600_000e18, "same fraction for both exiters");

        assertEq(staking.backing(), 0, "the pot empties exactly — nothing stranded");
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.owed(), 0, "every claim settled");
        assertTrue(staking.isSolvent());
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // (b) THE ATTACK SHAPE: an early exiter whose full equity fits the pot must NOT drain
    // it and leave the late pure staker with nothing. Alice stakes 1M and borrows 400k
    // (equity 600k; the borrow itself moved 400k out of the pot). Bob is a pure staker with
    // 400k. A 400k theft leaves pot 600k against 1M of claims → fraction 3/5.
    //
    // Pre-fix: alice's full 600k equity == the whole pot; she exits whole and bob's 400k
    // transfer reverts against an empty pot — the late pure staker gets ZERO.
    // Post-fix: alice 360k, bob 240k — the same 3/5 each, and the pot ends exactly empty.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_H05_EarlyBorrowerExitCannotDrainPot_LatePureStakerStillPaid() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 90);
        vm.prank(bob);   staking.deposit(400_000e18, 90);
        vm.roll(block.number + 2);
        vm.prank(alice); staking.borrow(400_000e18);       // debt nets against her principal

        assertEq(staking.backing(), 1_000_000e18, "healthy: pot == claims to the wei");
        token.burn(address(staking), 400_000e18);          // the theft
        assertEq(staking.backing(), 600_000e18, "pot after theft");
        assertEq(staking.totalStaked() - staking.totalDebt(), 1_000_000e18, "claims");
        assertFalse(staking.isSolvent(), "real breach, the only state the haircut engages in");

        _declareEmergency();

        uint256 aliceGot = _exit(alice);                   // the would-be drainer goes FIRST
        assertEq(aliceGot, 360_000e18, "3/5 of her 600k net equity — not the full pot");
        assertEq(staking.backing(), 240_000e18, "bob's share is still physically there");

        uint256 bobGot = _exit(bob);
        assertGt(bobGot, 0, "the late pure staker must never be left with zero");
        assertEq(bobGot, 240_000e18, "3/5 of his 400k equity — the SAME fraction as alice");
        assertEq(aliceGot * 400_000e18, bobGot * 600_000e18, "payout_i / equity_i equal");

        assertEq(staking.backing(), 0, "pot distributed exactly, no residue");
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.totalDebt(), 0);
        assertEq(staking.owed(), 0);
        assertTrue(staking.isSolvent());
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // HONEST OPERATION UNCHANGED: in a discretionary (non-breached) emergency the pot equals
    // the claims exactly (1000 in, 300 borrowed out → pot 700 vs claims 700), the strict
    // `pot < claims` gate stays closed, and the exiter is paid FULL net equity — the same
    // number BlazePhoenixStaking.t.sol::test_Emergency has always asserted. The haircut must
    // never tax a solvent exit.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_H05_SolventEmergency_FullNetEquityUnchanged() public {
        vm.prank(alice); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(alice); staking.borrow(300e18);

        assertEq(staking.backing(), 700e18, "pot == claims: the boundary, not a shortfall");
        assertEq(staking.totalStaked() - staking.totalDebt(), 700e18);
        assertTrue(staking.isSolvent());

        _declareEmergency();

        uint256 aliceGot = _exit(alice);
        assertEq(aliceGot, 700e18, "full net equity = staked - debt, no haircut when solvent");
        assertEq(staking.backing(), 0);
        assertEq(staking.owed(), 0);
    }
}
