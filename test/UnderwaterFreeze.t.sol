// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

// Recovered from adversarial audit workflow wf_8e3fd5d8 (2026-08-18) and re-derived
// against the real contract on recovery.
//
// CapitalConservation.t.sol shows the invariant HOLDS with a 25M whale vs a 1000e18
// borrower (utilisation ~0%, rate at its floor). The contract's own comment (~L1331)
// warns the "next checked `totalStaked -= amount_` (withdraw) hits" once the eager global
// slice erodes totalStaked below a healthy staker's still-intact u.staked. This test builds
// the OPPOSITE ratio the existing suite explicitly does not cover: a small healthy saver
// (debt==0, so eligible to withdraw) alongside borrowers who dominate utilisation and, over
// a decade with no maintenance, drive the global slice to erode totalStaked below the saver's
// stake. The saver's withdraw then underflows with Panic 0x11 — funds locked, not lost.
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

contract UnderwaterFreezeTest is Test {
    BlazePhoenixStaking st;
    MockBZPX tok;
    address admin = address(0xA11CE);
    address treasury = address(0x713A5);
    address saver = makeAddr("saver"); // healthy, no debt -> eligible to withdraw

    uint256 constant N = 6;
    address[N] bs;

    function setUp() public {
        vm.warp(1_900_000_000);
        tok = new MockBZPX();
        vm.prank(admin);
        st = new BlazePhoenixStaking(address(tok), treasury);
        // Mirror CapitalConservation's working funding: mint + approve admin, saver, borrowers.
        address[] memory who = new address[](N + 2);
        who[0] = admin; who[1] = saver;
        for (uint256 i; i < N; ++i) who[i + 2] = bs[i] = makeAddr(string(abi.encodePacked("b", i)));
        for (uint256 i; i < who.length; ++i) {
            tok.mint(who[i], 100_000_000e18);
            vm.prank(who[i]); tok.approve(address(st), type(uint256).max);
        }
    }

    function _sumStakes() internal view returns (uint256 s) {
        (uint256 sv,,,,,,,,,,,,,) = st.getUserInfo(saver); s += sv;
        for (uint256 i; i < N; ++i) { (uint256 st_,,,,,,,,,,,,,) = st.getUserInfo(bs[i]); s += st_; }
    }

    // Panic(uint256) selector 0x4e487b71 with code 0x11 == checked arithmetic under/overflow.
    function _isPanic11(bytes memory r) internal pure returns (bool) {
        if (r.length < 36) return false;
        bytes4 sel; uint256 code;
        assembly { sel := mload(add(r, 0x20)) code := mload(add(r, 0x24)) }
        return sel == 0x4e487b71 && code == 0x11;
    }

    function test_HealthySaverWithdraw_FreezesOnDriftUnderflow() public {
        uint256 t = block.timestamp;

        // Small healthy saver, no lock, no borrow -> withdraw-eligible after the flash-loan window.
        vm.prank(saver); st.deposit(1_000e18, 0);

        // Borrowers dominate utilisation; no large healthy staker suppresses the rate.
        for (uint256 i; i < N; ++i) { vm.prank(bs[i]); st.deposit(1_000e18, 90); }
        t += 100; vm.warp(t); vm.roll(block.number + 20);
        for (uint256 i; i < N; ++i) {
            (,, , uint256 maxB,,,,,,,,,,) = st.getUserInfo(bs[i]);
            if (maxB > 0) { vm.prank(bs[i]); st.borrow(maxB); }
        }

        // Freeze autonomous maintenance so no position is swept, then let a decade of steep-rate
        // interest run. The global slice (capped at totalStaked) erodes the aggregate; the saver's
        // u.staked is never touched (debt==0 -> no per-user interest), so it stays at 1_000e18.
        bytes32 guardian = keccak256("GUARDIAN_ROLE");
        vm.prank(admin); st.grantRole(guardian, admin);
        vm.prank(admin); st.pause();
        t += 3650 days; vm.warp(t);
        vm.prank(admin); st.unpause();
        vm.roll(block.number + 20);

        uint256 total = st.totalStaked();
        uint256 sum = _sumStakes();
        console2.log("sum(u.staked):", sum);
        console2.log("totalStaked  :", total);
        console2.log("uncollected  :", st.solvency().totalUncollectedInterest);
        if (sum > total) console2.log(">>> totalStaked BELOW sum by:", sum - total);

        // RED-FIRST: the healthy saver must be able to withdraw its intact stake. Present code:
        // `totalStaked -= amount_` (L725) underflows because the eager global slice drove
        // totalStaked below the saver's u.staked -> Panic 0x11, funds frozen. After a fix that
        // keeps totalStaked == sum(u.staked): withdraw succeeds.
        bool underflowed;
        vm.prank(saver);
        try st.withdraw(1_000e18) { underflowed = false; }
        catch (bytes memory r) { underflowed = _isPanic11(r); if (underflowed) console2.log(">>> withdraw underflowed (Panic 0x11)"); }

        assertFalse(underflowed, "healthy saver withdraw underflowed on totalStaked (Panic 0x11) - eager/lazy drift freeze");
    }
}
