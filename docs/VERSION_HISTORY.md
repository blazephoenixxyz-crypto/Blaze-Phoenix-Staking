# Version history & completeness map

This file tracks exactly what changed across the three versions so nothing is silently lost
between them.

## Summary

| Version | Contract | MathLib | Theme |
|---|---|---|---|
| v1 | `1.1.0` | `1.0.0-staking` | Feature-rich; offline audit only; admin sweep + admin liquidation |
| v2 | `2.1.0` | `2.0.0-staking` | Security core: on-chain conservation guard, permissionless liquidation, no backdoor |
| **v3 (final)** | **`3.0.0`** | **`3.0.0-staking`** | v2 core **+** fully autonomous maintenance **+** public solvency proofs |

v3 = **v2 base**, with the two requested additions and the useful UX views that v2 had dropped
from v1 re-added.

---

## What v3 keeps from v2 (the security core)

- `conserves` per-transaction value-conservation guard on every value-moving entry-point.
- `_owed()` Master Conservation Identity; `_hardBreach()` (read-only solvency check used by views
  and `cancelEmergency`).
- Single-writer boost accounting (`_applyBoost` / `_computeBoost` / `_resync` / `_checkpoint`).
- Permissionless, keeper-incentivised `liquidate(user)`.
- Immutable `treasury`; `withdrawReserve` cannot pick a destination; **no principal sweep**.
- Pull-only emergency (`declareEmergency` / `cancelEmergency` / `emergencyWithdraw`);
  **no `sweepRemaining` backdoor**.
- CEI settlement (`rewardDebt` written before transfer).
- Deterministic emission (`tbe == 0` advances the clock).
- `repay` callable while paused; `withdraw` callable while paused, blocked under emergency.

## Where v3 deliberately DIVERGES from v2

- **Removed the permissionless `tripBreaker()`.** v2 let *anyone* flip the contract into emergency
  mode whenever `_hardBreach()` read true. That is a griefing lever: any path (rounding drift, a
  token-level quirk, a transient mis-read) that makes the breach condition true even once would let
  an attacker freeze the protocol permanently. It also added no real safety, because **conservation
  is already enforced intrinsically** by the `conserves` guard on every value-moving transaction —
  an unconservative state is unreachable, so there is nothing for a keeper to "catch". v3 keeps
  conservation intrinsic and makes the only halt path GUARDIAN-only (`declareEmergency`). Solvency
  remains publicly *observable* (`isSolvent` / `solvency` / `auditInvariants`) but never *actionable*
  by third parties. The `Staking__NoBreach` error and the `permissionless` field of
  `EmergencyDeclared` are removed with it.

  Note: `liquidate(user)` and the autonomous maintenance sweep stay permissionless — that is
  *liquidation* (keeping positions healthy), not the conservation breaker, and keeper/organic
  participation there is desirable.

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
- `pureStakerApr(uint8)`
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
