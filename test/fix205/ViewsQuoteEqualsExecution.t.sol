// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// =============================================================================
//  REGRESSION TESTS — a public view must quote what the executing function will do.
//
//  Each test reads a view, then runs the function the view describes in the
//  SAME block, and requires the two to agree. They failed before the fixes
//  because the views read stored state while the executors first run accrual
//  and extra caps.
//
//  Toolchain note: this forge build can reuse the result of a textually
//  repeated call site (warp, roll or the same external view called twice in one
//  function). Every test here warps once and rolls once, and any view read
//  twice is read the second time through an external helper on this contract
//  (`readViews`, `readMaxBorrow`), so the two reads are distinct call sites.
// =============================================================================

import {console2} from "forge-std/console2.sol";
import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

contract ViewsQuoteEqualsExecutionTest is Base {
    uint256 constant WAD = 1e18;

    // ── helpers ──────────────────────────────────────────────────────────────

    function _tryBorrow(address who, uint256 amount) internal returns (bool ok, bytes4 sel) {
        vm.prank(who);
        try staking.borrow(amount) {
            ok = true;
        } catch (bytes memory r) {
            if (r.length >= 4) {
                assembly { sel := mload(add(r, 32)) }
            }
        }
    }

    /// Second read of the health views, through a distinct external call site.
    function readViews(address who) external view returns (uint256 h, uint256 d) {
        h = staking.healthFactor(who);
        d = staking.daysToLiquidation(who);
    }

    /// Second read of maxBorrowOf, through a distinct external call site.
    function readMaxBorrow(address who) external view returns (uint256) {
        return staking.maxBorrowOf(who);
    }

    // ── MAXB-UTIL ────────────────────────────────────────────────────────────
    // Proves: maxBorrowOf (:1743) returns only the LTV headroom and omits the
    // aggregate utilisation ceiling borrow() enforces (:716-718,
    // MAX_PROTOCOL_UTIL_WAD = 0.75e18).
    // Oracle: borrow() itself. If maxBorrowOf quotes m > 0, borrow(m) must succeed.
    // State: a single borrower at the 50% LTV cap cannot lift the book past 50%
    // utilisation by borrowing, so the book is pushed to ~74.6% by interest
    // erosion (interest debits stake, debt stays). One long warp, then the
    // borrower touches its own position so the index is realised; alice is a
    // small debt-free depositor with full LTV headroom and no pending interest,
    // which isolates this item from MAXB-INT.
    function test_MAXB_UTIL_maxBorrowOfIsBorrowableUnderAggregateCap() public {
        vm.prank(bob);   staking.deposit(1_000e18, 90);
        vm.prank(alice); staking.deposit(10e18, 90);
        vm.roll(block.number + 11);
        vm.prank(bob);   staking.borrow(500e18);           // bob at his LTV cap

        // util 500/1010 -> 347 bps; 7154 days of it debits ~340e18 from stake,
        // leaving the book just under the 75% ceiling (room ~2.45e18 < alice's 5e18).
        vm.warp(block.timestamp + 7154 days);
        vm.prank(bob);   staking.claimRewards();           // realise the index

        uint256 util = staking.utilizationRate();
        assertLt(util, 0.75e18, "precondition: book must sit just under the 75% ceiling");
        assertGt(util, 0.70e18, "precondition: book must be close to the 75% ceiling");

        uint256 m = staking.maxBorrowOf(alice);
        (, uint256 aliceDebt,,,,,,,,,,,,) = staking.getUserInfo(alice);
        assertEq(aliceDebt, 0, "precondition: alice is debt-free");

        (uint256 totalStaked_, uint256 totalDebt_) = (staking.totalStaked(), staking.totalDebt());
        uint256 utilRoom = totalStaked_ * 75 / 100 > totalDebt_ ? totalStaked_ * 75 / 100 - totalDebt_ : 0;
        console2.log("util (WAD)", util);
        console2.log("maxBorrowOf(alice)", m);
        console2.log("aggregate util room", utilRoom);

        if (m > 0) {
            (bool ok, bytes4 sel) = _tryBorrow(alice, m);
            if (!ok) console2.log("borrow(maxBorrowOf) reverted with UtilTooHigh:",
                sel == BlazePhoenixStaking.Staking__UtilTooHigh.selector);
            assertTrue(ok, "maxBorrowOf quoted an amount borrow() rejects under the aggregate utilisation cap");
        }
    }

    // ── MAXB-INT ─────────────────────────────────────────────────────────────
    // Proves: maxBorrowOf omits pending interest. borrow() runs
    // _accrueInterestFor (:705-712) before the LTV check, which lowers staked and
    // therefore the cap.
    // Oracle: borrow() itself, in the same block as the quote.
    // State: a large pure staker keeps aggregate utilisation near 0%, so only
    // the LTV cap can bind.
    function test_MAXB_INT_maxBorrowOfIncludesPendingInterest() public {
        vm.prank(carol); staking.deposit(100_000e18, 90);  // pure: keeps utilisation tiny
        vm.prank(alice); staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(alice); staking.borrow(100e18);           // well under the cap

        vm.warp(block.timestamp + 365 days);               // no touches

        uint256 m = staking.maxBorrowOf(alice);
        assertGt(m, 0, "precondition: alice has LTV headroom");
        console2.log("maxBorrowOf(alice) before accrual", m);

        (bool ok, bytes4 sel) = _tryBorrow(alice, m);
        if (!ok) {
            console2.log("borrow(maxBorrowOf) reverted with LTVExceeded:",
                sel == BlazePhoenixStaking.Staking__LTVExceeded.selector);
            // Measure the overstatement: realise alice's interest, re-quote.
            vm.prank(alice); staking.claimRewards();
            uint256 mAfter = this.readMaxBorrow(alice);
            console2.log("maxBorrowOf(alice) after accrual", mAfter);
            console2.log("overstatement (wei)", m > mAfter ? m - mAfter : 0);
        }
        assertTrue(ok, "maxBorrowOf quoted an amount borrow() rejects once pending interest is accrued");
    }

    // ── HF-INT (views move under a pure accrual) ─────────────────────────────
    // Proves: healthFactor (:1717 via _health :1692-1704) and daysToLiquidation
    // (:1720-1734) read stored staked without the pending interest.
    // Oracle: the same views after the position's own accrual-only touch
    // (claimRewards with no emission funded moves nothing but interest). The
    // economic state does not change in that touch, so neither view may move.
    function test_HF_INT_viewsDoNotMoveUnderAccrualOnlyTouch() public {
        vm.prank(carol); staking.deposit(100_000e18, 90);  // pure: keeps the rate flat
        vm.prank(alice); staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(alice); staking.borrow(400e18);

        vm.warp(block.timestamp + 3650 days);              // ten years, no touches

        uint256 h0 = staking.healthFactor(alice);
        uint256 d0 = staking.daysToLiquidation(alice);

        vm.prank(alice); staking.claimRewards();           // accrual only

        (uint256 h1, uint256 d1) = this.readViews(alice);
        console2.log("healthFactor before / after", h0, h1);
        console2.log("daysToLiquidation before / after", d0, d1);

        assertEq(h0, h1, "healthFactor moved under an accrual-only touch (ignores pending interest)");
        assertApproxEqAbs(d0, d1, 1, "daysToLiquidation moved under an accrual-only touch (ignores pending interest)");
    }

    // ── HF-INT (view says safe, enforcer liquidates) ─────────────────────────
    // Proves: the same omission flips the verdict. After a long untouched
    // interval the views still report a healthy position while liquidate()
    // — which accrues first (:920) — accepts it.
    // Oracle: liquidate() itself, called last, as in LiquidationViewAgreement.
    function test_HF_INT_viewsAgreeWithLiquidateAfterUntouchedInterval() public {
        vm.prank(alice); staking.deposit(1_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(alice); staking.borrow(500e18);           // 50% util -> 350 bps

        // 30 years at 350 bps on 500e18 is ~525e18 of interest: stake ~475e18,
        // past the 95% liquidation threshold (and below the debt).
        vm.warp(block.timestamp + 30 * 365 days);

        uint256 days_  = staking.daysToLiquidation(alice);
        uint256 health = staking.healthFactor(alice);
        console2.log("daysToLiquidation (view)", days_);
        console2.log("healthFactor (view)", health);

        bool enforcerAccepts;
        vm.prank(keeper);
        try staking.liquidate(alice) { enforcerAccepts = true; }
        catch { enforcerAccepts = false; }

        assertTrue(enforcerAccepts, "precondition: the enforcer must accept the position");
        assertEq(days_, 0, "daysToLiquidation reported a liquidatable position as safe (ignores pending interest)");
        assertEq(health, 0, "healthFactor reported positive health for a position under water once interest accrues");
    }

    // ── PEND-DISTRESS ────────────────────────────────────────────────────────
    // Proves: in terminal distress (slice > totalStaked) _updateInterestIndex
    // (:1387-1410) re-derives delta = floor(slice*WAD/debt) and then
    // slice = floor(debt*delta/WAD); _pendingPure (:1834-1847) only takes
    // min(slice, totalStaked). The two disagree by the floor dust.
    // Oracle: claimPureYield() in the same block, paid amount measured by the
    // token balance change (no emission is funded, so rewards pay 0).
    // State: the debt is chosen so that totalStaked*WAD mod debt is large
    // (1001e18 vs 499999999999999999251 -> 500 wei of re-derivation dust).
    function test_PEND_DISTRESS_pendingPureYieldEqualsClaimUnderClamp() public {
        vm.prank(bob);   staking.deposit(1_000e18, 90);
        vm.prank(carol); staking.deposit(1e18, 90);        // the only pure staker
        vm.roll(block.number + 11);
        vm.prank(bob);   staking.borrow(499_999_999_999_999_999_251);

        // ~349 bps for 100 years on ~500e18 is ~1745e18 > totalStaked = 1001e18: the clamp binds.
        vm.warp(block.timestamp + 100 * 365 days);

        uint256 quote = staking.pendingPureYield(carol);

        // In this book the projected pure yield (~971e18) exceeds the contract's cash
        // (1001e18 deposited - ~500e18 lent = ~501e18), so the claim would revert
        // Staking__TransferFailed before the comparison could be made. A plain token
        // donation supplies the cash; it touches no accounting variable (the
        // conservation check is delta-based) and pays nothing to carol by itself.
        token.mint(address(staking), 1_000e18);

        uint256 balBefore = token.balanceOf(carol);
        vm.prank(carol); staking.claimPureYield();
        uint256 paid = token.balanceOf(carol) - balBefore;

        console2.log("pendingPureYield(carol)", quote);
        console2.log("paid by claimPureYield", paid);
        console2.log("quote - paid (wei)", quote > paid ? quote - paid : 0);
        console2.log("paid - quote (wei)", paid > quote ? paid - quote : 0);

        assertGt(paid, 0, "precondition: the claim must pay interest");
        assertEq(quote, paid, "pendingPureYield did not equal what claimPureYield paid when the clamp binds");
    }
}
