# BlazePhoenix Staking — v3 (Autonomous + Provably Solvent)

Single-asset staking + lending where **collateral, borrowed asset, and reward token are all the
same token (BZPX)**. Because there is only one asset, there is **no price oracle anywhere** — an
entire class of attacks simply does not exist.

This is the consolidated final version. It takes the **v2 security core** and adds the two
properties the protocol is now designed around:

1. **100% autonomous maintenance** — the book cleans itself from ordinary user traffic; no keeper
   bot and no admin button are required.
2. **Provable solvency** — anyone can verify, on-chain and for free, that the contract holds at
   least everything it owes.

---

## 1. The Master Conservation Identity (the "supreme" equation)

The whole protocol obeys a single equation at all times:

```
balanceOf(contract) + totalBadDebt
   ==  (totalStaked − totalDebt)                       // net principal physically held
     +  rewardReserve                                  // unspent emission funding
     +  protocolReserve                                // protocol revenue
     +  (totalRewardDistributed − totalRewardsPaid)    // accrued rewards not yet paid
```

The right-hand side is computed by `_owed()`. **Solvency ⇔ `balance ≥ owed`.**

This identity is enforced in two complementary ways:

- **Per-transaction (preventive).** Every value-moving entry-point is wrapped in the `conserves`
  modifier. It snapshots the real balance and `_owed()` before the body, and afterwards requires
  that the *change* in the real balance equals the *change* in what the protocol owes (within a
  `1e10` wei dust tolerance for rounding). Any transaction that would leak value — i.e. let the
  ledger claim more than the contract holds — **reverts atomically**. An insolvent state is
  *unreachable*, not merely observable. Crucially this checks the *delta*, so historical dust
  drift can never DoS a legitimate user.

- **Intrinsic, not keeper-driven.** Conservation is enforced *by the protocol's own
  transactions* — the `conserves` guard above. It does **not** rely on any external watcher to
  notice a breach and react; a breach is *unreachable* through normal flow, not something a keeper
  must race to catch.
- **Permissionless breaker — but only on proven insolvency.** `tripBreaker()` lets **anyone** halt
  the protocol, but *only* when the chain itself proves insolvency: it requires `_hardBreach()`
  (`balance + dust < owed`), an objective, un-spoofable on-chain condition. Nobody can lower the
  contract's balance except through flows that lower `owed` by the same amount, and donations only
  raise it — so the breaker can fire **only on a genuine shortfall** (a real bug/theft or a
  token-level failure), never on healthy state. It is **reversible**: if the reading was transient,
  the admin calls `cancelEmergency()` once `_hardBreach()` clears, so the worst a spurious trip can
  do is a temporary, admin-undoable pause — not a permanent freeze.
- **Discretionary halt (guardian).** Independently, the **GUARDIAN** may call `declareEmergency()`
  for an issue discovered off-chain (no on-chain breach required).

### Verify it yourself (no trust required)

| Function | Returns |
|---|---|
| `isSolvent()` | `true` iff `backing ≥ owed` |
| `backing()` | physical BZPX the contract holds right now |
| `owed()` | what the ledger says it owes |
| `collateralRatio()` | `backing / owed` in WAD (`1e18` = exactly solvent, `>1e18` = surplus) |
| `solvency()` | one struct with every term of the identity, so the caller can re-derive the equation |
| `auditInvariants()` | 5-bit health mask for off-chain monitors |

`solvency()` returns: `backing, owed, surplus, deficit, solvent, collateralRatioWad, totalStaked,
totalDebt, rewardReserve, protocolReserve, pendingDistribution, totalBadDebt,
totalUncollectedInterest`. A wallet, dashboard, or watchdog can read it in a single call.

---

## 2. 100% autonomous maintenance

There is **no keeper requirement and no governance knob**. Every ordinary user transaction
(`deposit / borrow / repay / withdraw / claimRewards / claimPureYield / lock / pokeExpiredLock`)
ends by calling `_autoMaintain`, which:

- walks a **rotating window** of borrowers from a persistent cursor;
- **liquidates** anything underwater and pays the seizure surplus to whoever carried the gas;
- **keeps every scanned position fresh** — accrues its interest, expires stale locks, and resyncs
  its boost weight — so the global reward denominators never drift from reality.

The window **self-sizes** with backlog pressure via `_maintBudget()` — a *pure function of
on-chain state*, no admin input:

```
scan = clamp( MAINT_BASE
            + borrowers / MAINT_DENSITY            // more borrowers  -> wider scan
            + secondsSinceLastSweep / MAINT_GAP_UNIT,  // longer idle   -> wider scan
            0, MAINT_MAX_SCAN )                    // hard per-tx ceiling -> bounded gas
```

