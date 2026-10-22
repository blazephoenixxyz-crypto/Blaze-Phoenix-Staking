#!/usr/bin/env python3
"""Mutation guard: proves the guards that exist HAVE tests that watch them.

WHY THIS EXISTS. A green suite says the code passes its tests; it does not say the tests can
fail. A guard whose test still passes with the guard removed is decorative, and a revert with the
right selector does not prove the right check fired (bp-dex lost a coverage gate exactly that way:
the test passed 5/5 with the gate torn out, because another check reverted with the same code).

NOT A GENERIC MUTATION TOOL, on purpose. A FIXED, VERSIONED list of mutants, each paired with the
one named test that MUST catch it. Port of bp-dex .github/scripts/mutants.py: same contract, same
three ways a verdict can be void.

THE CONTRACT: apply the mutant -> the named test must go RED. If it stays green the guard is
unwatched and the run fails. Adding a guard to the contract means adding its line here.

The verdict is void, and reported as a failure, when
  - the paired test is already red at baseline (every mutant on it would score killed for free);
  - the paired test does not exist (`No tests match`);
  - the deployed bytecode is byte-identical to pristine (INERT: the source moved, the artefact did
    not, so the test's verdict is about nothing).

Usage:
  python3 .github/scripts/mutants.py                 # all mutants
  MUTANTS_SHARD=0 MUTANTS_SHARDS=2 python3 ...       # one shard of the list
  MUTANTS_ONLY=3,7 python3 ...                       # 1-based indices, for a local re-run
Run it on a GREEN suite, alone: it rewrites src/ in place (and restores it) one mutant at a time.
"""
import re, subprocess, sys, os, json, hashlib

F = "src/BlazePhoenixStaking.sol"

