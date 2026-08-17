// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
//
// Regression tests for the 2026-08-17 bounty wave (auditor_1b3f2c, siam siddik).
// Each asserts the CORRECT post-fix behaviour, so it fails on the pre-fix code
// (red-first) and passes once the fix lands.
//
//   forge test --match-contract Bounty2ndWave -vv
//
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract MockERC20 {
    string public name = "BlazePhoenix"; string public symbol = "BZPX"; uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
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

contract Bounty2ndWaveBase is Test {
    BlazePhoenixStaking staking;
    MockERC20 token;
    address admin    = address(0xA11CE);
    address treasury = address(0x713A5);
    address alice    = address(0x1);
    address bob      = address(0x2);
    address carol    = address(0x3);

    function _fund(address u) internal {
        token.mint(u, 500_000_000e18);
        vm.prank(u);
        token.approve(address(staking), type(uint256).max);
    }

    function setUp() public {
        vm.warp(1_900_000_000);
        token = new MockERC20();
        vm.prank(admin);
        staking = new BlazePhoenixStaking(address(token), treasury);
        _fund(admin); _fund(alice); _fund(bob); _fund(carol);
    }
}

contract Bounty2ndWave is Bounty2ndWaveBase {
    // BPX-2026-001: a 1-wei pure seat must NOT capture the borrower-interest pool.
    // Pre-fix alice banked ~33,853 BZPX; post-fix the throttle sends the slice to reserve.
    function test_BPX001_dustSeatThrottled() public {
        vm.prank(carol); staking.deposit(1_000_000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(carol); staking.borrow(500_000e18);

        vm.prank(alice); staking.deposit(1, 90);   // 1-wei dust seat, only pure staker

        vm.warp(block.timestamp + 730 days);
        vm.roll(block.number + 400);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice); staking.claimPureYield();
        uint256 paid = token.balanceOf(alice) - before;

        emit log_named_uint("alice paid (wei)", paid);
        emit log_named_uint("protocolReserve (BZPX)", staking.protocolReserve() / 1e18);

        assertLt(paid, 1e18, "dust seat must not capture meaningful interest (throttle)");
        assertGt(staking.protocolReserve(), 30_000e18, "throttled interest must bank to reserve");
        assertTrue(staking.isSolvent());
    }

    // Low (siam): pendingPureYield (quote) must equal claimPureYield (execution) to the wei,
    // even when the terminal-distress interest clamp binds. Pre-fix the quote overstated by 510 wei.
    function test_Low_quoteEqualsExecutionInTerminalDistress() public {
        vm.prank(bob);   staking.deposit(3000e18, 90);   // borrower
        vm.prank(alice); staking.deposit(500e18, 90);    // pure staker
        vm.roll(block.number + 20);
        vm.prank(bob);   staking.borrow(1500e18);

        // Bind the terminal-distress clamp: guardian pause + a long warp so the interest
        // slice exceeds totalStaked and _updateInterestIndex re-derives (C-03).
        vm.prank(admin); staking.grantRole(keccak256("GUARDIAN_ROLE"), admin);
        vm.prank(admin); staking.pause();

        vm.warp(block.timestamp + 150 * 365 days);
        vm.roll(block.number + 20);

        uint256 quoted = staking.pendingPureYield(alice);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice); staking.claimPureYield();
        uint256 actual = token.balanceOf(alice) - before;

        emit log_named_uint("quoted", quoted);
        emit log_named_uint("actual", actual);

        assertGt(quoted, 0, "quote must be non-trivial for the test to bite");
        assertEq(actual, quoted, "quote must equal execution to the wei");
        assertTrue(staking.isSolvent());
    }
}
