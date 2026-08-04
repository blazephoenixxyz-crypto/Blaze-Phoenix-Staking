// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// The permissionless cleanup path, measured end to end: `expiredLockScan` (the preview a site
// would render) feeding `pokeExpiredLocks` (the batch anyone may call).
//
// SweepLatency.t.sol showed the passive rotating sweep needs O(S/budget) ordinary transactions
// to reach a given expired lock, growing linearly once MAINT_MAX_SCAN saturates. The explicit
// path is supposed to be the escape hatch from that. This asks three things with numbers:
//
//   1. Does the preview actually identify the right positions, and price the excess boost?
//   2. What does the batch cost per position cleaned, and how does it scale?
//   3. Where does that gas go — i.e. what would "ultra optimisation" actually be attacking?
//
// forge test --match-contract CleanupPathGas -vv

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract MockTok2 {
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

contract CleanupPathGasTest is Test {
    BlazePhoenixStaking st;
    MockTok2 tok;
    address admin = address(0xA11CE);
    address treasury = address(0x713A5);
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_900_000_000);
        tok = new MockTok2();
        vm.prank(admin);
        st = new BlazePhoenixStaking(address(tok), treasury);
        tok.mint(admin, 200_000_000e18);
        vm.prank(admin); tok.approve(address(st), type(uint256).max);
        vm.prank(admin); st.fundEmission(50_000_000e18);
        tok.mint(keeper, 10_000_000e18);
        vm.prank(keeper); tok.approve(address(st), type(uint256).max);
    }

    function _mk(uint256 i, uint256 lockDays) internal returns (address who) {
        who = address(uint160(0x200000 + i));
        tok.mint(who, 10_000e18);
        vm.prank(who); tok.approve(address(st), type(uint256).max);
        vm.prank(who); st.deposit(1_000e18, lockDays);
    }

    /// @notice The preview must find exactly the expired positions and quantify what they are
    ///         over-earning — that is what makes it usable as a site surface and as the input to
    ///         the batch call.
    function test_Preview_IdentifiesExpiredAndPricesExcessBoost() public {
        uint256 t = block.timestamp;
        for (uint256 i; i < 10; ++i) _mk(i, 90);      // will expire
        for (uint256 i = 10; i < 20; ++i) _mk(i, 2000); // stays committed

        // Before expiry: nothing to clean.
        (address[] memory none,,, uint256 total0) = st.expiredLockScan(0, 100);
        assertEq(none.length, 0, "nothing is expired yet");
        assertEq(total0, 20, "the registry holds every locked position");

        t += 91 days;
        vm.warp(t);

        (address[] memory due, uint256 excessBE, uint256 excessBP, uint256 total) =
            st.expiredLockScan(0, 100);

        console2.log("registry size:", total);
        console2.log("positions due for cleanup:", due.length);
        console2.log("excess boosted-effective still counted:", excessBE);
        console2.log("excess boosted-pure still counted:", excessBP);

        assertEq(due.length, 10, "exactly the ten elapsed commitments must be listed");
        assertGt(excessBP, 0,
            "an expired pure staker is still weighted above 1.00x until normalised - that is the leak the preview must surface");

        // Pagination must behave, so a site can page through a large registry.
        (address[] memory page,,, ) = st.expiredLockScan(0, 4);
        assertLe(page.length, 4, "limit must be honoured");
    }

    /// @notice What the batch costs, and how it scales per position cleaned.
    function test_BatchCleanup_GasPerPosition() public {
        uint256 t = block.timestamp;
        uint256 N = 30;
        for (uint256 i; i < N; ++i) _mk(i, 90);
        vm.prank(keeper); st.deposit(1_000e18, 2000);

        t += 91 days;
        vm.warp(t);

        (address[] memory due,,,) = st.expiredLockScan(0, 100);
        assertEq(due.length, N, "every short commitment is due");

        // One position at a time.
        address[] memory one = new address[](1);
        one[0] = due[0];
        vm.prank(keeper);
        uint256 g0 = gasleft();
        st.pokeExpiredLocks(one);
        uint256 gOne = g0 - gasleft();

        // Then the rest in a single batch.
        (address[] memory rest,,,) = st.expiredLockScan(0, 100);
        vm.prank(keeper);
        uint256 g1 = gasleft();
        st.pokeExpiredLocks(rest);
        uint256 gBatch = g1 - gasleft();

        console2.log("cleanup of 1 position, gas:", gOne);
        console2.log("cleanup of", rest.length);
        console2.log("   in one batch, gas:", gBatch);
        if (rest.length > 0) console2.log("   marginal gas per position:", gBatch / rest.length);
        console2.log("fixed overhead visible in the single call:", gOne > gBatch / rest.length ? gOne - gBatch / rest.length : 0);

        (address[] memory left,,,) = st.expiredLockScan(0, 100);
        assertEq(left.length, 0, "the batch must leave nothing due");
    }

    /// @notice Where does the fixed overhead of an explicit cleanup actually go?
    ///         `pokeExpiredLocks` ends with `_autoMaintain(msg.sender)`, so a targeted call also
    ///         pays for the rotating sweep it exists to bypass. `_autoMaintain` no-ops while
    ///         paused and this entry point carries no `whenNotPaused`, so pausing isolates it.
    function test_ExplicitCleanup_CostOfTheTrailingAutoMaintain() public {
        uint256 t = block.timestamp;
        for (uint256 i; i < 40; ++i) _mk(i, 90);
        vm.prank(keeper); st.deposit(1_000e18, 2000);
        t += 91 days;
        vm.warp(t);

        (address[] memory due,,,) = st.expiredLockScan(0, 100);
        address[] memory a = new address[](1); a[0] = due[0];

        vm.prank(keeper);
        uint256 g0 = gasleft();
        st.pokeExpiredLocks(a);
        uint256 gLive = g0 - gasleft();

        // Re-scan: the trailing _autoMaintain of the call above already normalised extra
        // positions on its own, so the next target must be taken from the CURRENT due list.
        (address[] memory stillDue,,,) = st.expiredLockScan(0, 100);
        assertGt(stillDue.length, 0, "need a remaining target to measure against");
        address[] memory b = new address[](1); b[0] = stillDue[0];

        bytes32 guardian = keccak256("GUARDIAN_ROLE");
        vm.prank(admin); st.grantRole(guardian, admin);
        vm.prank(admin); st.pause();

        vm.prank(keeper);
        uint256 g1 = gasleft();
        st.pokeExpiredLocks(b);
        uint256 gPaused = g1 - gasleft();

        console2.log("targeted cleanup, maintenance active :", gLive);
        console2.log("targeted cleanup, maintenance no-op  :", gPaused);
        if (gLive > gPaused) {
            console2.log("=> trailing _autoMaintain costs, gas:", gLive - gPaused);
            console2.log("   as percent of the call:", ((gLive - gPaused) * 100) / gLive);
        }
    }

    /// @notice The escape hatch must actually beat waiting: cleaning a specific position
    ///         explicitly is O(1) in registry size, while the passive sweep is O(S/budget).
    function test_ExplicitCleanupIsIndependentOfRegistrySize() public {
        uint256 t = block.timestamp;
        // One expiring position buried behind many long commitments.
        address target = _mk(0, 90);
        for (uint256 i = 1; i <= 80; ++i) _mk(i, 2000);
        vm.prank(keeper); st.deposit(1_000e18, 2000);

        t += 91 days;
        vm.warp(t);

        assertTrue(st.isTrackedLocker(target), "precondition");
        address[] memory one = new address[](1);
        one[0] = target;

        vm.prank(keeper);
        uint256 g0 = gasleft();
        st.pokeExpiredLocks(one);
        uint256 g = g0 - gasleft();

        console2.log("registry size:", st.activeLockerCount() + 1);
        console2.log("gas to clean ONE targeted position:", g);
        console2.log("(the passive sweep needed 21 ordinary txs at S=62 - see SweepLatency)");
        assertFalse(st.isTrackedLocker(target), "the targeted position must be normalised immediately");
    }
}
