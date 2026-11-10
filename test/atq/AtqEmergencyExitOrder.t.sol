// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  atq-1111 (staking front) — emergency: exit order, and the guards of the path
//
//  1. A breached emergency pays every position the same share in every exit order.
//     Root of the breach here: a token-level loss (the balance drops under the books),
//     not the attribution path. ORACLE: the test's own sum of stored positive equity
//     (raw storage) and plain integer arithmetic; neither `totalPositiveEquity` nor
//     `mulDiv` is read to decide what a payout should be.
//     TOLERANCE, derived (no fixed threshold): each exit floors once, so the ratio
//     pot/E can only rise, by less than 1/E' per earlier exit; a position still in E'
//     has equity <= E', so its payout moves by at most one wei per earlier exit.
//     This sharpens test/fix1027 `testFuzz_P1_EMG_exit_order_never_changes_a_payout` (three
//     fixed positions, always breached, 1e11 tolerance) to five fuzzed positions, both
//     regimes, two orders on the same state and a wei bound.
//  2. The emergency guards that had no mutant: the breaker inside an emergency on a breached
//     book, the breaker boundary at the dust +- one wei, the cancel on a short book, and the
//     halt whose length changes nothing in the books after a cancel. Guards whose refusal is already
//     asserted elsewhere only gain a mutant paired with that existing test.
//
//  Paired mutants: [ATQ-staking-24..39] in .github/scripts/mutants.py.
//  Run: forge test --match-path test/atq/AtqEmergencyExitOrder.t.sol
// =============================================================================

import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";

