// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Foundry suite — unit + fuzz + invariant. NOT run in the cloud sandbox (no network to install
// Foundry); intended to be run on Termux / any machine with Foundry:
//
//   forge install foundry-rs/forge-std
//   forge test -vvv
//   forge test --match-contract Invariant -vvv
//
// The JS harness in test/run.mjs already exercises the same behaviours on a real EVM offline.

import {Test, StdInvariant} from "forge-std/Test.sol";
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

contract Base is Test {
    BlazePhoenixStaking staking;
    MockERC20 token;
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

    function setUp() public virtual {
        vm.warp(1_900_000_000);
        token = new MockERC20();
        vm.prank(admin);
        staking = new BlazePhoenixStaking(address(token), treasury);
        _fund(admin); _fund(alice); _fund(bob); _fund(carol); _fund(keeper);
    }
}

contract UnitTest is Base {
    function test_BoostCurve() public view {
        assertEq(staking.boostByDays(0), 10000);
        assertEq(staking.boostByDays(90), 10199);
        assertEq(staking.boostByDays(365), 11000);
        assertEq(staking.boostByDays(730), 12500);
        assertEq(staking.boostByDays(2555), 27500);
        assertEq(staking.boostByDays(99999), 27500);
    }

    function test_DepositRequiresValidLock() public {
        vm.startPrank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockTooShort.selector);
        staking.deposit(100e18, 89);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockTooLong.selector);
        staking.deposit(100e18, 2556);
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAmount.selector);
        staking.deposit(0, 90);
        staking.deposit(100e18, 90);
        vm.stopPrank();
        assertEq(staking.totalStaked(), 100e18);
    }

    function test_MandatoryLockBlocksWithdraw() public {
        vm.prank(alice); staking.deposit(1000e18, 90);
        vm.roll(block.number + 11);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__StillLocked.selector);
        staking.withdraw(100e18);
        vm.warp(block.timestamp + 91 days); vm.roll(block.number + 11);
        vm.prank(alice); staking.withdraw(1000e18);
        assertEq(staking.totalStaked(), 0);
    }

    function test_WithdrawRequiresRepayAll() public {
        vm.prank(alice); staking.deposit(1000e18, 90);
        vm.roll(block.number + 2);
        vm.prank(alice); staking.borrow(400e18);
        vm.warp(block.timestamp + 91 days); vm.roll(block.number + 11);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__HasDebt.selector);
        staking.withdraw(100e18);
        vm.prank(alice); staking.repay(1000e18);          // clears the ~400 debt
        assertEq(staking.totalDebt(), 0);
        vm.roll(block.number + 11);                        // flash guard after becoming pure staker
        (uint256 staked,,,,,,,,,,,,,) = staking.getUserInfo(alice);
        vm.prank(alice); staking.withdraw(staked);
        assertEq(staking.totalStaked(), 0);
    }

    function test_BorrowLTV() public {
        vm.prank(alice); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__LTVExceeded.selector);
        staking.borrow(501e18);
        vm.prank(alice); staking.borrow(500e18);
        assertEq(staking.totalDebt(), 500e18);
        assertTrue(staking.isTrackedBorrower(alice));
    }

    function test_TopUpExtendsOnly() public {
        vm.prank(alice); staking.deposit(100e18, 400);
        (, uint256 unlock1,,) = staking.lockInfoOf(alice);
        vm.roll(block.number + 11);
        vm.prank(alice); staking.deposit(100e18, 90);      // shorter -> keep
        (uint256 d2, uint256 unlock2,,) = staking.lockInfoOf(alice);
        assertEq(unlock2, unlock1); assertEq(d2, 400);
        vm.prank(alice); staking.deposit(100e18, 800);     // longer -> extend
        (uint256 d3, uint256 unlock3,,) = staking.lockInfoOf(alice);
        assertGt(unlock3, unlock1); assertEq(d3, 800);
    }

    function test_LiquidationClearsAndConserves() public {
        vm.prank(bob); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(bob); staking.borrow(500e18);
        vm.warp(block.timestamp + 80 * 365 days); vm.roll(block.number + 2);
        vm.prank(keeper); staking.liquidate(bob);
        (, uint256 debt,,,,,,,,,,,,) = staking.getUserInfo(bob);
        assertEq(debt, 0);
        assertFalse(staking.isTrackedBorrower(bob));
        assertEq(staking.totalLiquidations(), 1);
        assertTrue(staking.isSolvent());
        assertEq(staking.auditInvariants() & 1, 0);
    }

    function test_AutonomousMaintenance() public {
        vm.prank(bob); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(bob); staking.borrow(500e18);
        vm.warp(block.timestamp + 80 * 365 days); vm.roll(block.number + 2);
        assertTrue(staking.isTrackedBorrower(bob));
        vm.prank(carol); staking.claimRewards();           // carol's unrelated tx sweeps bob
        assertFalse(staking.isTrackedBorrower(bob));
        assertGe(staking.totalAutoLiquidations(), 1);
        assertTrue(staking.isSolvent());
    }

    function test_EmissionClaimAndNoBacklog() public {
        vm.prank(admin); staking.fundEmission(10_000_000e18);
        // a full year with no stakers must NOT be captured by a latecomer
        vm.warp(block.timestamp + 365 days); vm.roll(block.number + 2);
        vm.prank(alice); staking.deposit(1_000_000e18, 365);
        vm.roll(block.number + 2);
        assertEq(staking.pendingRewards(alice), 0);
        vm.warp(block.timestamp + 30 days); vm.roll(block.number + 2);
        assertGt(staking.pendingRewards(alice), 0);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice); staking.claimRewards();
        assertGt(token.balanceOf(alice), before);
        assertTrue(staking.isSolvent());
    }

    function test_TripBreakerOnlyOnInsolvency() public {
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__NoBreach.selector);
        staking.tripBreaker();
    }

    function test_Emergency() public {
        vm.prank(admin); staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(alice); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);
        vm.prank(alice); staking.borrow(300e18);
        vm.prank(keeper); staking.declareEmergency();
        assertTrue(staking.emergencyMode());
        uint256 before = token.balanceOf(alice);
        vm.prank(alice); staking.emergencyWithdraw();
        assertEq(token.balanceOf(alice) - before, 700e18);  // net equity = staked - debt
    }
}

