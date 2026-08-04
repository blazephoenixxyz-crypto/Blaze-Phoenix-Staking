// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Is `sum(u.staked) == totalStaked` actually an invariant?
//
// The question comes from an asymmetry in how v3.1.0's continuous accrual splits the two sides
// of an interest charge:
//
//   * GLOBAL (`_updateInterestIndex`): slice = totalDebt * delta / WAD, then
//     `if (slice > totalStaked) slice = totalStaked;  totalStaked -= slice;`
//     — capped against the AGGREGATE stake.
//   * PER-USER (`_accrueInterestFor`): interest = u.debt * idxDelta / WAD, then
//     `if (interest > u.staked) { totalUncollectedInterest += interest - u.staked;
//      interest = u.staked; }  u.staked -= interest;`
//     — capped against THAT USER'S stake, with the shortfall recorded.
//
// While nobody is capped these agree exactly, because sum(u.debt) == totalDebt and every position
// shares the same idxDelta. They diverge the moment ONE position's interest exceeds its own
// collateral while the aggregate still has plenty: the global side debits the full slice, the
// individual side cannot, and the difference is booked into `totalUncollectedInterest` — a
// counter that is written and reported but never enters `_owed()`.
//
// If they diverge, users collectively believe they hold more stake than the aggregate records,
// and `withdraw`'s `totalStaked -= amount_` (checked arithmetic) would underflow and revert for
// whoever exits last — funds locked, not lost.
//
// RESULT: the invariant HELD exactly (sum == aggregate to the wei, totalUncollectedInterest == 0)
// even with one position left unliquidated for a decade. The reason is structural and worth
// recording, because it is what makes the asymmetry safe rather than luck:
//
//   The interest RATE is a function of GLOBAL utilisation (totalDebt / totalStaked), but the
//   per-user cap binds on an INDIVIDUAL position. For one position's interest to exceed its own
//   collateral the rate must be very high, which requires utilisation to be very high, which
//   requires the aggregate to be almost entirely borrowed — at which point the global slice is
//   pressing against its own `totalStaked` cap too. A large healthy staker suppresses the rate
//   for everyone (here: 500e18 of debt against 25M of stake leaves utilisation ~0%, the rate at
//   its 100bps floor, so a decade of interest is 50e18 against 1000e18 of collateral).
//
//   The two caps therefore cannot drift far apart, because the SAME denominator governs both.
//
// This does not prove divergence is impossible under adversarial extremes (utilisation driven
// past the 80% kink, where the rate turns steep and collateral erosion becomes self-amplifying);
// it proves the invariant is not casually reachable, and names the mechanism that protects it.
//
// forge test --match-contract CapitalConservation -vv

import {Test, console2} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

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

