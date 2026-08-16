# Version history & completeness map

This file tracks exactly what changed across the three versions so nothing is silently lost
between them.

## Summary

| Version | Contract | MathLib | Theme |
|---|---|---|---|
| v1 | `1.1.0` | `1.0.0-staking` | Feature-rich; offline audit only; admin sweep + admin liquidation |
| v2 | `2.1.0` | `2.0.0-staking` | Security core: on-chain conservation guard, permissionless liquidation, no backdoor |
| v3 | `3.0.0` | `3.0.0-staking` | v2 core **+** fully autonomous maintenance **+** public solvency proofs |
| v3.1 | `3.1.0` | `3.0.0-staking` | v3 **+** lock expiry priced against the clock **+** the locker maintenance window |
| **v4 (final)** | **`4.0.0`** | **`3.0.0-staking`** | v3.1 **+** final tokenomics: 180M biennial-halving emission, closed-form O(1) |
| **v4 hardened** | **`4.0.0`** | **`3.0.0-staking`** | v4 **+** terminal-distress round: floor-free `conserves`, index-coupled clamp, 75% aggregate util cap, pro-rata emergency haircut, honest telemetry |

v3 = **v2 base**, with the two requested additions and the useful UX views that v2 had dropped
from v1 re-added.

---

## v4 hardened — the terminal-distress round (August 2026)

An internal adversarial pass (devil's-advocate review, two independent skeptics) plus one
external disclosure, all in the regime the original suites under-visited: **interest erosion
carried to the end of the book**. No contract version bump — same ABI, same economics in every
healthy state; every change below only alters what happens when `totalStaked` approaches or
reaches exhaustion, or what the published telemetry says there.

- **LIQ-01 — floor-free `conserves`.** The guard now compares the delta of the identity in the
  rearrangement `balance + totalDebt + totalBadDebt == totalStaked + RR + PR + pending`, with
  no `max(x,0)` anywhere. The old `_owed()`-based check crossed its floors in terminal distress
  and reverted legitimate bad-debt liquidations, repayments and accrual — freezing the recovery
  tools exactly when they were needed.
- **C-03 — per-user clamp reconcile.** When a position's accrued charge exceeds its remaining
  stake, the uncollectible shortfall is restored to `totalStaked` and recorded as
  `totalBadDebt`, keeping `totalStaked == Σ u.staked` (honest utilisation, honest solvency,
  honest haircut denominator, no withdraw underflow freeze).
- **Index-coupled clamp.** When the global slice clamp binds, the per-debt index advance is
  re-derived from the clamped slice, and the global debit re-derived from the floored index
  advance — `Σ per-user charges == global debit` in every regime. The healthy path is
  bit-identical to pre-fix. (Three commits: the coupling, the bind-only restriction after both
  CI suites caught healthy-regime rounding drift, and the floor-dust re-derivation after the JS
  attack suite caught a checked-underflow re-freeze on non-dividing books.)
- **H-04 — aggregate utilisation cap.** `borrow()` reverts past 75% aggregate utilisation,
  below the 80% kink: no borrow can push the whole protocol into the steep branch.
- **H-05 — pro-rata emergency haircut.** In a breached emergency, `emergencyWithdraw` scales
  payouts by `pot/claims` (exit-order invariant); solvent operation pays full equity unchanged.
- **Honest telemetry.** `utilizationRate`/`getGlobalStats`/`auditInvariants`/the rate function
  clamp utilisation to WAD and report the terminal state as maximum distress, never as floor
  rate + 0% utilisation + no violation.
- **BP-2026-008 (external, NetGakarot).** The lock-expiry window no longer inherits the
  borrower window's self-exclusion: normalising your own expired boost pays nothing, so
  skipping the beneficiary only let an active user keep an expired boost alive with their own
  traffic.

Regression anchors: `HardeningH04_UtilCap.t.sol`, `HardeningH05_EmergencyHaircut.t.sol`, and
the JS attack suite's single-window self-liquidation on a non-dividing book (1,000,000/499,000)
for the rounding-dust path. Foundry 57/57 across 10 suites; Node harness 9/9 suites green.

---

## v4 — final tokenomics: the biennial-halving emission curve

The only economic change: the schedule moves from **180M linear over 7 years** to **180M on a
biennial-halving curve** — period `p` (0-indexed, 2 years each) emits `90M >> p`, so
Σ 90M/2ᵖ = 180M exactly by construction. Chosen over the linear schedule because a flat curve
ends in a cliff (documented mercenary-capital exodus at linear ends), while the geometric tail
fades into the real-yield regime (borrow interest + DEX fee-share) with no magic date.

Mechanics:

- Cumulative emission is **closed-form O(1)** — one division, two shifts, one multiplication;
  no loop, no oracle, no exp/log:
  `emitted(t) = (TOTAL − (TOTAL >> p)) + (R0 >> p)·(t − start − p·PERIOD)`, `p = ⌊(t−start)/PERIOD⌋`.
- `_updateGlobal` integrates the **delta** of that curve per window, replacing the flat
  `REWARD_PER_SEC × elapsed` term. Everything else in the accumulator is untouched.
- The programme **hard-closes after 8 periods (16 years)**: 255/256 of the budget
  (179,296,875 BZPX) emitted, running rate < 0.8% of initial — a fade, not a cliff. The exact
  `180M >> 8 = 703,125 BZPX` residue is recoverable via the pre-existing
  `sweepUndistributedEmission`, pro-protocol.
- Rounding is always pro-protocol: the floored rate's sub-wei remainder (< 1e-10 BZPX per
  rollover) folds into the `TOTAL − (TOTAL >> p)` term, keeping the curve on the exact series.

Surface changes:

- Constants: `EMISSION_PERIOD` / `REWARD_PER_SEC` → `HALVING_PERIOD`, `EMISSION_PERIODS`,
  `EMISSION_LENGTH`, `INITIAL_REWARD_PER_SEC`.
- New view `emittedAt(timestamp)` exposes the curve for free on-chain verification (same ethos
  as `solvency()`); `emissionProgress()` now reports emitted/TOTAL (the curve, not the clock).
- `MAX_LOCK_DAYS` stays 2555 — now a policy cap (the boost curve and its overflow proof are
  calibrated on d ≤ 2555), no longer equal to the programme length. `maxLockDaysAvailable()`
  stays pinned at 2555 until fewer than 2555 days remain to the 16-year close.

**Untouched, verified by the existing suites:** the Master Conservation Identity and the
`conserves` guard, deterministic no-backlog-capture emission (empty windows advance the clock;
their emission strands in `rewardReserve`, recoverable), the `MIN_EMISSION_WEIGHT` throttle, CEI
settlement, the autonomous maintenance engine, and the whole lock/boost model.

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
