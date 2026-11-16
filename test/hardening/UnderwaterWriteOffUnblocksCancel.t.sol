// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice An unrecorded loss must be recordable inside an emergency, or `absorbBadDebt` cannot
///         reach it and `cancelEmergency` keeps reverting.
///
///         The book: a borrower whose interest has outgrown her stake while no liquidation or sweep
///         ran, so `_owed()` floors the ledger (totalStaked + rewardReserve + protocolReserve <
///         totalDebt). In an emergency `liquidate` and the sweep are closed. Before the fix
///         `syncEquity` attributed only the interest above the stake and never the debt above it,
///         so the loss stayed unrecorded, `absorbBadDebt` covered only `totalBadDebt`, and the read
///         deficit kept a remainder of `totalDebt - ledgerSum` that kept `cancelEmergency` reverting,
///         against the NatSpec of `absorbBadDebt`.
///
///         The fix: `syncEquity` writes off a position whose stake no longer exceeds its debt,
///         booking the loss exactly as the borrower's own `emergencyWithdraw` books it (a
///         liquidation with no seizure bonus). A position with stake above its debt is untouched.
///
///         Red at c0366cf: the cancel tests revert with `Staking__InvariantBreached` after every
///         recordable loss has been recorded and absorbed.
///
///         Oracle: the public getters of the book (owed, backing, totalStaked, rewardReserve,
///         protocolReserve, totalDebt, totalBadDebt, getUserInfo), the stake-ledger identity read
///         from storage, the borrower's own emergency exit as a second path, and refusals by selector.
contract UnderwaterWriteOffUnblocksCancelTest is Base {
    uint256 internal constant DUST = 1e10;            // CONSERVATION_DUST (private in src)
    uint256 internal constant ATTRIBUTED_SLOT = 38;   // `_interestAttributed`, storage layout
    bytes32 internal constant GUARDIAN = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant LIQUIDATED_SIG =
        keccak256("Liquidated(address,address,uint256,uint256,uint256,uint256,uint256)");

    uint256 internal constant A = 10_000e18;
    uint256 internal constant BRW = 4_000e18;
    uint256 internal constant B = 1_000e18;
    uint256 internal constant YRS = 150;
    uint256 internal constant EMISSION = 1_000_000e18;

    address internal dave = address(0x5);

    // ── fixture ──────────────────────────────────────────────────────────────────────────
    /// @dev alice (and optionally dave) borrow against their stake, bob is a pure staker, then the
    ///      book sits untouched for `yrs` years and the guardian declares an emergency (which
    ///      charges the interest up to the halt).
    function _dormantBook(uint256 yrs, bool twoBorrowers) internal {
        vm.prank(alice); staking.deposit(A, 90);
        vm.prank(bob);   staking.deposit(B, 90);
        if (twoBorrowers) { _fund(dave); vm.prank(dave); staking.deposit(A, 90); }
        vm.roll(block.number + 11);
        vm.prank(alice); staking.borrow(BRW);
        if (twoBorrowers) { vm.prank(dave); staking.borrow(BRW); }
        vm.warp(block.timestamp + yrs * 365 days);
        vm.roll(block.number + 1);
        vm.prank(admin); staking.grantRole(GUARDIAN, keeper);
        vm.prank(keeper); staking.declareEmergency();
    }

    function _ledgerSum() internal view returns (uint256) {
        return staking.totalStaked() + staking.rewardReserve() + staking.protocolReserve();
    }

    function _gap() internal view returns (uint256) {
        uint256 o = staking.owed();
        uint256 b = staking.backing();
        return o > b ? o - b : 0;
    }

    function _pos(address who) internal view returns (uint256 staked, uint256 debt) {
        (staked, debt,,,,,,,,,,,,) = staking.getUserInfo(who);
    }

    function _absorbAll() internal {
        if (staking.totalBadDebt() > 0) { vm.prank(carol); staking.absorbBadDebt(type(uint256).max); }
        assertEq(staking.totalBadDebt(), 0, "recorded bad debt not fully absorbed");
    }

    /// @dev Stake ledger, exact: sum(u.staked) + stakedOverdraw + attributed == totalStaked + global.
    function _assertStakeLedger(address[] memory who) internal view {
        uint256 sum;
        for (uint256 i = 0; i < who.length; i++) { (uint256 s,) = _pos(who[i]); sum += s; }
        uint256 attributed = uint256(vm.load(address(staking), bytes32(ATTRIBUTED_SLOT)));
        assertEq(sum + staking.stakedOverdraw() + attributed,
            staking.totalStaked() + staking.totalInterestAccruedGlobal(), "stake ledger does not close");
    }

    function _assertFlooredBreach() internal view {
        assertTrue(staking.emergencyMode(), "not in emergency");
        assertLt(_ledgerSum(), staking.totalDebt(), "ledger not floored");
        assertGt(_gap(), staking.totalBadDebt() + DUST, "gap within recorded bad debt + dust");
    }

    function _cancelPasses() internal {
        vm.prank(admin); staking.cancelEmergency();
        assertFalse(staking.emergencyMode(), "emergency not cancelled");
    }

    // ── the recording path ─────────────────────────────────────────────────────────────────
    /// @notice Record every loss with the permissionless sync, absorb the recorded bad debt, and the
    ///         emergency cancels: the remainder that the floor hid is now recorded.
    function test_writeOff_floored_absorbAll_cancelPasses() public {
        _dormantBook(YRS, false);
        _assertFlooredBreach();
        staking.syncEquity(alice);
        staking.syncEquity(bob);
        _absorbAll();
        _cancelPasses();
        assertGe(_ledgerSum(), staking.totalDebt(), "ledger still floored");
        assertTrue(staking.isSolvent(), "breached after the cancel");
    }

    /// @notice The write-off closes the underwater position and records its whole loss: the debt
    ///         leaves the book, the borrower registry empties, the stake ledger closes exactly, and
    ///         the pure staker's stake does not move.
    function test_writeOff_recordsTheWholeLoss() public {
        _dormantBook(YRS, false);
        staking.syncEquity(bob);
        (uint256 bobStaked,) = _pos(bob);
        staking.syncEquity(alice);
        (uint256 s, uint256 d) = _pos(alice);
        assertEq(s, 0, "stake left on a written-off position");
        assertEq(d, 0, "debt left on a written-off position");
        assertEq(staking.totalDebt(), 0, "written-off debt still in totalDebt");
        assertEq(staking.activeBorrowerCount(), 0, "written-off borrower still registered");
        (uint256 bobAfter,) = _pos(bob);
        assertEq(bobAfter, bobStaked, "write-off moved a third party's stake");
        address[] memory who = new address[](2); who[0] = alice; who[1] = bob;
        _assertStakeLedger(who);
        // A second sync of the closed position is harmless.
        staking.syncEquity(alice);
        assertEq(staking.totalDebt(), 0, "second sync moved the book");
    }

    /// @notice Second path: the write-off leaves the book exactly where the borrower's own
    ///         emergency exit leaves it (both book the same loss, neither pays her anything).
    function test_writeOff_equalsBorrowerOwnExit() public {
        _dormantBook(YRS, false);
        _assertWriteOffEqualsOwnExit();
    }

    /// @notice The same comparison with emission funded and a dormancy (60 years) that leaves the
    ///         stake below the debt but not eroded: attribution takes nothing from the protocol
    ///         reserve, so the reserve is there at the write-off and covers the shortfall first,
    ///         as in the borrower's own exit.
    function test_writeOff_reserveCovers_equalsBorrowerOwnExit() public {
        vm.prank(admin); staking.fundEmission(EMISSION);
        _dormantBook(60, false);
        uint256 r0 = staking.protocolReserve();
        assertGt(r0, 0, "no protocol reserve to cover with");
        _assertWriteOffEqualsOwnExit();
        assertLt(staking.protocolReserve(), r0, "the reserve covered nothing at the write-off");
    }

    /// @notice With emission funded, the write-off moves the closed position's stale-weight excess
    ///         back to the reserve; the trip anchor follows that move, so the cancel still passes.
    function test_writeOff_withEmission_absorbAll_cancelPasses() public {
        vm.prank(admin); staking.fundEmission(EMISSION);
        _dormantBook(YRS, false);
        staking.syncEquity(bob);
        uint256 d0 = staking.totalRewardDistributed();
        staking.syncEquity(alice);
        assertLt(staking.totalRewardDistributed(), d0, "the write-off moved no stale-weight excess");
        _absorbAll();
        _cancelPasses();
        assertTrue(staking.isSolvent(), "breached after the cancel");
    }

    function _assertWriteOffEqualsOwnExit() internal {
        staking.syncEquity(bob);
        uint256 snap = vm.snapshotState();
        vm.prank(alice); staking.emergencyWithdraw();
        uint256[7] memory exitBook = [staking.totalStaked(), staking.totalDebt(), staking.totalBadDebt(),
            staking.protocolReserve(), staking.rewardReserve(), staking.owed(), staking.backing()];
        uint256 aliceBal = token.balanceOf(alice);
        vm.revertToState(snap);
        staking.syncEquity(alice);
        uint256[7] memory syncBook = [staking.totalStaked(), staking.totalDebt(), staking.totalBadDebt(),
            staking.protocolReserve(), staking.rewardReserve(), staking.owed(), staking.backing()];
        for (uint256 i = 0; i < 7; i++) assertEq(syncBook[i], exitBook[i], "write-off and own exit disagree");
        assertEq(token.balanceOf(alice), aliceBal, "the exit paid a position the write-off closed for nothing");
        // The closed position has nothing left to exit.
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoStake.selector);
        staking.emergencyWithdraw();
    }

    /// @notice A borrower whose stake is still above its debt is NOT written off: the sync only
    ///         attributes, the debt and the registry stay.
    function test_writeOff_skipsPositionAboveWater() public {
        _dormantBook(0, false);
        staking.syncEquity(alice);
        (uint256 s, uint256 d) = _pos(alice);
        assertEq(d, BRW, "debt of a position above water was erased");
        assertGt(s, d, "fixture: position not above water");
        assertEq(staking.totalDebt(), BRW, "totalDebt moved for a position above water");
        assertEq(staking.activeBorrowerCount(), 1, "borrower above water left the registry");
        assertEq(staking.totalBadDebt(), 0, "loss booked for a position above water");
        _cancelPasses();
    }

    /// @notice Two underwater borrowers: recording one leaves the other's loss hidden and the cancel
    ///         reverting; recording both lets it pass.
    function test_writeOff_twoBorrowers_eachMustBeRecorded() public {
        _dormantBook(YRS, true);
        staking.syncEquity(bob);
        staking.syncEquity(alice);
        _absorbAll();
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__InvariantBreached.selector);
        staking.cancelEmergency();
        staking.syncEquity(dave);
        _absorbAll();
        address[] memory who = new address[](3); who[0] = alice; who[1] = bob; who[2] = dave;
        _assertStakeLedger(who);
        _cancelPasses();
    }

    /// @notice Range: dormancy 0-300 years. Every write-off closes a position whose stake did not
    ///         exceed its debt, with no bonus and no leftover; every kept position is above water; and
    ///         after recording and absorbing everything the emergency cancels.
    function testFuzz_writeOff_onlyUnderwater_thenCancelPasses(uint256 yrs) public {
        yrs = bound(yrs, 0, 300);
        _dormantBook(yrs, false);
        staking.syncEquity(bob);
        vm.recordLogs();
        staking.syncEquity(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 s, uint256 d) = _pos(alice);
        if (d != 0) assertGt(s, d, "kept a position at or below water");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != LIQUIDATED_SIG) continue;
            (uint256 seized, uint256 debt, uint256 bonus, uint256 leftover,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            assertLe(seized, debt, "wrote off a position above water");
            assertEq(bonus, 0, "write-off paid a bonus");
            assertEq(leftover, 0, "write-off left a stake behind");
            assertEq(d, 0, "event without the write-off");
        }
        address[] memory who = new address[](2); who[0] = alice; who[1] = bob;
        _assertStakeLedger(who);
        _absorbAll();
        _cancelPasses();
    }

    // ── the other paths that unblock (unchanged by the fix) ───────────────────────────────
    /// @notice Admin `fundEmission` of the gap closes it while the ledger stays floored.
    function test_floored_fundEmission_unblocksCancel() public {
        _dormantBook(YRS, false);
        _assertFlooredBreach();
        uint256 g = _gap();
        vm.prank(admin); staking.fundEmission(g);
        assertTrue(staking.isSolvent(), "still breached after fundEmission(gap)");
        _cancelPasses();
    }

    /// @notice A plain transfer of the gap: backing is measured.
    function test_floored_donation_unblocksCancel() public {
        _dormantBook(YRS, false);
        _assertFlooredBreach();
        uint256 g = _gap();
        vm.prank(carol); token.transfer(address(staking), g);
        assertTrue(staking.isSolvent(), "still breached after donation(gap)");
        _cancelPasses();
    }

    /// @notice The borrower's own emergency exit records her loss; absorbing it lets the cancel pass.
    function test_floored_borrowerExit_thenAbsorb_unblocksCancel() public {
        _dormantBook(YRS, false);
        staking.syncEquity(bob);
        vm.prank(alice); staking.emergencyWithdraw();
        _absorbAll();
        assertGe(_ledgerSum(), staking.totalDebt(), "ledger still floored");
        assertTrue(staking.isSolvent(), "still breached");
        _cancelPasses();
    }

    /// @notice Control: a book that is not floored cancels after a discretionary halt.
    function test_control_notFloored_cancelPasses() public {
        _dormantBook(0, false);
        assertGe(_ledgerSum(), staking.totalDebt(), "control floored");
        _cancelPasses();
    }
}