So under heavy load or after a quiet period the sweep widens automatically, but per-transaction
gas is always bounded by `MAINT_MAX_SCAN`. Inspect the next budget with `maintenanceBudget()`.

**Safety:** `_autoMaintain` is disabled while paused or in emergency, so a borrower who cannot act
can never be liquidated by someone else's transaction. The permissionless `liquidate(user)` keeper
path remains for anyone who wants to target a position directly — bots *and* organic flow both keep
the book clean, so liveness never depends on keepers alone.

---

## 3. Staking is always locked (day-based, with a countdown)

There is no liquid staking — **every deposit is a locked commitment** measured in days:

- `deposit(uint256 amount, uint256 lockDays)` — `lockDays` is **min 90, max 2555 (7 years)**.
- A **decreasing countdown** caps every lock at the days remaining until the 7-year emission end
  (`maxLockDaysAvailable()`), so **no lock can ever outlast emission**. Early on you can lock up to
  the full 7 years; with, say, 2 years left, the max is ~730 days; in the final 90 days new
  deposits/locks are unavailable (the 90-day floor would cross the end).
- **Top-ups can only extend, never shorten.** If the chosen duration would land *before* your
  current unlock, the longer existing lock is kept and the new funds inherit it. To push your
  unlock later, pass a longer `lockDays`.
- Boost is **continuous** in the committed duration: `boost(d) = 10000 + 750·(d/365) + 250·(d/365)²`
  bps (90d ≈ 1.02×, 1y = 1.10×, 7y = 2.75×).
- **Withdrawal requires the lock to have expired *and* the position to be DEBT-FREE.** A borrower
  must repay everything before withdrawing any stake (`Staking__HasDebt`). There is no
  early-exit-with-debt path, and therefore **no exit penalty**.

`lock(uint256 lockDays)` also exists to extend an existing commitment without depositing. Inspect
with `lockInfoOf(user)`, `timeUntilUnlock(user)`, `maxLockDaysAvailable()`, `boostByDays(days)`.

---

## 4. Other v2 security properties (retained)

- **Single-writer boost accounting** (`_applyBoost`): the *only* writer of the boosted-total
  denominators. Plain checked subtraction means any desync reverts instead of corrupting state.
  Even the emergency hatch funnels through it — no ghost shares.
- **Zero backdoor:** no admin sweep of principal; reserve withdrawals go *only* to an **immutable
  treasury**, with no caller-chosen destination.
- **Pull-only emergency:** `emergencyWithdraw()` returns your net equity (`staked − debt`) with the
  simplest possible logic and is *not* conservation-guarded, so it works even in a breached state.
- **CEI settlement:** reward/yield debt is written **before** the token transfer.
- **Deterministic emission:** empty-pool intervals advance the clock (emission stays in reserve),
  so a latecomer can never capture an accumulated backlog.
- **Flash-loan guard:** `MIN_DEPOSIT_BLOCKS` between deposit and withdraw/claim/lock.
- **`repay` works while paused** (a borrower must always be able to de-risk).

---

## Economic parameters

| Parameter | Value |
|---|---|
| Total emission | 180,000,000 BZPX, linear over 7 years |
| Max stake / wallet | 30,000,000 BZPX |
| Max LTV (on effective stake) | 50% |
| Liquidation threshold | 95% |
| Liquidation bonus | 5% (paid to the gas-payer) |
| Withdrawal | requires lock expired **and** debt fully repaid (no exit penalty) |
| Reserve factor | 3% |
| Lock duration | **min 90 days, max 2555 days (7 years)**, capped by a decreasing countdown to emission end |
| Lock boost | `boost(d) = 10000 + 750·(d/365) + 250·(d/365)²` bps → 90d ≈ 1.02×, 1y = 1.10×, 5y = 2.00×, 7y = 2.75× |
| Interest curve | kinked at 80% utilisation (1%→5% base, steep above) |

---

## Build & verify

```bash
npm install                # solc 0.8.28 + @openzeppelin/contracts
node compile.js            # standalone compile check (viaIR + optimizer)
# or, with Foundry:
forge build                # uses foundry.toml (via_ir = true)
```

`viaIR` is required (the rich `getUserInfo` / `solvency` views exceed the legacy stack).

---

## Layout

```
src/BlazePhoenixStaking.sol   final staking + lending contract  (VERSION "3.0.0")
src/BlazePhoenixMathLib.sol   512-bit mulDiv + raw token calls   (VERSION "3.0.0-staking")
```

## Licence & Whitepaper

- **Licence:** [BUSL-1.1](./LICENSE) — Change Date 2030-06-01, then GPL-2.0-or-later
- **Whitepaper:** [docs/WHITEPAPER.md](./docs/WHITEPAPER.md)
