// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  EXACT BOUNDARIES — every comparison a `<` / `<=` flip would move, landed on
//  to the wei, the second and the block.
//
//  A `<` -> `<=` flip diverges from the original on exactly one input: the
//  boundary value. A test that probes a guard at 80 % or 120 % of its bound
//  passes against both forms and therefore says nothing about which one ships.
//  Each test below therefore holds two calls that differ in ONE unit:
//    - the call ON the boundary, whose outcome the comparison as written decides;
//    - the control one unit across it, asserted by its exact selector.
//  So a flipped comparator turns one of the two red, and the selector names
//  which guard fired. The mutants that prove each pair bites are listed in
//  .github/scripts/mutants.py (method of bp-dex test/BoundaryEquality.t.sol).
//
//  Toolchain note (same as fix205/ViewsQuoteEqualsExecution.t.sol): this forge
//  build can reuse the result of a textually repeated `vm.warp(block.timestamp
//  + X)` / `vm.roll(block.number + X)` / view call. Every test here reads the
//  clock ONCE into a local and warps and rolls to absolute values derived from
//  it, and no view is called twice through the same call site.
//  The start of the clock is itself read through an external helper
//  (clockTs/clockBlock): under via_ir a `uint256 t0 = block.timestamp` local
//  can be re-evaluated after vm.warp, which shifted every later target.
//
//  forge test --match-contract BoundaryEquality -vv
// =============================================================================

