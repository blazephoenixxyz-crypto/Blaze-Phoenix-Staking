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
  notice a breach and react. There is deliberately **no permissionless circuit-breaker**: a public
  "trip on breach" button would be a griefing lever (a single spurious breach reading could let
  anyone freeze the protocol forever), and it would add no safety the intrinsic guard doesn't
  already provide. A breach is therefore *unreachable* through normal flow, not something a keeper
  must race to catch.
- **Discretionary halt (guardian only).** For an issue discovered off-chain, the **GUARDIAN** —
  and only the guardian — may call `declareEmergency()` to halt. Solvency stays publicly
  *observable* by anyone via the views below, but only the guardian can *act* on it.

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

## 3. Other v2 security properties (retained)

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
| Early-exit fee | 5% |
| Reserve factor | 3% |
| Lock tiers | `boost(t) = 10000 + 750t + 250t²`, t∈[0,6] → 1.00×…2.35× |
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

> Licence: BUSL-1.1.