M = [
 # ── exact boundaries (test/BoundaryEquality.t.sol) ────────────────────────────────────────────
 dict(nome="deposit: the per-wallet cap refuses the cap itself (> becomes >=)",
      f=F,
      old="        if (u.staked + amount_ > MAX_STAKE_PER_WALLET) revert Staking__CapExceeded();",
      new="        if (u.staked + amount_ >= MAX_STAKE_PER_WALLET) revert Staking__CapExceeded(); // MUTANT",
      teste="test_DepositExactlyTheWalletCapSettles_OneWeiMoreIsRefused"),
 dict(nome="borrow: the LTV cap refuses the cap itself (> becomes >=)",
      f=F,
      old="        if (u.debt + amount_ > _ltvCap(u)) revert Staking__LTVExceeded();",
      new="        if (u.debt + amount_ >= _ltvCap(u)) revert Staking__LTVExceeded(); // MUTANT",
      teste="test_BorrowExactlyTheLtvCapSettles_OneWeiMoreIsRefused"),
 dict(nome="fundEmission: the cumulative cap refuses TOTAL_REWARDS itself (> becomes >=)",
      f=F,
      old="        if (totalEmissionFunded + amount_ > TOTAL_REWARDS) revert Staking__CapExceeded();",
      new="        if (totalEmissionFunded + amount_ >= TOTAL_REWARDS) revert Staking__CapExceeded(); // MUTANT",
      teste="test_FundingExactlyTotalRewardsSettles_OneWeiMoreIsRefused"),
 dict(nome="withdraw: the anti-flash guard lets the guard block through (<= becomes <)",
      f=F,
      old="        if (u.debt != 0)                                         revert Staking__HasDebt();      // repay everything first\n"
          "        if (block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection();",
      new="        if (u.debt != 0)                                         revert Staking__HasDebt();      // repay everything first\n"
          "        if (block.number < u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection(); // MUTANT",
      teste="test_WithdrawAtTheGuardBlockIsRefused_TheNextBlockSettles"),
 dict(nome="withdraw: a lock is still on AT unlockTime (< becomes <=)",
      f=F,
      old="        if (u.lockDays > 0 && block.timestamp < u.unlockTime)    revert Staking__StillLocked();",
      new="        if (u.lockDays > 0 && block.timestamp <= u.unlockTime)    revert Staking__StillLocked(); // MUTANT",
      teste="test_WithdrawOneSecondBeforeUnlockIsRefused_AtUnlockSettles"),
 dict(nome="MC/DC withdraw: the time arm of `lockDays > 0 && now < unlockTime` neutralised (forced true)",
      f=F,
      old="        if (u.lockDays > 0 && block.timestamp < u.unlockTime)    revert Staking__StillLocked();",
      new="        if (u.lockDays > 0 && true)    revert Staking__StillLocked(); // MUTANT",
      teste="test_WithdrawOneSecondBeforeUnlockIsRefused_AtUnlockSettles"),
 dict(nome="deposit: the emission countdown refuses the published maximum (> becomes >=)",
      f=F,
      old="        // Decreasing countdown: a lock may never extend past the emission close.\n"
          "        uint256 maxDays = (emissionEnd - block.timestamp) / 1 days;\n"
          "        maxDays = _min(maxDays, MAX_LOCK_DAYS);\n"
          "        if (lockDays_ > maxDays) revert Staking__LockExceedsEmissionEnd();",
      new="        // Decreasing countdown: a lock may never extend past the emission close.\n"
          "        uint256 maxDays = (emissionEnd - block.timestamp) / 1 days;\n"
          "        maxDays = _min(maxDays, MAX_LOCK_DAYS);\n"
          "        if (lockDays_ >= maxDays) revert Staking__LockExceedsEmissionEnd(); // MUTANT",
      teste="test_DepositAcceptsExactlyTheDaysLeft_OneMoreIsRefused"),
 dict(nome="lock: the emission countdown refuses the published maximum (> becomes >=)",
      f=F,
      old="        // Decreasing countdown: the lock may never extend past the emission close.\n"
          "        uint256 maxDays = (emissionEnd - block.timestamp) / 1 days;\n"
          "        maxDays = _min(maxDays, MAX_LOCK_DAYS);\n"
          "        if (lockDays_ > maxDays) revert Staking__LockExceedsEmissionEnd();",
      new="        // Decreasing countdown: the lock may never extend past the emission close.\n"
          "        uint256 maxDays = (emissionEnd - block.timestamp) / 1 days;\n"
          "        maxDays = _min(maxDays, MAX_LOCK_DAYS);\n"
          "        if (lockDays_ >= maxDays) revert Staking__LockExceedsEmissionEnd(); // MUTANT",
      teste="test_LockAcceptsExactlyTheDaysLeft_OneMoreIsRefused"),
 dict(nome="lock: a relock to the same unlockTime is accepted (<= becomes <)",
      f=F,
      old="        if (newUnlock <= u.unlockTime) revert Staking__CannotReduceLock();",
      new="        if (newUnlock < u.unlockTime) revert Staking__CannotReduceLock(); // MUTANT",
      teste="test_RelockToTheSameUnlockIsRefused_OneSecondLaterExtends"),
 dict(nome="pokeExpiredLock: a lock is still on AT unlockTime (< becomes <=)",
      f=F,
      old="        if (u.lockDays == 0) revert Staking__NoLock();\n"
          "        if (block.timestamp < u.unlockTime) revert Staking__StillLocked();",
      new="        if (u.lockDays == 0) revert Staking__NoLock();\n"
          "        if (block.timestamp <= u.unlockTime) revert Staking__StillLocked(); // MUTANT",
      teste="test_LockExpiryViewAndPokeAgreeOnTheBoundary"),
 dict(nome="lockInfoOf: the view calls a lock expired one second late (>= becomes >)",
      f=F,
      old="        expired = (u.lockDays > 0 && block.timestamp >= u.unlockTime);",
      new="        expired = (u.lockDays > 0 && block.timestamp > u.unlockTime); // MUTANT",
      teste="test_LockExpiryViewAndPokeAgreeOnTheBoundary"),
 dict(nome="currentRewardPerSec: the rate is still live AT emissionEnd (>= becomes >)",
      f=F,
      old="        if (block.timestamp >= emissionEnd) return 0;\n"
          "        return INITIAL_REWARD_PER_SEC >> ((block.timestamp - emissionStart) / HALVING_PERIOD);",
      new="        if (block.timestamp > emissionEnd) return 0; // MUTANT\n"
          "        return INITIAL_REWARD_PER_SEC >> ((block.timestamp - emissionStart) / HALVING_PERIOD);",
      teste="test_RewardRateIsLiveOneSecondBeforeTheCloseAndZeroAtIt"),
 # ── curves: metamorphic relations and canonical oracles (test/MetamorphicRelations.t.sol) ────
 dict(nome="boost: the MAX_LOCK_DAYS clamp is dropped",
      f=F,
      old="        lockDays_ = _min(lockDays_, MAX_LOCK_DAYS);",
      new="        // MUTANT",
      teste="testFuzz_BoostClampsAtTheMaximumLock"),
 dict(nome="boost: the quadratic term divides by 365 * 364 (off the specified curve)",
      f=F,
      old="                + (BOOST_QUAD * lockDays_ * lockDays_) / (DAYS_PER_YEAR * DAYS_PER_YEAR);",
      new="                + (BOOST_QUAD * lockDays_ * lockDays_) / (DAYS_PER_YEAR * 364); // MUTANT",
      teste="test_BoostAtWholeYearsIsTheCurveExactly"),
 dict(nome="simulateRate: the utilisation clamp at 100 % is dropped",
      f=F,
      old="        utilizationWad_ = _min(utilizationWad_, WAD);",
      new="        // MUTANT",
      teste="testFuzz_RateClampsAtFullUtilisation"),
 dict(nome="emission: the in-period rate is halved once too often (R0 >> (p + 1))",
      f=F,
      old="                 + (INITIAL_REWARD_PER_SEC >> p) * (dt - p * HALVING_PERIOD);",
      new="                 + (INITIAL_REWARD_PER_SEC >> (p + 1)) * (dt - p * HALVING_PERIOD); // MUTANT",
      teste="testFuzz_EmissionInsideAPeriodIsLinear"),
 dict(nome="emission: the closed form runs one second ahead of the clock",
      f=F,
      old="                 + (INITIAL_REWARD_PER_SEC >> p) * (dt - p * HALVING_PERIOD);",
      new="                 + (INITIAL_REWARD_PER_SEC >> p) * (dt - p * HALVING_PERIOD + 1); // MUTANT",
      teste="testFuzz_ClosedFormEmissionVersusTheSumOfRates"),
 # ── parity: quote == execution, fuzzed (test/ViewsQuoteEqualsExecutionFuzz.t.sol) ────────────
 dict(nome="pendingRewards: the quote forgets the reserve cap execution applies",
      f=F,
      old="            r = _min(r, rewardReserve);",
      new="            // MUTANT",
      teste="testFuzz_PendingQuotesAreWhatClaimRewardsPays"),
 dict(nome="pendingPureYield: the quote forgets the reserve factor execution deducts",
      f=F,
      old="            uint256 toPool = slice - ML.mulDiv(slice, RESERVE_FACTOR_BPS, 10_000);",
      new="            uint256 toPool = slice; // MUTANT",
      teste="testFuzz_PendingPureYieldIsWhatClaimPureYieldPays"),
 # ── guard watchers (test/GuardWatchers.t.sol): the two selectors no other test named ───────────
 dict(nome="constructor: a zero token or treasury is accepted (guard deleted)",
      f=F,
      old="        if (bzpx_ == address(0) || treasury_ == address(0)) revert Staking__ZeroAddress();",
      new="        // MUTANT",
      teste="test_ConstructorRefusesZeroAddresses_WithItsSelector"),
 dict(nome="withdraw: the stake-sufficiency guard is deleted",
      f=F,
      old="        if (u.staked < amount_) revert Staking__InsufficientStake();",
      new="        // MUTANT",
      teste="test_WithdrawAboveTheStakeIsRefused_WithItsSelector"),
 # ── emission delivery index (test/assurance/DeliveryIndex.t.sol): what reaches positions ──────
 dict(nome="emission: the tbe/MIN throttle is dropped (1 wei would capture the schedule)",
      f=F,
      old="        if (tbe < MIN_EMISSION_WEIGHT) reward = ML.mulDiv(reward, tbe, MIN_EMISSION_WEIGHT);",
      new="        // MUTANT",
      teste="test_OneWeiCannotCaptureTheSchedule"),
 dict(nome="emission: the reserve clamp is dropped (an under-funded window pays as if funded)",
      f=F,
      old="        reward = _min(reward, rewardReserve);",
      new="        // MUTANT",
      teste="test_UnderfundedWindowIsClampedToTheReserve"),
 dict(nome="emission: the 2^-8 tail is emitted at the close (withholding dropped)",
      f=F,
      old="        if (x >= emissionEnd)   return TOTAL_REWARDS - (TOTAL_REWARDS >> EMISSION_PERIODS);",
      new="        if (x >= emissionEnd)   return TOTAL_REWARDS; // MUTANT",
      teste="test_FullPoolReceivesTheScheduleLessTheTail"),
 # ── delivery index, one level up: the schedule's parameters ──────────────────────────────────
 dict(nome="emission: MIN_EMISSION_WEIGHT doubles (the throttle scale moves)",
      f=F,
      old="    uint256 public  constant MIN_EMISSION_WEIGHT  = 1_000e18;",
      new="    uint256 public  constant MIN_EMISSION_WEIGHT  = 2_000e18; // MUTANT",
      teste="test_OneWeiCannotCaptureTheSchedule"),
 dict(nome="emission: the halving period is one day short (2*365d becomes 2*364d)",
      f=F,
      old="    uint256 public  constant HALVING_PERIOD         = 2 * 365 days;",
      new="    uint256 public  constant HALVING_PERIOD         = 2 * 364 days; // MUTANT",
      teste="test_EmptyFirstYearStaysInTheReserve"),
 dict(nome="emission: the programme closes a period early (EMISSION_PERIODS 8 becomes 7)",
      f=F,
      old="    uint256 public  constant EMISSION_PERIODS       = 8;",
      new="    uint256 public  constant EMISSION_PERIODS       = 7; // MUTANT",
      teste="test_FullPoolReceivesTheScheduleLessTheTail"),
 # ── constant oracles (test/assurance/ConstantOracles.t.sol) ──────────────────────────────────
 # A test that reads a constant back from the contract moves with a mutant of that constant.
 # These pairs name tests that pin the published literals (300 bps, 9 700 bps, 30 000 000e18).
 dict(nome="reserve: the reserve factor becomes 400 bps (execution cut)",
      f=F,
      old="    uint256 public  constant RESERVE_FACTOR_BPS   = 300;   // 3%",
      new="    uint256 public  constant RESERVE_FACTOR_BPS   = 400;   // 3% MUTANT",
      teste="test_ReserveTakesThreeHundredBpsOfRealisedInterest"),
 dict(nome="reserve: the published APR stops netting the reserve factor",
      f=F,
      old="        aprBps = ML.mulDiv(_dampPure(base, tbp), 10_000 - RESERVE_FACTOR_BPS, 10_000);",
      new="        aprBps = ML.mulDiv(_dampPure(base, tbp), 10_000, 10_000); // MUTANT",
      teste="test_PublishedAprNetsTheReserveFactor"),
 dict(nome="cap: the per-wallet cap shrinks (30 000 000e18 becomes 29 000 000e18)",
      f=F,
      old="    uint256 public  constant MAX_STAKE_PER_WALLET = 30_000_000e18;",
      new="    uint256 public  constant MAX_STAKE_PER_WALLET = 29_000_000e18; // MUTANT",
      teste="test_WalletCapIsThirtyMillionTokens"),
 # The same constant in the other direction: the boundary test in BoundaryEquality reads the cap
 # back from the contract, so only the literal oracle can see the cap growing.
 dict(nome="cap: the per-wallet cap grows (30 000 000e18 becomes 31 000 000e18)",
      f=F,
      old="    uint256 public  constant MAX_STAKE_PER_WALLET = 30_000_000e18;",
      new="    uint256 public  constant MAX_STAKE_PER_WALLET = 31_000_000e18; // MUTANT",
      teste="test_WalletCapIsThirtyMillionTokens"),
 dict(nome="ltv: the LTV cap moves (50 becomes 51)",
      f=F,
      old="    uint256 public  constant MAX_LTV              = 50;",
      new="    uint256 public  constant MAX_LTV              = 51; // MUTANT",
      teste="test_BorrowLTV"),
 # ── the programme budget, in both directions ─────────────────────────────────────────────────
 # Shrinking TOTAL_REWARDS makes a 180M funding literal exceed the cap; growing it leaves that
 # funding valid but moves the schedule literals. Each direction names the test that sees it.
 dict(nome="emission: the programme budget shrinks (TOTAL_REWARDS 180M becomes 179M)",
      f=F,
      old="    uint256 public  constant TOTAL_REWARDS          = 180_000_000e18;",
      new="    uint256 public  constant TOTAL_REWARDS          = 179_000_000e18; // MUTANT",
      teste="test_EmptyProgrammeSweepsTheWholeBudgetToTreasury"),
 dict(nome="emission: the programme budget grows (TOTAL_REWARDS 180M becomes 181M)",
      f=F,
      old="    uint256 public  constant TOTAL_REWARDS          = 180_000_000e18;",
      new="    uint256 public  constant TOTAL_REWARDS          = 181_000_000e18; // MUTANT",
      teste="test_FullPoolReceivesTheScheduleLessTheTail"),
 # ── value constants, one deterministic killer each (never a fuzz case) ───────────────────────
 # CONSERVATION_DUST is deliberately left unpaired: no deterministic test is known to fail when it
 # moves, and a pair whose killer does not exist would certify nothing.
 dict(nome="scale: the fixed-point unit changes (WAD 1e18 becomes 2e18)",
      f=F,
      old="    uint256 private constant WAD                  = 1e18;",
      new="    uint256 private constant WAD                  = 2e18; // MUTANT",
      teste="test_DustPurePositionCannotCaptureTheProtocolsInterest"),
 dict(nome="boost: the curve normaliser moves (BOOST_BASE 10_000 becomes 20_000)",
      f=F,
      old="    uint256 private constant BOOST_BASE           = 10_000;",
      new="    uint256 private constant BOOST_BASE           = 20_000; // MUTANT",
      teste="test_BoostCurve"),
 dict(nome="rate: the steep-slope point moves (RATE_S2 72_500 becomes 80_000)",
      f=F,
      old="    uint256 private constant RATE_S2              = 72_500;",
      new="    uint256 private constant RATE_S2              = 80_000; // MUTANT",
      teste="test_RateEndpointsAndKink"),
 # ── loss ordering, token check, self-liquidation (test/hardening, test/assurance) ─────────────
 dict(nome="uncollectible interest: the reserve no longer absorbs it first (all booked as bad debt)",
      f=F,
      old="            uint256 covered = shortfall > protocolReserve ? protocolReserve : shortfall;",
      new="            uint256 covered = 0; // MUTANT",
      teste="test_reserveAbsorbsUncollectibleInterestBeforeBadDebt"),
 # ── uncovered bad debt is owed (test/hardening/OwedCountsBadDebt.t.sol) ─────────────────────
 dict(nome="owed: uncovered bad debt is netted out again (insolvency hidden, exit first-come-first-served)",
      f=F,
      old="        owed_ = ledgerNet + _sub0(totalRewardDistributed, totalRewardsPaid);",
      new="        owed_ = _sub0(ledgerNet + _sub0(totalRewardDistributed, totalRewardsPaid), totalBadDebt); // MUTANT",
      teste="test_E3_uncoveredBadDebtReadsInsolvent"),
 dict(nome="absorbBadDebt: the caller's share is no longer capped at the uncovered loss",
      f=F,
      old="        uint256 fromCaller  = _min(amount_, bad - fromReserve);",
      new="        uint256 fromCaller  = amount_; // MUTANT",
      teste="test_E3_absorbCapsAtTheLossAndRevertsWithoutOne"),
 dict(nome="deposit: the breach gate is deleted (new money funds the shortfall)",
      f=F,
      old="        // No new money into a pot that cannot cover its claims: it would only fund the shortfall.\n        if (_hardBreach()) revert Staking__InvariantBreached();",
      new="        // No new money into a pot that cannot cover its claims: it would only fund the shortfall.\n        // MUTANT",
      teste="test_E3_depositClosesUnderBreach"),
 dict(nome="borrow: the breach gate is deleted (lends at par out of a short pot)",
      f=F,
      old="        // Lending out of a short pot pays the borrower at par and shrinks everyone else's share.\n        if (_hardBreach()) revert Staking__InvariantBreached();",
      new="        // Lending out of a short pot pays the borrower at par and shrinks everyone else's share.\n        // MUTANT",
      teste="test_E3_borrowClosesUnderBreach"),
 dict(nome="claimRewards: the breach gate is deleted (full-value payout under a breach)",
      f=F,
      old="        // Same rule as `withdraw`: no full-value payout while the pot cannot cover every claim.\n        if (_hardBreach()) revert Staking__InvariantBreached();",
      new="        // Same rule as `withdraw`: no full-value payout while the pot cannot cover every claim.\n        // MUTANT",
      teste="test_E3_claimRewardsClosesUnderBreach"),
 dict(nome="claimPureYield: the breach gate is deleted (full-value payout under a breach)",
      f=F,
      old="        if (block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection();\n        if (_hardBreach()) revert Staking__InvariantBreached();",
      new="        if (block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection();\n        // MUTANT",
      teste="test_E3_claimPureYieldClosesUnderBreach"),
 dict(nome="withdrawReserve: the breach gate is deleted (revenue leaves before the loss is covered)",
      f=F,
      old="        // book already in breach, where the reserve goes to `absorbBadDebt` first.\n        if (_hardBreach()) revert Staking__InvariantBreached();",
      new="        // book already in breach, where the reserve goes to `absorbBadDebt` first.\n        // MUTANT",
      teste="test_E3_withdrawReserveClosesUnderBreach"),
 dict(nome="constructor: a token address without code is accepted (guard deleted)",
      f=F,
      old="        if (bzpx_.code.length == 0) revert Staking__TokenHasNoCode();",
      new="        // MUTANT",
      teste="test_rejectsTokenWithoutCode"),
 dict(nome="self-liquidation: the event reports the bonus the caller is not paid",
      f=F,
      old="        if (keeper_ == user_) { protocolReserve += keeperBonus; keeperBonus = 0; }",
      new="        if (keeper_ == user_) { protocolReserve += keeperBonus; } // MUTANT",
      teste="test_E_Liquidated_self_reports_bonus_actually_paid"),
 dict(nome="pure-yield settle: the breach check is deleted (uncollected interest paid at par)",
      f=F,
      old="        // stays credited for when the loss is absorbed, or is forfeited to the pro-rata exit.\n        if (_hardBreach()) revert Staking__InvariantBreached();",
      new="        // stays credited for when the loss is absorbed, or is forfeited to the pro-rata exit.\n        // MUTANT",
      teste="test_PUREUNCOLL_bookingTxPaysNoUncollectedPureYield"),
 dict(nome="getLockers: the page end overflows again for limit = max",
      f=F,
      old="        if (offset >= total || limit == 0) return (new address[](0), total);\n        uint256 end = offset + _min(limit, total - offset);",
      new="        if (offset >= total || limit == 0) return (new address[](0), total);\n        uint256 end = _min(offset + limit, total);",
      teste="test_B92_getLockersAcceptsMaxLimit"),
 dict(nome="expiredLockScan: the page end overflows again for limit = max",
      f=F,
      old="        if (offset >= total || limit == 0) return (new address[](0), 0, 0, total);\n        uint256 end = offset + _min(limit, total - offset);",
      new="        if (offset >= total || limit == 0) return (new address[](0), 0, 0, total);\n        uint256 end = _min(offset + limit, total);",
      teste="test_B92_expiredLockScanAcceptsMaxLimit"),
 # ── EMIS-DEFER: no emission at par under a hard breach (test/hardening/EmissionDeferredUnderBreach.t.sol)
 dict(nome="emission settle: the breach deferral is deleted (emission paid at par from a short pot)",
      f=F,
      old="        if (ML.rawBalanceOf(bzpx, address(this)) + CONSERVATION_DUST\n            < _owed() + _sub0(_sub0(u.debt, u.staked), protocolReserve)) {\n            _rewardDeferred[user_] = due; return;\n        }\n",
      new="        // MUTANT\n",
      teste="test_EMISDEFER_repayUnderBreachPaysNoEmissionAndKeepsTheCredit"),
 dict(nome="emission settle: a paid deferred credit is not cleared (paid twice)",
      f=F,
      old="        _rewardDeferred[user_] = 0;\n",
      new="        // MUTANT\n",
      teste="test_EMISDEFER_deferredCreditIsPaidOnceSolvent"),
 dict(nome="pendingRewards: the quote drops the deferred credit",
      f=F,
      old="        return deferred + _sub0(g, u.rewardDebt);",
      new="        return _sub0(g, u.rewardDebt); // MUTANT",
      teste="test_EMISDEFER_repayUnderBreachPaysNoEmissionAndKeepsTheCredit"),
 dict(nome="emergencyWithdraw: the deferred credit survives the exit",
      f=F,
      old="        delete _rewardDeferred[msg.sender];   // deferred emission is unpaid emission: forfeited too",
      new="        // MUTANT",
      teste="test_EMISDEFER_emergencyExitForfeitsTheDeferredCredit"),
 # ── ERODED-EXIT: an eroded borrower closes by its own exit (test/hardening/ErodedBorrowerEmergencyExit.t.sol)
 dict(nome="emergencyWithdraw: a position with debt but no stake is refused again",
      f=F,
      old="        if (principal == 0 && debt == 0) revert Staking__NoStake();",
      new="        if (principal == 0) revert Staking__NoStake(); // MUTANT",
      teste="test_ERODED_emergencyExitClosesAnErodedBorrowerAndBooksItsDebt"),
 dict(nome="uncollectible-interest restore: adds the whole shortfall back, ignoring the overdraw",
      f=F,
      old="                totalStaked              += shortfall - overdrawn;",
      new="                totalStaked              += shortfall; // MUTANT",
      teste="test_ERODED_stakedOverdrawIsSettledByTheLaterAttribution"),
 dict(nome="_debitStaked: the part beyond zero is dropped instead of carried",
      f=F,
      old="        if (x > ts) { stakedOverdraw += x - ts; x = ts; }",
      new="        if (x > ts) { x = ts; } // MUTANT",
      teste="test_ERODED_latchOpensAfterEveryExitWithoutARawTransfer"),
 dict(nome="conserves: the identity leaves stakedOverdraw out",
      f=F,
      old="        lhsBefore = ML.rawBalanceOf(bzpx, address(this)) + totalDebt + totalBadDebt + stakedOverdraw;\n        rhsBefore = totalStaked + rewardReserve + protocolReserve + _pendingDistribution();\n    }\n\n    function _conservationCheck(uint256 lhsBefore, uint256 rhsBefore) internal view {\n        uint256 lhs = ML.rawBalanceOf(bzpx, address(this)) + totalDebt + totalBadDebt + stakedOverdraw + rhsBefore;",
      new="        lhsBefore = ML.rawBalanceOf(bzpx, address(this)) + totalDebt + totalBadDebt; // MUTANT\n        rhsBefore = totalStaked + rewardReserve + protocolReserve + _pendingDistribution();\n    }\n\n    function _conservationCheck(uint256 lhsBefore, uint256 rhsBefore) internal view {\n        uint256 lhs = ML.rawBalanceOf(bzpx, address(this)) + totalDebt + totalBadDebt + rhsBefore; // MUTANT",
      teste="test_ERODED_stakedOverdrawIsSettledByTheLaterAttribution"),
 # ── OWED-READ: the floored read is a lower bound and still reads the breach (test/hardening/UnbookedLossReadIsALowerBound.t.sol)
 dict(nome="_owed: signed sum floored only at the end (an unrecorded loss nets out of the read)",
      f=F,
      old="        uint256 ledgerNet = _sub0(ledgerSum, totalDebt);\n        owed_ = ledgerNet + _sub0(totalRewardDistributed, totalRewardsPaid);",
      new="        owed_ = _sub0(ledgerSum + _sub0(totalRewardDistributed, totalRewardsPaid), totalDebt); // MUTANT",
      teste="test_OWEDREAD_unbookedLossReadsAsABreachBoundedByTheRealDeficit"),
 # ── EMIS-DEFER at liquidation: the settle reads the pot after the loss it books (test/hardening/EmissionDeferredUnderBreach.t.sol)
 dict(nome="emission settle: the breach read ignores the position's own loss (a liquidation that books it pays at par)",
      f=F,
      old="            < _owed() + _sub0(_sub0(u.debt, u.staked), protocolReserve)) {",
      new="            < _owed()) { // MUTANT",
      teste="test_EMISDEFER_liquidationThatBooksTheLossReadsThePotAfterIt"),
 # ── TERM-DISTRESS: the withdraw site of _debitStaked and the shared end state (test/hardening/TerminalDistressOrdering.t.sol)
 dict(nome="withdraw: the stake debit saturates at zero instead of carrying the overdraw",
      f=F,
      old="        _debitStaked(amount_);",
      new="        totalStaked = _sub0(totalStaked, amount_); // MUTANT",
      teste="test_TERMDISTRESS_pureStakerWithdrawPastTotalStakedCarriesTheOverdraw"),
 dict(nome="maintStep: the borrower is not accrued before the liquidatable check",
      f=F,
      old="        _accrueInterestFor(who);\n        if (_isLiquidatable(_users[who])) {",
      new="        if (_isLiquidatable(_users[who])) { // MUTANT",
      teste="test_TERMDISTRESS_neutralTouchAndSeizureSucceedWhenTheUnderWaterSideIsSeizedFirst"),
 # ── SWEEP-SOLVENT: the residue leaves only from a book that reads solvent after it (test/hardening/EmissionSweepKeepsTheBookSolvent.t.sol)
 dict(nome="sweepUndistributedEmission: the post-sweep breach check is deleted",
      f=F,
      old="        if (_hardBreach()) revert Staking__InvariantBreached();\n        emit UndistributedEmissionSwept",
      new="        // MUTANT\n        emit UndistributedEmissionSwept",
      teste="test_SWEEP_residueThatCoversTheClaimsStaysInThePot"),
 # ── EMIS-DEFER, the class: the settle reads the pot after the loss its own tx books (test/hardening/EmissionDeferredUnderBreach.t.sol)
 dict(nome="emission settle: the position is not attributed before the breach read",
      f=F,
      old="        _accrueInterestFor(user_);\n        UserInfo storage u = _users[user_];\n        uint256 due = _rewardDeferred[user_];",
      new="        UserInfo storage u = _users[user_]; // MUTANT\n        uint256 due = _rewardDeferred[user_];",
      teste="test_EMISDEFER_claimThatBooksItsOwnShortfallReadsThePotAfterIt"),
 dict(nome="emission settle: the own-loss read ignores the reserve (a covered seizure is deferred)",
      f=F,
      old="            < _owed() + _sub0(_sub0(u.debt, u.staked), protocolReserve)) {",
      new="            < _owed() + _sub0(u.debt, u.staked)) { // MUTANT",
      teste="test_EMISDEFER_liquidationWhoseLossTheReserveCoversPaysAtPar"),
 dict(nome="withdrawReserve: the breach is read before the reserve leaves",
      f=F,
      old="        if (amount_ == 0) revert Staking__ZeroAmount();\n        _updateGlobal();   // read the book as of now: the elapsed interest slice moves the reserve and the claims\n        amount_ = _min(amount_, protocolReserve);\n        protocolReserve -= amount_;\n        if (!ML.rawTransfer(bzpx, treasury, amount_)) revert Staking__TransferFailed();\n        // Revenue leaves only while every claim is covered, read AFTER it leaves: once a hidden\n        // loss has pushed `totalStaked + rewardReserve` below `totalDebt`, the reserve is what\n        // keeps the pot covering every claim, and taking it opens a breach on a book that read\n        // solvent. A withdrawal never shrinks the deficit, so the same read refuses one out of a\n        // book already in breach, where the reserve goes to `absorbBadDebt` first.\n        if (_hardBreach()) revert Staking__InvariantBreached();",
      new="        if (amount_ == 0) revert Staking__ZeroAmount();\n        _updateGlobal();   // read the book as of now: the elapsed interest slice moves the reserve and the claims\n        if (_hardBreach()) revert Staking__InvariantBreached(); // MUTANT\n        amount_ = _min(amount_, protocolReserve);\n        protocolReserve -= amount_;\n        if (!ML.rawTransfer(bzpx, treasury, amount_)) revert Staking__TransferFailed();",
      teste="test_SWEEP_reserveThatCoversTheClaimsStaysInThePot"),
dict(nome="deposit: the maintenance sweep runs after the caller's settles (LOSS-FIRST)",
      f=F,
      old='        _autoMaintain(msg.sender);   // LOSS-FIRST: every loss this tx books precedes the settles\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _processLockExpiry(msg.sender);\n',
      new='        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _processLockExpiry(msg.sender);\n        _autoMaintain(msg.sender); // MUTANT\n',
      teste='test_LOSSFIRST_order_deposit'),
dict(nome="borrow: the maintenance sweep runs after the caller's settles (LOSS-FIRST)",
      f=F,
      old="        _autoMaintain(msg.sender);   // LOSS-FIRST\n        // Lending out of a short pot pays the borrower at par and shrinks everyone else's share.\n        if (_hardBreach()) revert Staking__InvariantBreached();\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n",
      new="        // Lending out of a short pot pays the borrower at par and shrinks everyone else's share.\n        if (_hardBreach()) revert Staking__InvariantBreached();\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _autoMaintain(msg.sender); // MUTANT\n",
      teste='test_LOSSFIRST_order_borrow'),
dict(nome='borrow: the breach is read before the sweep books its losses',
      f=F,
      old="        _autoMaintain(msg.sender);   // LOSS-FIRST\n        // Lending out of a short pot pays the borrower at par and shrinks everyone else's share.\n        if (_hardBreach()) revert Staking__InvariantBreached();\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n",
      new="        // Lending out of a short pot pays the borrower at par and shrinks everyone else's share.\n        if (_hardBreach()) revert Staking__InvariantBreached(); // MUTANT\n        _autoMaintain(msg.sender);\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n",
      teste='test_LOSSFIRST_borrowWhoseSweepBooksAThirdPartyLossIsRefused'),
dict(nome="repay: the maintenance sweep runs after the caller's settles (LOSS-FIRST)",
      f=F,
      old='        _autoMaintain(msg.sender);   // LOSS-FIRST\n\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _processLockExpiry(msg.sender);\n        if (u.debt == 0) revert Staking__NoDebt();',
      new='\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _processLockExpiry(msg.sender);\n        _autoMaintain(msg.sender); // MUTANT\n        if (u.debt == 0) revert Staking__NoDebt();',
      teste='test_LOSSFIRST_order_repay'),
dict(nome="withdraw: the maintenance sweep runs after the caller's settles (LOSS-FIRST)",
      f=F,
      old='        _autoMaintain(msg.sender);   // LOSS-FIRST\n        // A full-value exit out of a pot that cannot cover every claim is first-come-first-served:\n        // the first exiter takes 100% and the shortfall lands on whoever is left. Under a hard\n        // breach the only fair exit is the pro-rata one, so the normal channel closes and the\n        // permissionless `tripBreaker` opens `emergencyWithdraw` with its haircut.\n        if (_hardBreach()) revert Staking__InvariantBreached();\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _processLockExpiry(msg.sender);\n',
      new='        // A full-value exit out of a pot that cannot cover every claim is first-come-first-served:\n        // the first exiter takes 100% and the shortfall lands on whoever is left. Under a hard\n        // breach the only fair exit is the pro-rata one, so the normal channel closes and the\n        // permissionless `tripBreaker` opens `emergencyWithdraw` with its haircut.\n        if (_hardBreach()) revert Staking__InvariantBreached();\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _processLockExpiry(msg.sender);\n        _autoMaintain(msg.sender); // MUTANT\n',
      teste='test_LOSSFIRST_order_withdraw'),
dict(nome="claimRewards: the maintenance sweep runs after the caller's settles (LOSS-FIRST)",
      f=F,
      old='        _autoMaintain(msg.sender);   // LOSS-FIRST\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _processLockExpiry(msg.sender);\n        _resync(msg.sender);',
      new='        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _processLockExpiry(msg.sender);\n        _autoMaintain(msg.sender); // MUTANT\n        _resync(msg.sender);',
      teste='test_LOSSFIRST_order_claimRewards'),
dict(nome="claimPureYield: the maintenance sweep runs after the caller's settles (LOSS-FIRST)",
      f=F,
      old='        _autoMaintain(msg.sender);   // LOSS-FIRST\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _resync(msg.sender);',
      new='        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _autoMaintain(msg.sender); // MUTANT\n        _resync(msg.sender);',
      teste='test_LOSSFIRST_order_claimPureYield'),
dict(nome="lock: the maintenance sweep runs after the caller's settles (LOSS-FIRST)",
      f=F,
      old='        _autoMaintain(msg.sender);   // LOSS-FIRST\n        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n\n        _processLockExpiry(msg.sender);   // an elapsed',
      new='        _settlePendingRewards(msg.sender);\n        _settlePendingPureYield(msg.sender);\n        _autoMaintain(msg.sender); // MUTANT\n\n        _processLockExpiry(msg.sender);   // an elapsed',
      teste='test_LOSSFIRST_order_lock'),
dict(nome="pokeExpiredLock: the maintenance sweep runs after the poked owner's settle (LOSS-FIRST)",
      f=F,
      old='        _autoMaintain(msg.sender);   // LOSS-FIRST; its lock window may already have normalised `user_`\n        if (u.lockDays != 0) this.lockStep(user_, msg.sender);\n',
      new='        if (u.lockDays != 0) this.lockStep(user_, msg.sender);\n        _autoMaintain(msg.sender); // MUTANT\n',
      teste='test_LOSSFIRST_order_pokeExpiredLock'),
dict(nome='pokeExpiredLock: the lockStep runs even when the sweep already normalised the lock',
      f=F,
      old='        _autoMaintain(msg.sender);   // LOSS-FIRST; its lock window may already have normalised `user_`\n        if (u.lockDays != 0) this.lockStep(user_, msg.sender);\n',
      new='        _autoMaintain(msg.sender);   // LOSS-FIRST; its lock window may already have normalised `user_`\n        this.lockStep(user_, msg.sender); // MUTANT\n',
      teste='test_LOSSFIRST_order_pokeExpiredLock'),
dict(nome='pokeExpiredLocks: the solvency sweep runs after the named settles (LOSS-FIRST)',
      f=F,
      old='        if (!paused() && !emergencyMode) {\n            uint256 b = _maintBudget();\n            if (b != 0) _sweepBorrowers(msg.sender, b);\n            lastMaintTime = block.timestamp;\n        }\n        uint256 swept;\n        for (uint256 i = 0; i < users_.length; ) {\n            UserInfo storage w = _users[users_[i]];\n            if (w.lockDays > 0 && block.timestamp >= w.unlockTime) {\n                try this.lockStep(users_[i], msg.sender) { unchecked { ++swept; } } catch {}\n            }\n            unchecked { ++i; }\n        }\n',
      new='        uint256 swept;\n        for (uint256 i = 0; i < users_.length; ) {\n            UserInfo storage w = _users[users_[i]];\n            if (w.lockDays > 0 && block.timestamp >= w.unlockTime) {\n                try this.lockStep(users_[i], msg.sender) { unchecked { ++swept; } } catch {}\n            }\n            unchecked { ++i; }\n        }\n        if (!paused() && !emergencyMode) { // MUTANT\n            uint256 b = _maintBudget();\n            if (b != 0) _sweepBorrowers(msg.sender, b);\n            lastMaintTime = block.timestamp;\n        }\n',
      teste='test_LOSSFIRST_order_pokeExpiredLocks'),
dict(nome='withdrawReserve: the cap is read on the book of the last touch (no fresh accrual)',
      f=F,
      old='        _updateGlobal();   // read the book as of now: the elapsed interest slice moves the reserve and the claims\n',
      new='        // MUTANT\n',
      teste='test_SWEEP_reserveIsReadOnTheBookAsOfNow'),
dict(nome='sweepUndistributedEmission: the breach is read before the residue leaves',
      f=F,
      old='        rewardReserve = 0;\n        if (!ML.rawTransfer(bzpx, treasury, residue)) revert Staking__TransferFailed();\n        // Same rule as `withdrawReserve`, read AFTER the sweep: the residue sits in `_owed()` and in\n        // the pot, and once a hidden loss has pushed `totalStaked + protocolReserve` below\n        // `totalDebt` it is what keeps the pot covering every claim, so taking it opens a breach on\n        // a book that read solvent. A sweep never shrinks the deficit, so the same read also refuses\n        // a sweep out of a book already in breach.\n        if (_hardBreach()) revert Staking__InvariantBreached();\n',
      new='        if (_hardBreach()) revert Staking__InvariantBreached(); // MUTANT\n        rewardReserve = 0;\n        if (!ML.rawTransfer(bzpx, treasury, residue)) revert Staking__TransferFailed();\n',
      teste='test_SWEEP_residueIsReadAfterItLeaves'),
dict(nome='emission settle: a pot covering the claims exactly to the dust defers (< becomes <=)',
      f=F,
      old='            < _owed() + _sub0(_sub0(u.debt, u.staked), protocolReserve)) {',
      new='            <= _owed() + _sub0(_sub0(u.debt, u.staked), protocolReserve)) { // MUTANT',
      teste='test_EMISDEFER_potCoveringTheClaimsToTheDustPaysAtPar'),
]
CONTRACTS = ("BlazePhoenixStaking",)


