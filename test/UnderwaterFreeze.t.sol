// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

// Recovered from adversarial audit workflow wf_8e3fd5d8 (2026-08-18). Red-first
// assertions added on recovery: the original recovered PoC only logged; these
// encode the post-fix contract so the test is RED now and GREEN once the
// eager/lazy interest desync is reconciled.
contract MockBZPX {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
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

// PoC: with MULTIPLE underwater borrowers whose per-user interest is never individually
// accrued, the GLOBAL eager interest debit (`_updateInterestIndex`: totalStaked -= slice)
// erodes totalStaked far below the sum of collectible stakes, while the LAZY per-user
// bad-debt recognition (`_accrueInterestFor` C-03 add-back) has not run, so
// totalUncollectedInterest reads ZERO. In that window a checked `totalStaked -= seized`
// (liquidate) or `-= amount_` (withdraw) reverts with Panic 0x11 — freezing core paths.
contract UnderwaterFreezeTest is Test {
    BlazePhoenixStaking st;
    MockBZPX tok;
    address admin = address(0xA11CE);
    address treasury = address(0x713A5);

    uint256 constant N = 6;
    address[N] bs;

    function setUp() public {
        vm.warp(1_900_000_000);
        tok = new MockBZPX();
        vm.prank(admin);
        st = new BlazePhoenixStaking(address(tok), treasury);
        for (uint256 i; i < N; ++i) {
            bs[i] = makeAddr(string(abi.encodePacked("b", i)));
            tok.mint(bs[i], 100_000_000e18);
            vm.prank(bs[i]); tok.approve(address(st), type(uint256).max);
        }
        vm.prank(admin); st.fundEmission(50_000_000e18);
    }

    function _sumStakes() internal view returns (uint256 s) {
        for (uint256 i; i < N; ++i) { (uint256 st_,,,,,,,,,,,,,) = st.getUserInfo(bs[i]); s += st_; }
    }

    function test_MultiUnderwater_FreezesLiquidation() public {
        uint256 t = block.timestamp;

        // Many borrowers at max LTV, no large healthy staker -> util can climb into the steep
        // branch as interest erodes collateral, driving every position underwater together.
        for (uint256 i; i < N; ++i) {
            vm.prank(bs[i]); st.deposit(1_000e18, 90);
        }
        t += 100; vm.warp(t); vm.roll(block.number + 20);
        for (uint256 i; i < N; ++i) {
            (,, , uint256 maxB,,,,,,,,,,) = st.getUserInfo(bs[i]);
            vm.prank(bs[i]); st.borrow(maxB);
        }

        // Freeze autonomous maintenance so NO position is individually accrued/liquidated.
        bytes32 guardian = keccak256("GUARDIAN_ROLE");
        vm.prank(admin); st.grantRole(guardian, admin);
        vm.prank(admin); st.pause();

        t += 3650 days; vm.warp(t);
        vm.prank(admin); st.unpause();
        vm.roll(block.number + 20);

        uint256 total = st.totalStaked();
        uint256 sum = _sumStakes();
        uint256 uncollected = st.solvency().totalUncollectedInterest;
        console2.log("sum(u.staked):", sum);
        console2.log("totalStaked  :", total);
        console2.log("uncollected  :", uncollected);
        if (sum > total) console2.log(">>> totalStaked BELOW sum by:", sum - total);

        // RED-FIRST #1 (root): the conservation invariant the eager/lazy desync breaks.
        // Present code: totalStaked erodes below Sum(u.staked) -> FAILS here (this is the
        // desync that later underflows). After the fix (reconcile eager<->lazy): holds.
        assertGe(total, sum, "conservation: totalStaked must not fall below sum of stakes");

        // Now try to liquidate one position. `_executeLiquidation` does `totalStaked -= seized`
        // with seized ~ that position's stake. If totalStaked has been eroded below it, this
        // reverts with Panic 0x11 (checked underflow) rather than liquidating.
        bool liqReverted;
        vm.prank(bs[0]);
        try st.liquidate(bs[1]) { liqReverted = false; } catch { liqReverted = true; }
        console2.log("liquidate reverted:", liqReverted);

        // RED-FIRST #2 (impact): an underwater position must be liquidatable, not frozen by
        // a checked-math underflow. Present code: reverts -> FAILS. After the fix: executes.
        assertFalse(liqReverted, "liquidation froze (Panic 0x11 checked underflow) instead of executing");

        emit log_named_uint("final totalStaked", st.totalStaked());
    }
}