contract AtqEmergencyExitOrderTest is Base {
    uint256 internal constant N = 5;
    uint256 internal constant USERS_SLOT = 36;
    uint256 internal constant DUST = 1e10;      // CONSERVATION_DUST
    address[] internal ppl;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        staking.fundEmission(10_000_000e18);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.stopPrank();
        for (uint256 i = 0; i < N; i++) { address p = address(uint160(0xE000 + i)); _fund(p); ppl.push(p); }
    }

    function _raw(address a) internal view returns (uint256 s, uint256 d) {
        uint256 base = uint256(keccak256(abi.encode(a, USERS_SLOT)));
        s = uint256(vm.load(address(staking), bytes32(base)));
        d = uint256(vm.load(address(staking), bytes32(base + 1)));
    }
    function _equity(address a) internal view returns (uint256) { (uint256 s, uint256 d) = _raw(a); return s > d ? s - d : 0; }
    function _lose(uint256 amt) internal { vm.prank(address(staking)); token.transfer(address(0xDEAD), amt); }
    function _breached() internal view returns (bool) { return staking.backing() + DUST < staking.owed(); }
    function _exit(address who) internal returns (uint256 got) {
        uint256 b = token.balanceOf(who);
        vm.prank(who); staking.emergencyWithdraw();
        got = token.balanceOf(who) - b;
    }
    function _exitAll(uint256[N] memory order) internal returns (uint256[N] memory paid, uint256 sum) {
        for (uint256 k = 0; k < N; k++) { paid[order[k]] = _exit(ppl[order[k]]); sum += paid[order[k]]; }
    }

    /// Ranges: stake 1 token .. the wallet cap; debt none .. the LTV cap; halt after 1 s .. 80 days of
    /// interest; loss 1 wei .. the whole balance but one wei (solvent and breached regimes); entry by
    /// the permissionless breaker or by the guardian; any exit permutation against the identity order.
    function testFuzz_AtqBreachedExitPaysTheSameShareInEveryOrder(
        uint256[N] memory stakeSeed, uint256[N] memory debtSeed, uint256 lossSeed, uint256 timeSeed, uint256 permSeed
    ) public {
        for (uint256 i = 0; i < N; i++) {
            vm.prank(ppl[i]); staking.deposit(bound(stakeSeed[i], 1e18, 30_000_000e18), 90);
        }
        vm.roll(vm.getBlockNumber() + 11);
        for (uint256 i = 0; i < N; i++) {
            if (debtSeed[i] % 2 == 0) continue;
            (uint256 s,) = _raw(ppl[i]);
            vm.prank(ppl[i]);
            try staking.borrow(bound(debtSeed[i], 1, s / 2)) {} catch {}     // the utilisation cap may refuse
        }
        vm.warp(vm.getBlockTimestamp() + bound(timeSeed, 1, 80 days));
        vm.roll(vm.getBlockNumber() + 11);

        _lose(bound(lossSeed, 1, token.balanceOf(address(staking)) - 1));
        if (_breached()) { vm.prank(bob); staking.tripBreaker(); }
        else             { vm.prank(keeper); staking.declareEmergency(); }
        for (uint256 i = 0; i < N; i++) staking.syncEquity(ppl[i]);

        // independent reading of the book the exits draw on
        uint256[N] memory e; uint256 E;
        for (uint256 i = 0; i < N; i++) { e[i] = _equity(ppl[i]); E += e[i]; }
        uint256 pot = token.balanceOf(address(staking));
        assertEq(staking.totalPositiveEquity(), E, "after syncing every position the accumulator is the sum");

        uint256[N] memory idn; uint256[N] memory perm;
        for (uint256 i = 0; i < N; i++) { idn[i] = i; perm[i] = i; }
        for (uint256 i = N - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(permSeed, i))) % (i + 1);
            (perm[i], perm[j]) = (perm[j], perm[i]);
        }

        uint256 snap = vm.snapshot();
        (uint256[N] memory pa, uint256 sa) = _exitAll(idn);
        vm.revertTo(snap);
        (uint256[N] memory pb, uint256 sb) = _exitAll(perm);

        for (uint256 i = 0; i < N; i++) {
            uint256 fair = pot >= E ? e[i] : (e[i] * pot) / E;
            assertGe(pa[i], fair, "identity order: paid below the share");
            assertLe(pa[i], fair + (N - 1), "identity order: paid above the share");
            assertGe(pb[i], fair, "permuted order: paid below the share");
            assertLe(pb[i], fair + (N - 1), "permuted order: paid above the share");
        }
        assertLe(sa, pot, "identity order: paid more than the pot");
        assertLe(sb, pot, "permuted order: paid more than the pot");
        if (pot < E) {
            assertGe(sa + N, pot, "identity order: part of a short pot was stranded");
            assertGe(sb + N, pot, "permuted order: part of a short pot was stranded");
        }
    }

    // ── the guards of the emergency path ─────────────────────────────────────────────────────
    function _seed() internal {
        vm.prank(alice); staking.deposit(1_000_000e18, 90);
        vm.roll(vm.getBlockNumber() + 11);
    }
    function _declare() internal { vm.prank(keeper); staking.declareEmergency(); }

    function test_AtqTripBreakerIsRefusedInsideAnEmergency_EvenOnABreachedBook() public {
        _seed(); _declare(); _lose(5_000_000e18);
        assertTrue(_breached(), "setup: the book is breached");
        vm.expectRevert(BlazePhoenixStaking.Staking__EmergencyActive.selector);
        staking.tripBreaker();
    }
    function test_AtqTripBreakerIsRefusedOnASoundBook_AndTripsOnceItIsShort() public {
        _seed();
        vm.expectRevert(BlazePhoenixStaking.Staking__NoBreach.selector);
        staking.tripBreaker();
        _lose(DUST);                                   // short by exactly the dust: still sound
        vm.expectRevert(BlazePhoenixStaking.Staking__NoBreach.selector);
        staking.tripBreaker();
        _lose(1);                                      // one wei past the dust
        staking.tripBreaker();
        assertTrue(staking.emergencyMode(), "one wei past the dust trips");
    }
    function test_AtqCancelEmergencyIsRefusedWhileTheBookIsShort_AndPassesOnceItIsWhole() public {
        _seed(); _declare(); _lose(5_000_000e18);
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.cancelEmergency();
        vm.prank(alice); token.transfer(address(staking), 5_000_000e18);   // made whole again
        vm.prank(admin); staking.cancelEmergency();
        assertFalse(staking.emergencyMode(), "a whole book resumes");
    }

    /// The halt is never charged nor emitted: a cancel resumes both clocks at the cancel, so the books
    /// after the resume cannot depend on how long the halt lasted. Metamorphic, on the same state:
    /// a halt of zero seconds against a halt of 1 s .. 80 days. The 90-day locks do not lapse inside
    /// either path (3 d + 80 d), so no lapsed weight enters the comparison. (An absolute reading of
    /// `totalRewardDistributed` is not an oracle here: a settle hands a borrower's stale excess back.)
    function testFuzz_AtqTheLengthOfACancelledHaltChangesNothingInTheBooks(uint256 haltSeed) public {
        _seed();
        vm.prank(bob); staking.deposit(2_000_000e18, 90);
        vm.roll(vm.getBlockNumber() + 11);
        vm.prank(bob); staking.borrow(500_000e18);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _declare();
        assertGt(staking.totalRewardDistributed(), 0, "setup: emission ran before the halt");
        assertGt(staking.accInterestPerDebt(), 0, "setup: interest ran before the halt");

        uint256 snap = vm.snapshot();
        uint256[7] memory zero = _resumeAndSettle(0);
        vm.revertTo(snap);
        uint256[7] memory late = _resumeAndSettle(bound(haltSeed, 1, 80 days));

        assertGt(zero[6], 0, "setup: the first claim after the resume pays something");
        assertEq(late[0], zero[0], "the halt emitted (totalRewardDistributed)");
        assertEq(late[1], zero[1], "the halt emitted (accRewardPerShare)");
        assertEq(late[2], zero[2], "the halt charged interest (accInterestPerDebt)");
        assertEq(late[3], zero[3], "the halt charged interest (totalInterestAccruedGlobal)");
        assertEq(late[4], zero[4], "the halt moved the reward reserve");
        assertEq(late[5], zero[5], "the halt moved the protocol reserve");
        assertEq(late[6], zero[6], "the halt changed what the first claim pays");
    }
    function _resumeAndSettle(uint256 halt) internal returns (uint256[7] memory r) {
        vm.warp(vm.getBlockTimestamp() + halt);
        vm.roll(vm.getBlockNumber() + 11);
        vm.startPrank(admin); staking.cancelEmergency(); staking.unpause(); vm.stopPrank();
        uint256 b = token.balanceOf(alice);
        vm.prank(alice); staking.claimRewards();        // first settle after the resume, same second
        r[0] = staking.totalRewardDistributed(); r[1] = staking.accRewardPerShare();
        r[2] = staking.accInterestPerDebt();     r[3] = staking.totalInterestAccruedGlobal();
        r[4] = staking.rewardReserve();          r[5] = staking.protocolReserve();
        r[6] = token.balanceOf(alice) - b;
    }
}