def run(t):
    r = subprocess.run(["forge", "test", "--match-test", t], capture_output=True, text=True)
    return r.returncode == 0, r.stdout + r.stderr


def artefact_fingerprint():
    """sha256 of creation + runtime bytecode of each shipped contract (bp-dex: a mutant is a claim
    about the artefact, not about the source; byte-identical means INERT)."""
    out = {}
    for c in CONTRACTS:
        f = os.path.join("out", f"{c}.sol", f"{c}.json")
        if not os.path.exists(f):
            return {}
        art = json.load(open(f))
        obj = art.get("bytecode", {}).get("object", "") + "|" + art.get("deployedBytecode", {}).get("object", "")
        out[c] = hashlib.sha256(obj.encode()).hexdigest()[:16]
    return out


def baseline():
    """Which paired tests are GREEN before anything is mutated: a test red for its own reasons
    scores every mutant paired with it as killed, for free."""
    r = subprocess.run(["forge", "test"], capture_output=True, text=True)
    out = r.stdout + r.stderr
    green = set(re.findall(r"\[PASS\]\s+(\w+)", out))
    red = set(re.findall(r"\[FAIL[^\]]*\]\s+(\w+)", out))
    return green, red, out


def selection():
    only = os.environ.get("MUTANTS_ONLY")
    k = int(os.environ.get("MUTANTS_SHARD", "0"))
    n = int(os.environ.get("MUTANTS_SHARDS", "1"))
    if n < 1 or not 0 <= k < n:
        sys.exit(f"MUTANTS_SHARD={k} MUTANTS_SHARDS={n}: need 0 <= shard < shards")
    if only:
        want = {int(x) for x in only.split(",") if x.strip()}
        return [(i, m) for i, m in enumerate(M, 1) if i in want], k, n
    return [(i, m) for i, m in enumerate(M, 1) if (i - 1) % n == k], k, n


