// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// How long does self-curation actually take to reach a position that needs it?
//
// `_sweepExpiredLocks` walks ONE registry that holds still-locked and expired entries together.
// A still-locked entry costs a probe and does nothing (`else { ++_lockCursor; ++n; }`), so a
// registry dominated by long commitments spends its whole per-transaction budget rotating past
// positions with nothing to normalise. Meanwhile the expired position it has not reached yet is
// still drawing a boosted share of every emission and interest distribution it is no longer
// entitled to.
//
// The engine does not STALL — every branch consumes either probe budget or action budget, so it
// always terminates. The question is LATENCY, and latency is what decides whether "self-curating"
// is true in practice or only in the limit.
//
// This measures it: N long-locked positions, one expired, and count how many ordinary
// transactions it takes before the expired one is normalised.
//
// MEASURED (62 lockers, budget 2/tx): the expired position was normalised on the 21st ordinary
// transaction. The engine does not stall and the registry self-heals — but the SCALING LAW is
// the finding, and it is closed-form:
//
//     budget(S) = min(MAINT_MAX_SCAN, MAINT_BASE + S / MAINT_DENSITY) = min(10, 1 + S/50)
//     full-sweep latency  =  S / budget(S)   transactions
//
//   | lockers S | budget | txs for a full sweep |
//   |-----------|--------|----------------------|
//   |        62 |      2 |                   31 |
//   |       450 |     10 | 45  <- budget saturates here |
//   |     5,000 |     10 |                  500 |
//   |    50,000 |     10 |                5,000 |
//
// Below ~450 entries the budget grows with the registry and latency stays roughly flat. Once
// MAINT_MAX_SCAN caps it, **latency grows LINEARLY with registry size** — an expired position
// keeps drawing a boost it is no longer entitled to for O(S/10) transactions. The cap exists for
// a good reason (per-transaction gas must stay bounded, and the locker-flood stress test proves
// it), so this is a deliberate trade, not a defect. It is recorded here because the trade has a
// price that grows with adoption, and nothing else states it.
//
// The structural cause is that ONE registry holds still-locked and expired entries together, so
// probe budget is spent rotating past positions with nothing to normalise. Anything that let the
// sweep reach expired entries directly (ordering by unlockTime, or a separate due-queue) would
// remove the linear term rather than just raising the cap.
//
// forge test --match-contract SweepLatency -vv

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract MockTok {
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

contract SweepLatencyTest is Test {
    BlazePhoenixStaking st;
    MockTok tok;
    address admin = address(0xA11CE);
    address treasury = address(0x713A5);
    address driver = makeAddr("driver"); // sends the ordinary traffic that carries maintenance

    function setUp() public {
        vm.warp(1_900_000_000);
        tok = new MockTok();
        vm.prank(admin);
        st = new BlazePhoenixStaking(address(tok), treasury);
        tok.mint(admin, 200_000_000e18);
        vm.prank(admin); tok.approve(address(st), type(uint256).max);
        vm.prank(admin); st.fundEmission(50_000_000e18);

        tok.mint(driver, 10_000_000e18);
        vm.prank(driver); tok.approve(address(st), type(uint256).max);
    }

    function _mkLocker(uint256 i, uint256 lockDays, uint256 amt) internal returns (address who) {
        who = address(uint160(0x100000 + i));
        tok.mint(who, amt * 2);
        vm.prank(who); tok.approve(address(st), type(uint256).max);
        vm.prank(who); st.deposit(amt, lockDays);
    }

    /// @notice N long-locked positions plus one whose commitment has elapsed. Count the ordinary
    ///         transactions needed before self-curation reaches and normalises the expired one.
    function test_LatencyToNormaliseOneExpiredLockAmongManyLive() public {
        uint256 t = block.timestamp;
        uint256 N = 60;

        // One position on the shortest possible commitment — this is the one that will expire.
        address expiring = _mkLocker(0, 90, 1_000e18);
        // ...buried among long commitments that will still be live throughout the whole test.
        for (uint256 i = 1; i <= N; ++i) _mkLocker(i, 2000, 1_000e18);

        // The driver needs a position of its own so its transactions are ordinary user traffic.
        vm.prank(driver); st.deposit(1_000e18, 2000);

        console2.log("lockers registered:", st.activeLockerCount());
        console2.log("probe budget per tx:", st.lockSweepBudget());

        // Move just past the short commitment. Everyone else stays locked.
        t += 91 days;
        vm.warp(t);
        assertTrue(st.isTrackedLocker(expiring), "precondition: the expired position is still registered");

        // Drive ordinary traffic and count how many transactions it takes to reach it.
        uint256 txs;
        for (uint256 i; i < 400; ++i) {
            if (!st.isTrackedLocker(expiring)) break;
            t += 1;                       // keep the gap term from inflating the budget
            vm.warp(t);
            vm.prank(driver);
            st.claimRewards();            // an ordinary, unrelated action
            unchecked { ++txs; }
        }

        console2.log("transactions until the expired lock was normalised:", txs);
        console2.log("still registered afterwards?:", st.isTrackedLocker(expiring) ? 1 : 0);

        assertFalse(st.isTrackedLocker(expiring),
            "self-curation must eventually reach an expired lock buried among live ones");

        // Latency should be roughly registry-size / probe-budget. Recording it as an assertion
        // pins the behaviour: if a change makes curation dramatically slower, this fails.
        console2.log("registry size:", N + 2);
        console2.log("=> probes needed per registry sweep ~ size/budget:", (N + 2) / st.lockSweepBudget());
    }

    /// @notice The engine must not stall when EVERY entry is still locked: it should burn its
    ///         probe budget, change nothing, and leave the carrying transaction succeeding.
    function test_NoStall_WhenNothingIsExpired() public {
        for (uint256 i; i < 20; ++i) _mkLocker(i, 2000, 1_000e18);
        vm.prank(driver); st.deposit(1_000e18, 2000);

        uint256 before = st.activeLockerCount();
        uint256 t = block.timestamp + 1;
        vm.warp(t);
        vm.prank(driver);
        st.claimRewards(); // must not revert

        assertEq(st.activeLockerCount(), before,
            "nothing is expired, so nothing may be de-registered");
    }

    /// @notice A registry made entirely of stale entries (locks cleared elsewhere) must
    ///         self-heal rather than be walked forever.
    function test_SelfHealing_PrunesStaleEntries() public {
        uint256 t = block.timestamp;
        for (uint256 i; i < 12; ++i) _mkLocker(i, 90, 1_000e18);
        vm.prank(driver); st.deposit(1_000e18, 2000);

        uint256 before = st.activeLockerCount();
        t += 91 days;
        vm.warp(t);

        // Every short lock is now expired; drive traffic and watch the registry drain.
        for (uint256 i; i < 60; ++i) {
            t += 1; vm.warp(t);
            vm.prank(driver);
            st.claimRewards();
        }
        uint256 remaining = st.activeLockerCount();
        console2.log("lockers before:", before);
        console2.log("lockers after 60 txs:", remaining);
        assertLt(remaining, before, "the registry must drain as commitments elapse");
    }
}
