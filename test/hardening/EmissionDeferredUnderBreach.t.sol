// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice EMIS-DEFER. Oracle: while the pot cannot cover every claim (`isSolvent() == false`), no
///         transaction pays emission at par, whichever door reaches the settlement (the owner's
///         repay, a third-party lock poke, a liquidation). The doors stay open: the earned amount
///         stays credited to the position, the published quote keeps showing it, and it is paid
///         by the first settlement after the loss is covered.
///         The book: emission funded, one pure staker, two borrowers left untouched for decades;
///         the liquidation of one books an uncovered loss, so the contract reads a hard breach.
///         Red at cc614f9: repay and pokeExpiredLock paid the whole pending emission at par.
contract EmissionDeferredUnderBreachTest is Base {
    uint256 internal constant DUST = 1e10;
    address internal dave = address(0xD4);

    function _breachedBook() internal {
        _untouchedBook();
        vm.prank(keeper);
        staking.liquidate(bob);
        assertFalse(staking.isSolvent(), "setup: hard breach");
        assertGt(staking.totalBadDebt(), DUST, "setup: an uncovered loss is recorded");
    }

    function _untouchedBook() internal {
        _fund(dave);
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        vm.prank(alice);
        staking.deposit(2_000e18, 90);
        vm.prank(carol);
        staking.deposit(1_000e18, 365);
        vm.prank(bob);
        staking.deposit(1_000e18, 90);
        vm.prank(dave);
        staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(carol);
        staking.borrow(400e18);
        vm.prank(bob);
        staking.borrow(500e18);
        vm.prank(dave);
        staking.borrow(500e18);
        vm.warp(block.timestamp + 100 days + 60 * 365 days);
        vm.roll(block.number + 30);
    }

    /// The liquidation that BOOKS the uncovered loss reads the pot after that loss. The book reads
    /// solvent before; seizing bob records a loss the reserve cannot cover, so the same transaction
    /// leaves the pot short and pays bob none of his emission: it stays credited.
    /// Red at d9b9b16: bob was paid 274,188e18 at par and the same tx booked 162.5e18 of bad debt.
    function test_EMISDEFER_liquidationThatBooksTheLossReadsThePotAfterIt() public {
        _untouchedBook();
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before the liquidation");
        uint256 pend = staking.pendingRewards(bob);
        assertGt(pend, DUST, "setup: bob has earned emission");
        uint256 paidBefore = staking.totalRewardsPaid();
        uint256 b0 = token.balanceOf(bob);
        vm.prank(keeper);
        staking.liquidate(bob);
        assertFalse(staking.isSolvent(), "setup: the liquidation left the pot short");
        assertGt(staking.totalBadDebt(), DUST, "setup: the loss is recorded");
        assertEq(token.balanceOf(bob), b0, "emission paid at par by the tx that left the pot short");
        assertEq(staking.totalRewardsPaid(), paidBefore, "no emission counted as paid");
        assertGe(staking.pendingRewards(bob), pend, "the earned emission stays credited");
    }

    function test_EMISDEFER_repayUnderBreachPaysNoEmissionAndKeepsTheCredit() public {
        _breachedBook();
        uint256 pend = staking.pendingRewards(carol);
        assertGt(pend, DUST, "setup: carol has earned emission");
        uint256 paidBefore = staking.totalRewardsPaid();
        uint256 b0 = token.balanceOf(carol);
        vm.prank(carol);
        staking.repay(1e18);
        assertEq(token.balanceOf(carol), b0 - 1e18, "repay under breach moved only the repayment");
        assertEq(staking.totalRewardsPaid(), paidBefore, "no emission counted as paid");
        assertGe(staking.pendingRewards(carol), pend, "the earned emission stays credited");
    }

    function test_EMISDEFER_thirdPartyPokeUnderBreachPaysNoEmission() public {
        _breachedBook();
        uint256 pend = staking.pendingRewards(carol);
        uint256 b0 = token.balanceOf(carol);
        vm.prank(keeper);
        staking.pokeExpiredLock(carol);
        assertEq(token.balanceOf(carol), b0, "a third-party poke paid emission under breach");
        assertGe(staking.pendingRewards(carol), pend, "the earned emission stays credited");
    }

    /// A position closed by liquidation under breach keeps its credit, even when the
    /// liquidation leaves nothing and deletes the position.
    function test_EMISDEFER_liquidationUnderBreachPaysNoEmissionAndKeepsTheCredit() public {
        _breachedBook();
        uint256 pend = staking.pendingRewards(dave);
        assertGt(pend, DUST, "setup: dave has earned emission");
        uint256 b0 = token.balanceOf(dave);
        vm.prank(keeper);
        staking.liquidate(dave);
        assertFalse(staking.isTrackedBorrower(dave), "setup: dave was liquidated");
        assertEq(token.balanceOf(dave), b0, "liquidation under breach paid emission");
        assertGe(staking.pendingRewards(dave), pend, "the earned emission stays credited");
        // The closed position still claims it once the loss is covered.
        vm.prank(keeper);
        staking.absorbBadDebt(type(uint256).max);
        assertTrue(staking.isSolvent(), "setup: the loss is covered");
        uint256 quote = staking.pendingRewards(dave);
        uint256 b1 = token.balanceOf(dave);
        vm.prank(dave);
        staking.claimRewards();
        assertEq(token.balanceOf(dave) - b1, quote, "the closed position is paid its credit");
    }

    /// The credit is paid, quote == execution, by the first settlement once the loss is covered.
    function test_EMISDEFER_deferredCreditIsPaidOnceSolvent() public {
        _breachedBook();
        uint256 pend = staking.pendingRewards(carol);
        vm.prank(carol);
        staking.repay(1e18);
        vm.prank(keeper);
        staking.absorbBadDebt(type(uint256).max);
        assertTrue(staking.isSolvent(), "setup: the loss is covered");
        uint256 quote = staking.pendingRewards(carol);
        assertGe(quote, pend, "quote still carries the credit");
        uint256 b0 = token.balanceOf(carol);
        vm.prank(carol);
        staking.claimRewards();
        assertEq(token.balanceOf(carol) - b0, quote, "claim pays exactly the published quote");
        assertEq(staking.pendingRewards(carol), 0, "nothing left credited");
    }

    /// The emergency exit forfeits unpaid emission, and a deferred credit is unpaid emission.
    function test_EMISDEFER_emergencyExitForfeitsTheDeferredCredit() public {
        _breachedBook();
        vm.prank(carol);
        staking.repay(1e18);
        assertGt(staking.pendingRewards(carol), DUST, "setup: a credit was deferred");
        vm.prank(keeper);
        staking.tripBreaker();
        vm.prank(carol);
        staking.emergencyWithdraw();
        assertEq(staking.pendingRewards(carol), 0, "the exited position keeps no emission credit");
    }

    // ── the settle reads the pot after the loss its own transaction books ──────────────────────
    // The book: `_untouchedBook` left 50 more years (110 in all). Bob's interest has outgrown his
    // stake, but nobody has attributed it, so the book still reads solvent. Paused, so no
    // maintenance sweep runs: the only loss in the transaction is the one bob's own attribution
    // books. Red at 67ba48f: the settle read the pot before that attribution and paid bob
    // 274,188.78e18 at par; the attribution then booked 212.13e18 of bad debt and the transaction
    // ended in a hard breach (claimRewards, repay and pokeExpiredLock alike).

    function _ownShortfallBook() internal {
        _untouchedBook();
        vm.warp(block.timestamp + 50 * 365 days);
        vm.roll(block.number + 30);
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(keeper);
        staking.pause();
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before bob is attributed");
    }

    function _assertOwnShortfallDeferred(uint256 b0, uint256 pend, uint256 bad0, uint256 paid0) internal view {
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: bob's attribution booked a loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        assertEq(token.balanceOf(bob), b0, "emission paid at par by the tx that left the pot short");
        assertEq(staking.totalRewardsPaid(), paid0, "no emission counted as paid");
        assertGe(staking.pendingRewards(bob), pend, "the earned emission stays credited");
    }

    function test_EMISDEFER_claimThatBooksItsOwnShortfallReadsThePotAfterIt() public {
        _ownShortfallBook();
        uint256 pend = staking.pendingRewards(bob);
        assertGt(pend, DUST, "setup: bob has earned emission");
        (uint256 b0, uint256 bad0, uint256 paid0) =
            (token.balanceOf(bob), staking.totalBadDebt(), staking.totalRewardsPaid());
        vm.prank(bob);
        staking.claimRewards();
        _assertOwnShortfallDeferred(b0, pend, bad0, paid0);
    }

    function test_EMISDEFER_repayThatBooksItsOwnShortfallReadsThePotAfterIt() public {
        _ownShortfallBook();
        uint256 pend = staking.pendingRewards(bob);
        (uint256 b0, uint256 bad0, uint256 paid0) =
            (token.balanceOf(bob), staking.totalBadDebt(), staking.totalRewardsPaid());
        vm.prank(bob);
        staking.repay(1e18);
        _assertOwnShortfallDeferred(b0 - 1e18, pend, bad0, paid0);
    }

    function test_EMISDEFER_lockPokeThatBooksTheOwnersShortfallReadsThePotAfterIt() public {
        _ownShortfallBook();
        uint256 pend = staking.pendingRewards(bob);
        (uint256 b0, uint256 bad0, uint256 paid0) =
            (token.balanceOf(bob), staking.totalBadDebt(), staking.totalRewardsPaid());
        vm.prank(keeper);
        staking.pokeExpiredLock(bob);
        _assertOwnShortfallDeferred(b0, pend, bad0, paid0);
    }

    /// The loss can come after the settle in the same transaction: a keeper's lock poke settles
    /// bob, then its maintenance sweep liquidates bob. The settle counts bob's own uncovered loss.
    /// Red at 67ba48f: bob was paid 274,188.78e18 at par and the sweep then booked 162.53e18 of
    /// bad debt, leaving a hard breach.
    function test_EMISDEFER_lockPokeWhoseSweepSeizesTheOwnerReadsThePotAfterIt() public {
        _untouchedBook();
        assertTrue(staking.isSolvent(), "setup: the book reads solvent before the poke");
        uint256 pend = staking.pendingRewards(bob);
        assertGt(pend, DUST, "setup: bob has earned emission");
        (uint256 b0, uint256 bad0) = (token.balanceOf(bob), staking.totalBadDebt());
        vm.prank(keeper);
        staking.pokeExpiredLock(bob);
        assertFalse(staking.isTrackedBorrower(bob), "setup: the sweep liquidated bob");
        assertGt(staking.totalBadDebt(), bad0 + DUST, "setup: the liquidation booked a loss");
        assertFalse(staking.isSolvent(), "setup: that loss left the pot short");
        assertEq(token.balanceOf(bob), b0, "emission paid at par by the tx that left the pot short");
        assertGe(staking.pendingRewards(bob), pend, "the earned emission stays credited");
    }

    /// The other side of the own-loss read: a seizure whose shortfall the reserve covers in full
    /// books no uncovered loss, so it still pays the earned emission at par. The book has no pure
    /// staker, so the interest of three borrowers fills the reserve for 60 years.
    function test_EMISDEFER_liquidationWhoseLossTheReserveCoversPaysAtPar() public {
        _fund(dave);
        vm.prank(admin);
        staking.fundEmission(2_000_000e18);
        vm.prank(carol);
        staking.deposit(1_000e18, 365);
        vm.prank(bob);
        staking.deposit(1_000e18, 90);
        vm.prank(dave);
        staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(carol);
        staking.borrow(400e18);
        vm.prank(bob);
        staking.borrow(500e18);
        vm.prank(dave);
        staking.borrow(500e18);
        vm.warp(block.timestamp + 60 * 365 days);
        vm.roll(block.number + 30);

        uint256 pend = staking.pendingRewards(bob);
        assertGt(pend, DUST, "setup: bob has earned emission");
        (uint256 b0, uint256 bad0) = (token.balanceOf(bob), staking.totalBadDebt());
        vm.recordLogs();
        vm.prank(keeper);
        staking.liquidate(bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Liquidated(address,address,uint256,uint256,uint256,uint256,uint256)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            (uint256 seized, uint256 debt,,, uint256 uncovered) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            assertLt(seized, debt, "setup: the seizure leaves a shortfall");
            assertEq(uncovered, 0, "setup: the reserve covers all of it");
            seen = true;
        }
        assertTrue(seen, "setup: bob was liquidated");
        assertEq(staking.totalBadDebt(), bad0, "setup: no uncovered loss booked");
        assertTrue(staking.isSolvent(), "the book reads solvent after it");
        assertEq(token.balanceOf(bob) - b0, pend, "the earned emission is paid at par");
    }
}