def main():
    fails = []
    mine, k, n = selection()
    paired = {m["teste"] for _, m in mine}
    green, red, _ = baseline()
    pristine = artefact_fingerprint()
    inert = []
    for t in sorted(red & paired):
        fails.append(f"BASELINE RED: '{t}' already fails with no mutation; its mutants prove nothing.")
        print(f"  BASELINE RED  {t}")
    for t in sorted(paired - green - red):
        fails.append(f"BASELINE MISSING: '{t}' was neither PASS nor FAIL in the baseline run.")
        print(f"  BASELINE ?    {t}")
    for i, m in mine:
        src = open(m["f"]).read()
        if src.count(m["old"]) != 1:
            fails.append(f"[{i}] {m['nome']}: target not found exactly once in {m['f']}.")
            print(f"  [{i}] TARGET LOST  {m['nome']}"); continue
        bak = src
        try:
            open(m["f"], "w").write(src.replace(m["old"], m["new"]))
            ok, out = run(m["teste"])
            fp = artefact_fingerprint()
            if pristine and fp and fp == pristine:
                inert.append(f"[{i}] {m['nome']}: INERT - bytecode identical to pristine.")
                print(f"  [{i}] INERT        {m['nome']}")
            elif ok:
                fails.append(f"[{i}] {m['nome']}: '{m['teste']}' PASSED with the guard mutated - decorative.")
                print(f"  [{i}] SURVIVED     {m['nome']}  ({m['teste']} passed mutated)")
            elif "No tests match" in out or "Compiler run failed" in out:
                fails.append(f"[{i}] {m['nome']}: '{m['teste']}' does not exist or did not compile.")
                print(f"  [{i}] NO TEST      {m['nome']}")
            else:
                print(f"  [{i}] killed       {m['nome']}")
        finally:
            open(m["f"], "w").write(bak)
    print()
    fails.extend(inert)
    if fails:
        print("UNWATCHED GUARDS:"); [print("  -", f) for f in fails]
        sys.exit(1)
    print(f"{len(mine)}/{len(mine)} mutants killed (shard {k + 1}/{n} of {len(M)}), "
          f"all paired tests green at baseline ({len(green)} passing tests).")


if __name__ == "__main__":
    main()
