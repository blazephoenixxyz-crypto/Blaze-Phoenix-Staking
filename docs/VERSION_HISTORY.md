# Version history & completeness map

This file tracks exactly what changed across the three versions so nothing is silently lost
between them.

## Summary

| Version | Contract | MathLib | Theme |
|---|---|---|---|
| v1 | `1.1.0` | `1.0.0-staking` | Feature-rich; offline audit only; admin sweep + admin liquidation |
| v2 | `2.1.0` | `2.0.0-staking` | Security core: on-chain conservation guard, permissionless liquidation, no backdoor |
| v3 | `3.0.0` | `3.0.0-staking` | v2 core **+** fully autonomous maintenance **+** public solvency proofs |
| **v3.1 (final)** | **`3.1.0`** | **`3.0.0-staking`** | v3 **+** lock expiry priced against the clock **+** the locker maintenance window |

v3 = **v2 base**, with the two requested additions and the useful UX views that v2 had dropped
from v1 re-added.

---

## v3.1 — BP-2026-001: stale boost persistence in pure stakers

> **Reported by [NetGakarot](https://github.com/NetGakarot) ("Gakarot"), 28 July 2026.**
> The finding, the root-cause analysis, the game-theoretic argument that boost is strictly the
> price of illiquidity, and the first half of the remediation (real-time expiry evaluation inside
> `_computeBoost`) are all his. v3.1 is his report, implemented — with the propagation half added
> so the correction reaches idle positions too. Full credit to NetGakarot for the disclosure.

### The finding

`_autoMaintain` iterated `_borrowers` and nothing else. A **pure staker** (`debt == 0`) is never in
that array, so once such a position's lock expired, `_processLockExpiry` was never reached unless the
user personally transacted or someone paid gas to `pokeExpiredLock` them. Meanwhile `_computeBoost`
read `u.lockDays` straight from storage without consulting the clock. Result: an idle staker whose
lock lapsed kept its historical multiplier (e.g. 1.25x) in `totalBoostedEffective` /
`totalBoostedPure` indefinitely, drawing an oversized share of every ongoing emission and interest
distribution at the expense of stakers who were still committed.

**Solvency was never affected** — `TOTAL_REWARDS`, `rewardReserve` and the `conserves` guard bound
every payout, and boost is a *denominator weight*, never a claim on value. The damage was purely
distributional, and it destroyed the incentive to re-lock: holding liquid tokens retained boosted
yield, so committing capital bought nothing.

### The correction, on two axes

Either axis alone is insufficient, which is why v3.1 implements both:

**(a) Derivation** — `_effectiveLockDays()` evaluates expiry against `block.timestamp`, and every
boost in the protocol is derived through it. No code path can re-price an elapsed commitment at its
historical multiplier, whatever storage still says. *Alone, this only re-prices a position somebody
already touched — which an idle staker never is.*

**(b) Propagation** — a `_lockers` registry tracks every position holding a live commitment, giving
the autonomous engine a second gas-bounded rotating window that **can** see debt-free positions. The
global denominators shed expired weight with nobody touching the idle position. *Alone, this would
leave the stale multiplier re-derivable in the window between expiry and sweep.*

`_resync` now folds `_processLockExpiry` in, so stored state and tracked weight are structurally
unable to diverge: every boost write in the contract goes through it.

### Properties preserved (non-negotiable)

- **Master Conservation Identity** — untouched. Boost never appears in `_owed()`; the sweep settles
  through the same CEI path as any claim, so balance and `_owed()` move together.
- **Single-writer boost** — `_applyBoost` remains the only writer of both totals.
- **No confiscation** — the sweep settles the boosted backlog *before* it releases the weight.
  Everything earned while the commitment was live was earned at the boosted weight and is paid at it;
  only the future is re-priced.
- **Bounded gas** — the probe window shares the `MAINT_MAX_SCAN` cap; normalisations carry their own
  tighter `MAINT_MAX_LOCK_ACTIONS` ceiling. Worst case per tx is
  `MAINT_MAX_SCAN + MAINT_MAX_LOCK_ACTIONS` iterations, unconditionally.
- **No new DoS surface** — a poisoned position (a token that refuses to pay it) is isolated by the
  self-external `lockStep` + try/catch exactly as `maintStep` is, and the cursor rotates past it.

### Surface added

`pokeExpiredLocks(address[])`, `expiredLockScan(offset,limit)`, `hasStaleBoost(user)`,
`effectiveLockDaysOf(user)`, `effectiveBoostOf(user)`, `activeLockerCount()`, `lockerAt(i)`,
`isTrackedLocker(who)`, `getLockers(offset,limit)`, `lockSweepBudget()`, `totalLockSweeps()`,
`lockStep(who,beneficiary)` (self-only), and the `LockSwept` event.

`lockInfoOf().boostBps` and `getUserInfo().boostBps` now report what a position is **paid** at, not
what its stale storage claims — they read `10000` the instant a lock lapses. `lockDays` / `unlockTime`
still report the commitment on record.

### Regression coverage

`test/boost.mjs` (B1–B10) pins both axes. **B1 uses only the v3.0.0 ABI**, so it runs verbatim
against the vulnerable contract, where it fails on the reported divergence itself — idle:active
yield ratio `12500` (1.25x) and a `2.25M` denominator against the corrected `10000` and `2.0M` —
rather than on a missing function. The Foundry suite adds fuzzed expiry, a locker-flood stress
scenario, and three structural invariants, the load-bearing one being
`invariant_everyLiveCommitmentIsTracked`: a live lock that escapes the registry is a lock the engine
can never normalise, i.e. the original bug returning.

---

## What v3 keeps from v2 (the security core)

- `conserves` per-transaction value-conservation guard on every value-moving entry-point.
- `_owed()` Master Conservation Identity; `_hardBreach()` (objective on-chain insolvency check used
  by `tripBreaker`, `cancelEmergency` and the public views).
- Single-writer boost accounting (`_applyBoost` / `_computeBoost` / `_resync` / `_checkpoint`).
- Permissionless, keeper-incentivised `liquidate(user)`.
- Immutable `treasury`; `withdrawReserve` cannot pick a destination; **no principal sweep**.
- Pull-only emergency (`tripBreaker` / `declareEmergency` / `cancelEmergency` / `emergencyWithdraw`);
  **no `sweepRemaining` backdoor**.
- CEI settlement (`rewardDebt` written before transfer).
- Deterministic emission (`tbe == 0` advances the clock).
- `repay` callable while paused; `withdraw` callable while paused, blocked under emergency.

## Staking is mandatorily locked; withdraw requires repay-all (changed from v1/v2)

In v1/v2 staking was liquid and the lock was an *optional* boost add-on. v3 makes **all staking a
locked commitment**, and changes the exit rule:

- **Mandatory lock on deposit.** `deposit(uint256 amount)` → `deposit(uint256 amount, uint256
  lockDays)`. Every deposit sets/extends a lock; there is no unlocked stake. `lockDays` is **min 90,
  max 2555 (7 years)**, capped by the decreasing countdown (`maxLockDaysAvailable()`), so no lock
  outlasts the 7-year emission. Top-ups may only EXTEND: a chosen duration that would land before
  the current unlock keeps the longer existing lock (new funds inherit it).
- **Withdraw requires lock-expired AND debt-free.** `withdraw` now reverts with `Staking__HasDebt`
  unless `debt == 0` — a borrower must repay everything before withdrawing any stake. Lending
  (`borrow`) is unchanged and allowed against locked collateral.
- **Removed the early-exit-with-debt path** and its penalty: `EARLY_EXIT_FEE_BPS` is deleted and the
  `Withdrawn` event's `debtCleared` / `penalty` fields are now always 0 (signature kept).

## Lock model: day-based with a countdown (changed from v1/v2 tiers)

v1/v2 used discrete year-tiers (`lockTier` 1..6, `boostByTier`). v3 replaces them with a
**day-denominated** commitment:

- A **decreasing countdown** (`maxLockDaysAvailable()`) caps each lock at the days remaining to the
  7-year emission end, so a lock can never outlast emission.
- Boost is continuous: `boostByDays(d) = 10000 + 750·(d/365) + 250·(d/365)²` bps (90d ≈ 1.02×,
  1y = 1.10×, 7y = 2.75×). Note the **max boost rose from 2.35× (6y tier) to 2.75× (7y)**, since
  the cap is now the full emission window.
- `UserInfo.lockTier (uint8)` → `UserInfo.lockDays (uint16)`. The standalone `lock(uint256
  lockDays)` remains, for extending a commitment without depositing. Commitments may only be
  extended. New errors `Staking__LockTooShort` / `Staking__LockTooLong` / `Staking__NoLock` replace
  `Staking__InvalidTier`. Views `maxLockTierAvailable()` → `maxLockDaysAvailable()`; `lockInfoOf` /
  `getUserInfo` / `getGlobalStats` / `pureStakerApr` now speak days; `LockSet` carries `lockDays`.

## Circuit breaker: permissionless, but strictly insolvency-gated

`tripBreaker()` (from v2) is **kept** and is **permissionless**, but fires **only when the chain
proves insolvency** — it requires `_hardBreach()` (`balance + dust < owed`), an objective,
un-spoofable condition that is impossible on healthy state (donations only raise balance; nothing
lowers it except flows that lower `owed` equally). It is **reversible**: the admin's
`cancelEmergency()` requires `_hardBreach()` to have cleared, so a transient trip is an
admin-undoable pause, never a permanent freeze. Conservation itself remains enforced *intrinsically*
by the `conserves` guard on every value-moving tx — the breaker is a backstop for a real shortfall
(e.g. a token-level failure outside this contract), not the primary mechanism, and it is never
needed in normal operation. `declareEmergency()` (GUARDIAN, discretionary, off-chain issues) sits
alongside it. `liquidate(user)` and the autonomous sweep stay permissionless because that is
*liquidation* (position health), not the conservation breaker.

## What v3 ADDS (the request)

- **`_autoMaintain` on every user entry-point** — including the ones v2 missed
  (`claimPureYield`, `lock`, `pokeExpiredLock`). v2 only swept on deposit/borrow/repay/withdraw/
  claimRewards.
- **Adaptive, governance-free maintenance budget** `_maintBudget()` — a pure function of borrower
  count and time-since-last-sweep, hard-capped at `MAINT_MAX_SCAN`. Replaces v2's admin-tuned
  `maintPerTx` / `setMaintPerTx` (removed) so the engine is 100% autonomous.
- **Public solvency surface:** `isSolvent()`, `backing()`, `owed()`, `collateralRatio()`,
  `solvency()` (full struct), `maintenanceBudget()`.
- `totalAutoLiquidations` counter and `lastMaintTime` for telemetry.

## What v3 re-adds from v1 (UX views v2 had dropped)

- `timeSinceEmissionStart()`
- `timeUntilEmissionEnd()`
- `timeUntilUnlock(address)`
- `pureStakerApr(...)` (now takes lock-days instead of a tier)
- `getBorrowers(offset, limit)` paginated (v2 only had `borrowerAt(i)`)

## What v1 had that is intentionally NOT in v3 (and why)

| v1 item | Why dropped |
|---|---|
| `sweepRemaining(address)` admin principal sweep | Backdoor; removed in v2, stays removed. |
| `adminLiquidate(address)` | Replaced by permissionless `liquidate()` + autonomous sweep. |
| `runMaintenance()` / `adminMaintenance()` | Maintenance is now carried automatically by user txs. |
| `nextCheckTime` per-user scheduling + `_scheduleNextCheck` | Autonomous sweep scans the rotating list directly; per-user scheduling no longer needed. The adaptive budget handles backlog instead. |
| `MAINTENANCE_MIN/MAX/USER_CAP`, `LOAD_GAP_UNIT` | Superseded by `MAINT_BASE/DENSITY/GAP_UNIT/MAX_SCAN`. |
| Separate `FullLiquidated` / `SoftLiquidated` / `BadDebtCovered` events | Unified into one `Liquidated(...)` event carrying every field, plus `MaintenanceSwept`. |
| `emergencySwept`, `EMERGENCY_GRACE_PERIOD` enforcement | No sweep exists; grace constant kept only for UX/telemetry. |

## MathLib

`3.0.0-staking` is byte-for-byte the same maths as `2.0.0-staking` (which added `rawBalanceOf`
over `1.0.0-staking`). `rawBalanceOf` is what lets the contract read its own physical balance for
the conservation guard and the public solvency views. No functional change vs v2; version bump
only, to track alongside the contract.

---

## Conservation through liquidation (proof sketch)

`_autoMaintain` and `liquidate` must not break `conserves`. They don't, because every sub-step
preserves the identity:

- **Paying a user their pending reward `due`:** balance `−due`; `owed` `−due` (via
  `totalRewardsPaid += due`). Net zero.
- **Healthy liquidation (no bad debt):** `Δ(totalStaked − totalDebt) = −bonus`, and `bonus` is
  paid to the keeper, so balance `−bonus`. Net zero.
- **Liquidation with bad debt:** `Δ(totalStaked − totalDebt) = +badDebt`,
  `ΔprotocolReserve = −covered`, `ΔtotalBadDebt = +(badDebt − covered)`; sum into `_owed()` = 0,
  and no tokens move (keeper bonus is 0). Net zero.

So each maintenance step is conservation-neutral, and the wrapping `conserves` guard on the outer
user action always passes.