// ───────────────────────────────────────────────────────────────────────────────────────────
//  INVARIANT SUITE — the heart of the integrity guarantee under random action sequences.
// ───────────────────────────────────────────────────────────────────────────────────────────
contract Handler is Test {
    BlazePhoenixStaking public staking;
    MockERC20 public token;
    address[] public actors;

    constructor(BlazePhoenixStaking s, MockERC20 t, address[] memory a) {
        staking = s; token = t; actors = a;
    }
    function _actor(uint256 seed) internal view returns (address) { return actors[seed % actors.length]; }

    function deposit(uint256 seed, uint256 amt, uint256 lockDays) public {
        address a = _actor(seed);
        amt = bound(amt, 1e18, 5_000_000e18);
        lockDays = bound(lockDays, 90, 2555);
        vm.prank(a); try staking.deposit(amt, lockDays) {} catch {}
    }
    function borrow(uint256 seed, uint256 amt) public {
        address a = _actor(seed);
        amt = bound(amt, 1e18, 3_000_000e18);
        vm.prank(a); try staking.borrow(amt) {} catch {}
    }
    function repay(uint256 seed, uint256 amt) public {
        address a = _actor(seed);
        amt = bound(amt, 1e18, 5_000_000e18);
        vm.prank(a); try staking.repay(amt) {} catch {}
    }
    function withdraw(uint256 seed, uint256 amt) public {
        address a = _actor(seed);
        amt = bound(amt, 1e18, 5_000_000e18);
        vm.prank(a); try staking.withdraw(amt) {} catch {}
    }
    function claim(uint256 seed) public { address a = _actor(seed); vm.prank(a); try staking.claimRewards() {} catch {} }
    function liquidate(uint256 seed, uint256 tseed) public {
        vm.prank(_actor(seed)); try staking.liquidate(_actor(tseed)) {} catch {}
    }
    function passTime(uint256 s) public {
        s = bound(s, 1 hours, 60 days);
        vm.warp(block.timestamp + s); vm.roll(block.number + 30);
    }
}

contract InvariantTest is StdInvariant, Base {
    Handler handler;

    function setUp() public override {
        super.setUp();
        vm.prank(admin); staking.fundEmission(50_000_000e18);
        address[] memory actors = new address[](4);
        actors[0] = alice; actors[1] = bob; actors[2] = carol; actors[3] = keeper;
        handler = new Handler(staking, token, actors);
        // let the handler act as each actor (they already approved staking; approve handler-routed prank txs)
        targetContract(address(handler));
    }

    /// The protocol must always hold at least what it owes.
    function invariant_solvent() public view {
        assertTrue(staking.isSolvent(), "INSOLVENT");
    }
    /// The on-chain conservation bit must never be set.
    function invariant_conservationBit() public view {
        assertEq(staking.auditInvariants() & 1, 0, "CONSERVATION BIT");
    }
    /// Boosted denominators may never exceed stake * maxBoost / base.
    function invariant_boostBounded() public view {
        assertEq(staking.auditInvariants() & (1 << 4), 0, "BOOST UNBOUNDED");
    }
    /// Backing covers owed within the dust tolerance.
    function invariant_backingCoversOwed() public view {
        assertGe(staking.backing() + 1e10, staking.owed(), "BACKING < OWED");
    }
}
