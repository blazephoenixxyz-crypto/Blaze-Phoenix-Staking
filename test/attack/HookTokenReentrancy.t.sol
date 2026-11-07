// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice ERC777-like token: a hook fires on the PULL side (transferFrom, before the balance moves,
///         like tokensToSend) and on the PUSH side (transfer, after it moves, like tokensReceived),
///         and re-enters every external door of the staking contract from inside the transfer.
contract HookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public victim;
    address public watched;
    bool public armed;
    bytes[] internal _calls;
    bytes4[] public got;   // revert selector of each re-entry, in order; 0xffffffff = it succeeded

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function arm(address v, address w, bytes[] memory calls) external {
        victim = v; watched = w; armed = true;
        delete _calls;
        for (uint256 i = 0; i < calls.length; i++) _calls.push(calls[i]);
        delete got;
    }
    function gotLength() external view returns (uint256) { return got.length; }

    function _hook() internal {
        if (!armed) return;
        armed = false; // one round per transfer
        for (uint256 i = 0; i < _calls.length; i++) {
            (bool ok, bytes memory ret) = victim.call(_calls[i]);
            got.push(ok ? bytes4(0xffffffff) : (ret.length >= 4 ? bytes4(ret) : bytes4(0)));
        }
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a;
        if (to == watched) _hook();
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        if (from == watched) _hook();
        allowance[from][msg.sender] -= a;
        balanceOf[from] -= a; balanceOf[to] += a;
        return true;
    }
}

contract HookTokenReentrancyTest is Test {
    HookToken token;
    BlazePhoenixStaking staking;
    address admin = address(0xA11CE);
    address treasury = address(0x713A5);
    address alice = address(0x1);
    bytes4 constant RE = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    function setUp() public {
        vm.warp(1_900_000_000);
        token = new HookToken();
        vm.prank(admin);
        staking = new BlazePhoenixStaking(address(token), treasury);
        token.mint(admin, 90_000_000e18); token.mint(alice, 10_000_000e18);
        vm.prank(admin); token.approve(address(staking), type(uint256).max);
        vm.prank(alice); token.approve(address(staking), type(uint256).max);
        vm.prank(admin); staking.fundEmission(90_000_000e18);
    }

    function _doors() internal view returns (bytes[] memory c) {
        c = new bytes[](10);
        c[0] = abi.encodeCall(staking.deposit, (1_000e18, 90));
        c[1] = abi.encodeCall(staking.withdraw, (1));
        c[2] = abi.encodeCall(staking.claimRewards, ());
        c[3] = abi.encodeCall(staking.claimPureYield, ());
        c[4] = abi.encodeCall(staking.borrow, (1));
        c[5] = abi.encodeCall(staking.repay, (1));
        c[6] = abi.encodeCall(staking.liquidate, (alice));
        c[7] = abi.encodeCall(staking.pokeExpiredLock, (alice));
        c[8] = abi.encodeCall(staking.emergencyWithdraw, ());
        c[9] = abi.encodeCall(staking.tripBreaker, ());
    }

    /// Every nonReentrant door refuses by the guard's selector; the breaker reads the book
    /// mid-transfer as sound (Staking__NoBreach), on both the pull and the push side.
    function _check(string memory side) internal view {
        assertEq(token.gotLength(), 10, string.concat(side, ": the hook did not fire"));
        for (uint256 i = 0; i < 9; i++) {
            assertEq(token.got(i), RE, string.concat("ATK-REENTRY: a door re-entered from the hook, ", side));
        }
        assertEq(token.got(9), BlazePhoenixStaking.Staking__NoBreach.selector,
            string.concat("ATK-REENTRY: mid-transfer book read as breached, ", side));
    }

    function test_ATK_REENTRY_hookTokenCannotReenterAnyDoor() public {
        // via_ir caches block.number / block.timestamp: the clock is carried in locals
        uint256 bn = block.number;
        uint256 t = block.timestamp;
        token.arm(address(staking), alice, _doors());
        vm.prank(alice); staking.deposit(1_000_000e18, 90);          // pull
        _check("deposit pull");
        bn += 11; t += 7 days; vm.roll(bn); vm.warp(t);
        token.arm(address(staking), alice, _doors());
        vm.prank(alice); staking.claimRewards();                      // push
        _check("claim push");
        vm.prank(alice); staking.borrow(100_000e18);
        bn += 11; t += 1 days; vm.roll(bn); vm.warp(t);
        token.arm(address(staking), alice, _doors());
        vm.prank(alice); staking.repay(200_000e18);                   // pull
        _check("repay pull");
        bn += 11; t += 91 days; vm.roll(bn); vm.warp(t);
        token.arm(address(staking), alice, _doors());
        vm.prank(alice); staking.withdraw(500_000e18);                // push
        _check("withdraw push");
    }
}