import {Base} from "./BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract BoundaryEqualityTest is Base {
    uint256 constant P = 1_000e18;

    /// A wallet may hold EXACTLY the per-wallet cap; one more wei is refused.
    /// (`u.staked + amount_ > MAX_STAKE_PER_WALLET`)
    function test_DepositExactlyTheWalletCapSettles_OneWeiMoreIsRefused() public {
        uint256 cap = staking.MAX_STAKE_PER_WALLET();
        vm.prank(alice);
        staking.deposit(cap, 90);
        (uint256 staked,,,,,,,,,,,,,) = staking.getUserInfo(alice);
        assertEq(staked, cap, "the wallet holds exactly the cap");

        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__CapExceeded.selector);
        staking.deposit(1, 90);

        vm.prank(bob);
        vm.expectRevert(BlazePhoenixStaking.Staking__CapExceeded.selector);
        staking.deposit(cap + 1, 90);
    }

    /// The first borrow may reach EXACTLY floor(stake * MAX_LTV / 100); one more wei is refused
    /// by the LTV guard, not by the utilisation cap (the book sits at 50 % < 75 %).
    function test_BorrowExactlyTheLtvCapSettles_OneWeiMoreIsRefused() public {
        uint256 s = 1_001e18 + 1;                       // odd, so the floor is exercised
        uint256 cap = (s * 50) / 100;
        vm.prank(alice); staking.deposit(s, 90);
        vm.prank(bob);   staking.deposit(s, 90);

        vm.prank(alice);
        staking.borrow(cap);
        (, uint256 debt,,,,,,,,,,,,) = staking.getUserInfo(alice);
        assertEq(debt, cap, "borrowed exactly the cap");

        vm.prank(bob);
        vm.expectRevert(BlazePhoenixStaking.Staking__LTVExceeded.selector);
        staking.borrow(cap + 1);
    }

    /// Cumulative funding may reach EXACTLY TOTAL_REWARDS; one more wei is refused.
    function test_FundingExactlyTotalRewardsSettles_OneWeiMoreIsRefused() public {
        uint256 total = staking.TOTAL_REWARDS();
        vm.startPrank(admin);
        staking.fundEmission(total - 1);
        staking.fundEmission(1);
        assertEq(staking.totalEmissionFunded(), total, "funded exactly the cap, in two calls");
        vm.expectRevert(BlazePhoenixStaking.Staking__CapExceeded.selector);
        staking.fundEmission(1);
        vm.stopPrank();
    }

    /// The anti-flash guard refuses a withdrawal at depositBlock + MIN_DEPOSIT_BLOCKS (10) and
    /// lets the next block through. (`block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS`)
    function test_WithdrawAtTheGuardBlockIsRefused_TheNextBlockSettles() public {
        uint256 t0 = this.clockTs();
        uint256 n0 = this.clockBlock();
        vm.prank(alice); staking.deposit(P, 90);
        vm.warp(t0 + 90 days);                          // the lock is over: only the block guard is left

        vm.roll(n0 + 10);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__FlashLoanProtection.selector);
        staking.withdraw(P);

        vm.roll(n0 + 11);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice); staking.withdraw(P);
        assertGe(this.balOf(alice), before + P, "the principal leaves one block later");
    }

    /// A lock is over AT unlockTime, not one second after: withdraw is refused at unlockTime - 1
    /// and settles at unlockTime. (`block.timestamp < u.unlockTime`)
    function test_WithdrawOneSecondBeforeUnlockIsRefused_AtUnlockSettles() public {
        uint256 t0 = this.clockTs();
        uint256 n0 = this.clockBlock();
        vm.prank(alice); staking.deposit(P, 90);
        vm.roll(n0 + 11);

        vm.warp(t0 + 90 days - 1);
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__StillLocked.selector);
        staking.withdraw(P);

        vm.warp(t0 + 90 days);
        vm.prank(alice); staking.withdraw(P);
        (uint256 staked,,,,,,,,,,,,,) = staking.getUserInfo(alice);
        assertEq(staked, 0, "the whole position left at unlockTime");
    }

    /// The poke and the lock view agree on the same instant: one second before unlockTime the view
    /// says not expired and the poke is refused; at unlockTime the view says expired and the poke
    /// settles. Two producers of "is this lock over?" (lockInfoOf.expired and pokeExpiredLock's
    /// guard) pinned on the boundary where a `<` / `<=` drift between them would show.
    function test_LockExpiryViewAndPokeAgreeOnTheBoundary() public {
        uint256 t0 = this.clockTs();
        uint256 n0 = this.clockBlock();
        vm.prank(alice); staking.deposit(P, 90);
        vm.roll(n0 + 11);

        vm.warp(t0 + 90 days - 1);
        (,,, bool expiredBefore) = staking.lockInfoOf(alice);
        assertFalse(expiredBefore, "view: not expired one second before unlock");
        vm.prank(keeper);
        vm.expectRevert(BlazePhoenixStaking.Staking__StillLocked.selector);
        staking.pokeExpiredLock(alice);

        vm.warp(t0 + 90 days);
        (,,, bool expiredAt) = this.lockInfoExpired(alice);
        assertTrue(expiredAt, "view: expired at unlockTime");
        vm.prank(keeper); staking.pokeExpiredLock(alice);
        assertEq(this.lockDaysOf(alice), 0, "the poke cleared the lapsed commitment");
    }

    /// deposit: the decreasing countdown accepts EXACTLY floor(remaining / 1 day) and refuses one
    /// day more; the view maxLockDaysAvailable() publishes the same number.
    function test_DepositAcceptsExactlyTheDaysLeft_OneMoreIsRefused() public {
        uint256 end = staking.emissionEnd();
        vm.warp(end - 101 days + 1);                    // 100 days and 86399 s left: floor = 100
        assertEq(staking.maxLockDaysAvailable(), 100, "view: floor of the days left");

        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
        staking.deposit(P, 101);

        vm.prank(alice);
        staking.deposit(P, 100);
        (uint256 lockDays,,,) = staking.lockInfoOf(alice);
        assertEq(lockDays, 100, "the published maximum is accepted");
    }

    /// lock(): the same countdown, at its own call site.
    function test_LockAcceptsExactlyTheDaysLeft_OneMoreIsRefused() public {
        uint256 n0 = this.clockBlock();
        vm.prank(alice); staking.deposit(P, 90);
        vm.roll(n0 + 11);
        uint256 end = staking.emissionEnd();
        vm.warp(end - 100 days);                        // exactly 100 days left

        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__LockExceedsEmissionEnd.selector);
        staking.lock(101);

        vm.prank(alice);
        staking.lock(100);
        (uint256 lockDays, uint256 unlockTime,,) = staking.lockInfoOf(alice);
        assertEq(lockDays, 100, "the published maximum is accepted");
        assertEq(unlockTime, end, "and it ends exactly at the emission close");
    }

    /// A relock to the SAME unlockTime is refused (`newUnlock <= u.unlockTime`); one second later
    /// the same duration extends it by one second.
    function test_RelockToTheSameUnlockIsRefused_OneSecondLaterExtends() public {
        uint256 t0 = this.clockTs();
        uint256 n0 = this.clockBlock();
        vm.prank(alice); staking.deposit(P, 90);
        vm.roll(n0 + 11);

        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__CannotReduceLock.selector);
        staking.lock(90);

        vm.warp(t0 + 1);
        vm.prank(alice); staking.lock(90);
        (, uint256 unlockTime,,) = staking.lockInfoOf(alice);
        assertEq(unlockTime, t0 + 1 + 90 days, "extended by exactly one second");
    }

    /// The emission rate is the period's rate one second before the close and zero AT the close.
    /// (`block.timestamp >= emissionEnd` in currentRewardPerSec)
    function test_RewardRateIsLiveOneSecondBeforeTheCloseAndZeroAtIt() public {
        uint256 end = staking.emissionEnd();
        uint256 r7 = staking.INITIAL_REWARD_PER_SEC() >> 7;
        vm.warp(end - 1);
        assertEq(staking.currentRewardPerSec(), r7, "last second of period 7 pays R0 >> 7");
        vm.warp(end);
        assertEq(this.rateNow(), 0, "the programme is closed at emissionEnd");
    }

    // ── distinct external call sites for second reads (see the toolchain note) ──
    function balOf(address w) external view returns (uint256) { return token.balanceOf(w); }
    function rateNow() external view returns (uint256) { return staking.currentRewardPerSec(); }
    function lockDaysOf(address w) external view returns (uint256 d) { (d,,,) = staking.lockInfoOf(w); }
    function lockInfoExpired(address w) external view returns (uint256, uint256, uint256, bool) {
        return staking.lockInfoOf(w);
    }
    // via_ir may re-read TIMESTAMP/NUMBER for a local after vm.warp/vm.roll; an external call's
    // result cannot be rematerialised, so the start of the clock is captured through these.
    function clockTs() external view returns (uint256) { return block.timestamp; }
    function clockBlock() external view returns (uint256) { return block.number; }
}