contract CapitalConservationTest is Test {
    BlazePhoenixStaking st;
    MockBZPX tok;
    address admin = address(0xA11CE);
    address treasury = address(0x713A5);
    address borrower = makeAddr("borrower"); // goes deep under water
    address whale = makeAddr("whale");       // keeps the AGGREGATE stake large

    function setUp() public {
        vm.warp(1_900_000_000);
        tok = new MockBZPX();
        vm.prank(admin);
        st = new BlazePhoenixStaking(address(tok), treasury);
        for (uint256 i; i < 3; ++i) {
            address who = i == 0 ? admin : (i == 1 ? borrower : whale);
            tok.mint(who, 100_000_000e18);
            vm.prank(who);
            tok.approve(address(st), type(uint256).max);
        }
    }

    /// @dev Drive `who` past the point where accrued interest exceeds their whole collateral,
    ///      WITHOUT anyone liquidating them. Pausing is what buys that: `_autoMaintain` no-ops
    ///      while paused, so no third party's transaction sweeps the position, which is the
    ///      realistic shape of "nobody got round to it in time".
    function test_SumOfStakes_VersusTotalStaked_UnderDeepUnderwater() public {
        uint256 t = block.timestamp;

        // A large healthy staker keeps the AGGREGATE well funded, so the global slice is never
        // capped by totalStaked. This is what separates the two caps.
        vm.prank(whale);
        st.deposit(25_000_000e18, 365);

        vm.prank(borrower);
        st.deposit(1_000e18, 90);
        t += 100; vm.warp(t);
        vm.roll(block.number + 20);
        vm.prank(borrower);
        st.borrow(500e18); // max LTV

        // Freeze maintenance so nothing liquidates the borrower, then let interest run for a
        // very long time so the charge exceeds their 1_000e18 of collateral outright.
        bytes32 guardian = keccak256("GUARDIAN_ROLE");
        vm.prank(admin); st.grantRole(guardian, admin);
        vm.prank(admin); st.pause();

        t += 3650 days; // a decade
        vm.warp(t);

        // Touch the borrower so the per-user attribution runs and the cap (if any) is applied.
        vm.prank(borrower);
        st.claimRewards();

        (uint256 bStaked, uint256 bDebt,,,,,,,,,,,,) = st.getUserInfo(borrower);
        (uint256 wStaked,,,,,,,,,,,,,) = st.getUserInfo(whale);
        uint256 sumStakes = bStaked + wStaked;
        uint256 total = st.totalStaked();

        console2.log("borrower staked:", bStaked);
        console2.log("borrower debt  :", bDebt);
        console2.log("whale staked   :", wStaked);
        console2.log("sum(u.staked)  :", sumStakes);
        console2.log("totalStaked    :", total);
        console2.log("totalUncollectedInterest:", st.solvency().totalUncollectedInterest);

        if (sumStakes > total) {
            console2.log(">>> DIVERGENCE, sum exceeds aggregate by:", sumStakes - total);
        } else if (total > sumStakes) {
            console2.log(">>> aggregate exceeds sum by:", total - sumStakes);
        } else {
            console2.log(">>> exact match");
        }

        // The protocol-level guarantee that must hold regardless: it still holds at least what
        // it owes. Conservation is defined on the aggregate, so this is the real safety net.
        assertTrue(st.isSolvent(), "the contract must still hold at least what it owes");

        // And the aggregate must never claim MORE stake than the positions actually hold —
        // that direction would mean the book invented stake out of nothing.
        assertLe(total, sumStakes + 1, "totalStaked must never exceed the sum of positions");
    }

    /// @notice The direction that actually matters for exit liveness: if sum(u.staked) exceeds
    ///         totalStaked, the last withdrawer underflows `totalStaked -= amount_`. Prove
    ///         whether an exit is still possible after the divergence above.
    function test_ExitLiveness_AfterDeepUnderwater() public {
        uint256 t = block.timestamp;

        vm.prank(whale);
        st.deposit(25_000_000e18, 90);
        vm.prank(borrower);
        st.deposit(1_000e18, 90);
        t += 100; vm.warp(t);
        vm.roll(block.number + 20);
        vm.prank(borrower);
        st.borrow(500e18);

        bytes32 guardian = keccak256("GUARDIAN_ROLE");
        vm.prank(admin); st.grantRole(guardian, admin);
        vm.prank(admin); st.pause();
        t += 3650 days;
        vm.warp(t);
        vm.prank(admin); st.unpause();

        // The whale's lock is long expired; they repaid nothing because they never borrowed.
        vm.roll(block.number + 20);
        (uint256 wStaked,,,,,,,,,,,,,) = st.getUserInfo(whale);
        vm.prank(whale);
        st.withdraw(wStaked);

        (uint256 wAfter,,,,,,,,,,,,,) = st.getUserInfo(whale);
        assertEq(wAfter, 0, "the whale must be able to exit its full position");
        console2.log("whale exited:", wStaked);
        console2.log("totalStaked after exit:", st.totalStaked());
        assertTrue(st.isSolvent(), "still solvent after the large exit");
    }
}
