# BlazePhoenix Protocol — Technical Whitepaper

**Version 3.2.0 · August 2026**

> **Security credit — BP-2026-001.** §3.3 and §4.2.1 exist because of a finding disclosed on
> 28 July 2026 by **[NetGakarot](https://github.com/NetGakarot)** ("Gakarot"): the maintenance
> sweep iterated the borrower registry only, and a pure staker (`debt == 0`) is never in it, so an
> idle staker whose lock had expired retained its historical boost in the global reward
> denominators indefinitely. Solvency was never reachable — boost is a denominator weight, never a
> claim on value — but the distribution was unfair and the incentive to re-lock was destroyed.
>
> **Security credit — BP-2026-008.** The final paragraph of §3.3 exists because of a second
> finding by the same researcher: the lock-expiry window originally excluded the transaction's
> own `beneficiary` the way the borrower window does, so a position could keep its expired boost
> alive indefinitely by being the one that carries the maintenance traffic. The exclusion is
> correct for liquidations (you must not earn the keeper bonus on yourself) and wrong for lock
> normalisation (releasing your own lapsed weight pays nothing) — the two windows now differ
> deliberately, and the difference is documented in the code.

*Document 3.2.0 covers the August 2026 terminal-distress hardening round (contract `4.0.0`):
the floor-free conservation identity (§2.2), the aggregate utilisation cap (§5.2), the
index-coupled interest clamp (§5.3), and the pro-rata emergency haircut (§7.6).*

---

## Abstract

BlazePhoenix is a single-asset staking and lending protocol built on Ethereum.
It introduces three properties that, to the authors' knowledge, have not previously
been combined in a deployed protocol:

1. **Per-transaction conservation enforcement** — every value-moving entry-point
   carries a mathematical proof that the protocol's real token balance changed by
   exactly the same amount as what the ledger says it owes, making an insolvent
   state *unreachable through normal flow*, not merely *observable after the fact*.

2. **Fully autonomous maintenance** — liquidations, interest accrual, lock expiry,
   and boost-weight synchronisation are driven entirely by ordinary user
   transactions, with a scan budget that self-sizes from a pure function of
   on-chain state. There is no keeper requirement and no governance parameter.

3. **Oracle-free, provably solvent lending** — because collateral, borrowed asset,
   and reward token are all the same (BZPX), there is no price oracle anywhere.
   Solvency is a public, on-chain, trust-free read.

---

## 1. Background and Motivation

### 1.1 The oracle problem

Price oracles are the single largest attack surface in DeFi. Manipulation of a
Chainlink feed, a TWAP, or a spot price can drain a lending protocol in one
block. The conventional response — using multiple oracles, time-weighted
averages, or circuit-breakers — adds complexity and shifts, but does not
eliminate, the risk.

BlazePhoenix eliminates the problem at the source: by lending the same asset
that is staked, there is no cross-asset price to observe. The LTV is computed
entirely in BZPX units. No oracle, no manipulation surface.

### 1.2 The keeper problem

Most DeFi protocols require a network of off-chain keeper bots to stay healthy.
Keepers liquidate undercollateralised positions, harvest yield, and maintain
accounting accuracy. When keeper incentives misalign — during gas spikes, market
crashes, or periods of low activity — the protocol degrades. This is a systemic
liveness dependency.

BlazePhoenix removes keeper bots as a requirement. Maintenance is carried by
the organic flow of user transactions through a bounded, rotating scan.

### 1.3 The trust problem

A user interacting with a lending protocol cannot easily verify that it is
solvent. They must trust the team, the audit, or an off-chain dashboard. None
of these is trustless.

BlazePhoenix makes solvency a public, on-chain, single-call read available to
any address at any time.

---

## 2. The Master Conservation Identity

The entire accounting of the protocol obeys one equation at all times:

```
balanceOf(contract) + totalBadDebt
    =  (totalStaked − totalDebt)
     + rewardReserve
     + protocolReserve
     + (totalRewardDistributed − totalRewardsPaid)
```

The right-hand side is `_owed()`. **Solvency is equivalent to `balance ≥ owed`.**

### 2.1 Term-by-term explanation

| Term | Meaning |
|---|---|
| `balanceOf(contract)` | Physical BZPX the contract holds right now (raw `staticcall`, not a ledger variable) |
| `totalBadDebt` | Recorded losses from liquidations where `stake < debt` |
| `totalStaked − totalDebt` | Net principal: stakers' capital minus what has been lent out |
| `rewardReserve` | Emission funding deposited by admin but not yet distributed |
| `protocolReserve` | Revenue accrued from the reserve factor (3% of interest) |
| `totalRewardDistributed − totalRewardsPaid` | Rewards earned by stakers but not yet transferred |

### 2.2 The `conserves` modifier

Every value-moving public function — `deposit`, `borrow`, `repay`, `withdraw`,
`claimRewards`, `claimPureYield`, `lock`, `fundEmission`, `withdrawReserve` — is
wrapped in the `conserves` modifier:

```solidity
modifier conserves() {
    uint256 lhsBefore = ML.rawBalanceOf(bzpx, address(this)) + totalDebt + totalBadDebt;
    uint256 rhsBefore = totalStaked + rewardReserve + protocolReserve + _pendingDistribution();
    _;
    // revert Staking__InvariantBreached() unless |Δlhs − Δrhs| ≤ CONSERVATION_DUST
}
```

The guard compares the delta of the Master Conservation Identity in its **floor-free
rearrangement** — every term moved to the side that keeps it a plain non-negative state
variable, summed without any `max(x, 0)`:

```
balance + totalDebt + totalBadDebt
    =  totalStaked + rewardReserve + protocolReserve
     + (totalRewardDistributed − totalRewardsPaid)
```

This is algebraically the same equation as §2, but the arrangement matters. The public
`_owed()` view floors two of its intermediate subtractions so it can never report a negative
number. Inside the guard those floors are non-linearities: in terminal distress (interest
erosion has consumed the book) a legitimate bad-debt liquidation, repayment, or interest
accrual crosses a floor boundary and reads as a value leak — the guard would revert exactly
the recovery tools the distressed state needs. The floor-free form is linear in every regime,
so the guard never confuses distress with theft (finding LIQ-01, August 2026 hardening round).

The check is over the **delta**, not the absolute value. Formally:

```
|Δlhs − Δrhs| ≤ CONSERVATION_DUST
```

Checking the delta rather than the absolute value is critical for two reasons:

- **DoS prevention.** If the check were absolute (`balance ≥ owed`) and dust had
  accumulated historically (e.g. 1 wei from a rounding error months ago), the
  check could block every future transaction even though no real loss occurred.
  The delta check cancels historical drift algebraically.

- **Leak detection.** Any transaction that moves value in a way not reflected in
  the ledger — for example, a re-entrancy that claims rewards twice, or an
  accounting bug that credits a user without receiving tokens — will make the two
  sides of the identity diverge and revert atomically.

### 2.3 Public solvency surface

Anyone can verify the protocol on-chain at any time:

```solidity
isSolvent()          // bool: balance + dust ≥ owed
backing()            // uint256: physical BZPX held
owed()               // uint256: what the ledger says is owed
collateralRatio()    // uint256 WAD: backing / owed (1e18 = exactly solvent)
solvency()           // SolvencyReport: full picture in one call
auditInvariants()    // uint8: 5-bit health mask for monitors
```

`solvency()` returns every term of the Master Conservation Identity so any
caller can re-derive the equation independently without trusting the protocol.

### 2.4 The permissionless circuit-breaker

`tripBreaker()` lets any address halt the protocol — but **only** when the chain
itself proves insolvency:

```solidity
function tripBreaker() external {
    if (emergencyMode) revert Staking__EmergencyActive();
    if (!_hardBreach()) revert Staking__NoBreach();
    ...
}

function _hardBreach() internal view returns (bool) {
    return ML.rawBalanceOf(bzpx, address(this)) + CONSERVATION_DUST < _owed();
}
```

The condition `_hardBreach()` is **objective and un-spoofable**: no address can
reduce `rawBalanceOf(contract)` without going through a flow that reduces `_owed`
by the same amount (token transfers out only happen inside functions protected by
`conserves`). Donations raise the balance without raising `owed`. Therefore the
condition can be true only if the protocol has a genuine shortfall — a real bug,
theft, or token-level failure.

The breaker is also **reversible**: if the reading was transient, the admin calls
`cancelEmergency()` once `_hardBreach()` clears. The worst a spurious trip can do
is a temporary, admin-undoable pause.

---

## 3. Autonomous Maintenance

### 3.1 The scan budget

After every ordinary user transaction, the protocol runs `_autoMaintain`. The
number of positions it will scan is determined by `_maintBudget()`:

```
budget = clamp(
    MAINT_BASE
  + len(borrowers) / MAINT_DENSITY
  + secondsSinceLastSweep / MAINT_GAP_UNIT,
  0,
  MAINT_MAX_SCAN
)
```

| Constant | Value | Meaning |
|---|---|---|
| `MAINT_BASE` | 1 | Every transaction scans at least 1 borrower |
| `MAINT_DENSITY` | 50 | +1 scan per 50 active borrowers |
| `MAINT_GAP_UNIT` | 15 minutes | +1 scan per 15-minute idle gap |
| `MAINT_MAX_SCAN` | 10 | Hard per-tx ceiling — gas is always bounded |

This is a **pure function of on-chain state**. There are no governance parameters,
no admin knobs, no off-chain inputs. The schedule self-tunes: under heavy borrower
load or after a quiet period, the window widens automatically. Under light load it
contracts to save gas.

### 3.2 What the scan does

For each position in the window:

1. **Accrue interest** — update the position's debt for elapsed time.
2. **Check liquidatability** — if `debt * 100 ≥ stake * LIQ_THRESHOLD`, liquidate.
   - The seizure surplus (above the debt) is transferred to the user whose
     transaction carried the gas (the `beneficiary`). Liveness incentive is built in.
3. **If not liquidatable** — settle pending emission rewards and pure yield, expire
   stale locks, and resync the boost weight. The global denominators never drift.

### 3.3 The second window: expired locks on debt-free positions

The borrower registry is, by construction, blind to a **pure staker** (`debt == 0`) — precisely the
class whose lock expiry nothing else would ever normalise. A second registry, `_lockers`, tracks
every position holding a live commitment and receives its own rotating, gas-bounded window in the
same sweep. Any entry whose commitment has elapsed is normalised on the spot:

1. **Settle first** — emission rewards and pure yield are paid at the weight they were actually
   earned at. Everything accrued while the commitment was live was genuinely earned at the boosted
   weight; only the *future* is re-priced. The correction never confiscates.
2. **Release** — `_processLockExpiry` clears the lock, `_resync` recomputes the weight at 1.00×
   through the single writer, and the entry is de-registered.

A locker *probe* costs two storage slots; a normalisation does not. The two are therefore budgeted
separately — probes rotate the cursor under the shared `MAINT_MAX_SCAN` cap, normalisations carry
their own tighter `MAINT_MAX_LOCK_ACTIONS` ceiling — and a probe that finds work does not consume
probe budget, because the cursor holds on the swap-pop. A *cluster* of simultaneous expirations
therefore drains several per transaction, while a registry with nothing to do costs almost nothing.
Worst case per transaction is `MAINT_MAX_SCAN + MAINT_MAX_LOCK_ACTIONS` iterations, unconditionally.

`expiredLockScan(offset, limit)` measures the outstanding backlog on-chain with no indexer;
`pokeExpiredLock(user)` and `pokeExpiredLocks(users)` let anyone clear it at their own gas cost.

Unlike the borrower window, this window **does not skip the transaction's own beneficiary**,
and the asymmetry is deliberate (BP-2026-008). The borrower sweep excludes the beneficiary
because liquidating your own position would pay you the keeper bonus. Normalising your own
elapsed commitment pays nothing — it only releases weight the position is no longer entitled
to — so excluding the beneficiary here would let an active user keep their expired boost alive
indefinitely *precisely by being the one whose transactions carry the maintenance*.

### 3.4 Failure isolation

Each per-borrower step runs through an internal self-external call (`maintStep`, callable
only by the contract itself) wrapped in `try/catch`. If a single position cannot be processed —
for example, if the BZPX token refused to pay a specific borrower — that step is rolled back
atomically and skipped, the cursor advances so the sweep never stalls, and **the innocent
user's own transaction still succeeds**. A poisoned position can never become a denial-of-service
vector against the rest of the protocol. (See §7.7 for the token assumption this defends.)

### 3.5 Why this is sufficient

A position becomes liquidatable only after interest has eroded `stake` to within
`LIQ_THRESHOLD` (95%) of `debt`. The kinked interest rate (max ~730% APR above
80% utilisation) is the aggressive case. Even at 730% APR, a position at 50% LTV
takes approximately `(1 - 0.95/0.5) * 365 / 7.3 ≈ 0` days — meaning positions at
maximum LTV are immediately liquidatable if interest is at the extreme rate. At
normal rates (3–5% APR) a 50% LTV position has months of runway.

In all cases, organic user traffic will scan the position well within any
reasonable liquidation window, given that the scan window widens proportionally
to idle time.

---

## 4. Mandatory Locked Staking

### 4.1 Lock mechanics

Every deposit requires a lock duration in days:

```solidity
deposit(uint256 amount, uint256 lockDays)
```

- **Minimum:** 90 days
- **Maximum:** 2555 days (7 years)
- **Countdown cap:** `min(MAX_LOCK_DAYS, daysUntilEmissionEnd)` — no lock can
  outlast the 7-year emission window
- **Extends-only:** a top-up may only push the unlock later, never earlier

There is no liquid staking mode.

### 4.2 Boost curve

The lock duration grants a multiplicative boost on reward weight:

```
boost(d) = 10000 + 750·(d/365) + 250·(d/365)²   [basis points]
```

| Lock | Boost |
|---|---|
| 90 days | ~1.020× |
| 1 year | 1.100× |
| 2 years | 1.250× |
| 5 years | 2.000× |
| 7 years | 2.750× |

The quadratic term accelerates reward for long commitments. The curve is
continuous — any day count between 90 and 2555 is valid.

#### 4.2.1 Boost is the price of illiquidity, and it expires on time

The multiplier is compensation for capital the holder **cannot withdraw**. The instant
`block.timestamp >= unlockTime` that capital is liquid again, so the effective commitment is
0 days and the multiplier is 1.00× — regardless of whether stored state has been updated yet:

```solidity
function _effectiveLockDays(UserInfo storage u) internal view returns (uint256) {
    if (u.lockDays == 0) return 0;
    return block.timestamp >= u.unlockTime ? 0 : uint256(u.lockDays);
}
```

Every boost in the protocol is derived through this function, so no code path — present or future —
can re-price a lapsed commitment at its historical multiplier. The public views agree: 
`lockInfoOf().boostBps` and `getUserInfo().boostBps` report what a position is **paid** at and read
`10000` the moment a lock lapses, while `lockDays` / `unlockTime` continue to report the commitment
on record.

Real-time derivation and the §3.3 sweep are **jointly** necessary. Derivation alone only re-prices a
position somebody already touched — which an idle staker never is. The sweep alone would leave the
stale multiplier re-derivable in the window between expiry and normalisation. Together they make
stored state and tracked weight structurally unable to diverge, since `_resync` — the sole path by
which any boost weight is ever written — now processes expiry itself.

### 4.3 Withdrawal requires full repayment

```solidity
if (u.debt != 0) revert Staking__HasDebt();
```

A position cannot be partially withdrawn while carrying debt. There is no
early-exit-with-penalty path. This removes the incentive to attack the protocol
through partial collateral withdrawal and simplifies the solvency proof.

---

## 5. Lending

### 5.1 Oracle-free LTV

Because collateral and borrowed asset are both BZPX, the Loan-to-Value ratio
needs no price feed:

```
maxBorrow = (staked − currentDebt) × MAX_LTV / 100
```

`MAX_LTV = 50%`. Borrowing is on *effective* stake (net of existing debt).

### 5.2 Interest rate model

The protocol uses a kinked interest rate curve:

```
if utilisation ≤ 80%:  rate = R0 + util × S1/WAD
else:                   rate = RK + (util − 0.80) × S2/WAD
```

| Parameter | Value |
|---|---|
| `R0` (base rate) | 1% APR |
| `RK` (kink rate) | 5% APR |
| `S1` (slope below kink) | 5% per unit utilisation |
| `S2` (slope above kink) | 725% per unit utilisation |

Above 80% utilisation the rate rises steeply, incentivising repayment and
disincentivising further borrowing.

#### 5.2.1 Aggregate utilisation cap

`borrow()` additionally reverts (`Staking__UtilTooHigh`) whenever the **aggregate** book after
the borrow would exceed `MAX_PROTOCOL_UTIL_WAD = 75%` — deliberately below the 80% kink. No
act of borrowing, by anyone, can push the whole protocol into the steep interest branch; that
branch remains reachable only through interest erosion over time, which is the scenario it
exists to price. This is defence in depth on top of the per-position LTV bound (§5.1): the
individual bound limits a position, the aggregate cap limits the book. When a repayment brings
utilisation back under the cap, borrowing headroom reopens for every participant — the cap is
a property of the aggregate, not a per-account penalty.

#### 5.2.2 Telemetry never understates distress

If interest erosion ever drives `totalStaked` to zero with debt still outstanding, the naive
utilisation reading (`debt/staked`) is undefined, and an earlier revision reported that
terminal state as floor rate, 0% utilisation, and no invariant violation. The views
(`utilizationRate`, `getGlobalStats`, `auditInvariants`, and the rate function itself) now
clamp utilisation to 100% (`WAD`) and report maximum distress as maximum distress, matching
the public `simulateRate`. No UI reading the published surface can understate the real rate.

### 5.3 Interest accrual

Interest reduces the borrower's `staked` balance (not a separate debt counter).
Accrual is driven by a global per-debt index, `accInterestPerDebt`: each elapsed
window is stamped with the rate that actually prevailed across it (the index is
advanced **before** any write that could move the rate), the whole book's slice is
debited from `totalStaked` in the same step, and each position is later charged its
share of the index growth it lived through:

```
δ     = rate × elapsed / SECONDS_PER_YEAR          (index advance, WAD)
slice = ⌊totalDebt × δ / WAD⌋                       (global debit)
interest_i = ⌊debt_i × Δindex_i / WAD⌋              (per-user charge, on touch)
```

Of the interest collected:
- **3% reserve factor** → `protocolReserve` (admin can withdraw to immutable treasury)
- **97%** → distributed to pure stakers (debt-free positions) as `accPureYieldPerShare`

Distribution and collection move in the same atomic step, so the ledger never
claims more than the contract holds.

#### 5.3.1 The terminal-distress clamp is coupled to the index

The global debit can never exceed what remains: `slice` is clamped to `totalStaked`.
The hardening round showed that the clamp is only sound if the **index advance is
re-derived from the clamped slice** (`δ = ⌊slice × WAD / totalDebt⌋`) and the debit
then re-derived from that floored `δ` again. Uncoupled, the per-user charges (computed
off the full `δ`) sum to more than was globally debited; re-floored only once, the
rounding dust is debited globally but attributable to no position, `totalStaked` lands
below `Σ staked_i`, and the next liquidation hits a checked underflow — re-freezing
recovery in exactly the state it exists for. With both re-derivations,
`Σ per-user charges == global debit` in every regime, and the healthy (non-clamped)
path is bit-identical to the original arithmetic.

When a single position's charge exceeds its remaining stake, the position pays what
it has and the uncollectible shortfall is recorded as `totalBadDebt` while being
restored to `totalStaked` (finding C-03) — keeping `totalStaked == Σ staked_i` true,
which the utilisation reading, the solvency views, and the emergency haircut (§7.6)
all depend on. The floor-free `conserves` identity (§2.2) is what lets this
reclassification pass the guard: `+shortfall` on `totalBadDebt` (left side) matches
`+shortfall` on `totalStaked` (right side).

### 5.4 Liquidation

A position is liquidatable when:

```
debt × 100 ≥ stake × LIQ_THRESHOLD   (LIQ_THRESHOLD = 95)
```

The liquidator (or the beneficiary of an autonomous sweep) receives a 5% bonus
above the debt amount, seized from collateral:

```
seized      = min(debt + bonus, stake)
keeperBonus = seized − debt
leftover    = stake − seized
```

Any shortfall (`debt > stake`) is first covered by `protocolReserve`, with the
remainder recorded as `totalBadDebt`.

---

## 6. Emission

### 6.1 Schedule — biennial halving, closed-form O(1)

```
TOTAL_REWARDS          = 180,000,000 BZPX
HALVING_PERIOD         = 2 × 365 days
EMISSION_PERIODS       = 8                                   (programme closes after 16 years)
INITIAL_REWARD_PER_SEC = (TOTAL_REWARDS / 2) / HALVING_PERIOD ≈ 1.427 BZPX/s
```

Period `p` (0-indexed, 2 years each) emits `90M >> p` — 90M in years 1–2, 45M in
years 3–4, 22.5M in years 5–6, and so on. The geometric series sums to 180M
**exactly by construction**: Σ 90M/2ᵖ = 180M.

Cumulative emission is a closed form — one division, two shifts, one
multiplication; no loop, no oracle, no exp/log:

```
emitted(t) = (TOTAL − (TOTAL >> p)) + (R0 >> p) · (t − start − p·PERIOD),
p = ⌊(t − start) / PERIOD⌋
```

The accumulator integrates the **delta** of this curve per window, so every
property of the previous linear schedule (determinism, no backlog capture,
skipped windows staying in reserve) carries over unchanged. The curve is
exposed on-chain as `emittedAt(timestamp)` so anyone can verify it for free.

The programme hard-closes after 8 full periods: by then 255/256 of the budget
(179,296,875 BZPX) is out and the running rate is below 0.8% of the initial
one, so the close is a fade into real yield (borrow interest + DEX fee-share),
not a cliff. The exact residue — `180M >> 8 = 703,125 BZPX` — is recoverable to
the treasury via `sweepUndistributedEmission`, pro-protocol, never pro-user.

Why halving instead of linear: a flat schedule ends abruptly, and the
mercenary-capital exodus at linear cliffs is well documented; a halving tail
halves the peak sell-pressure of an annual-halving curve (45M/yr max) while
keeping twice the incentive horizon.

Rewards are distributed pro-rata to `totalBoostedEffective` (stake × boost,
net of debt) via the standard accumulator pattern.

`fundEmission` is **incremental**: the admin may call it multiple times, and a running counter
`totalEmissionFunded` is hard-capped at `TOTAL_REWARDS`. This removes the one-shot deploy risk
(a wrong first amount is no longer irreversible) while still bounding total emission. Each call is
conservation-safe — the contract's balance and `rewardReserve` rise by the same amount.

### 6.2 Deterministic emission (no backlog capture)

When `totalBoostedEffective == 0` (no stakers), the accumulator is not updated
but `lastRewardTime` **is** advanced:

```solidity
if (tbe == 0) { lastRewardTime = block.timestamp; return; }
```

A latecomer who stakes after an empty period receives zero rewards for that
period. The emission that passed during the empty window stays in `rewardReserve`
and continues to be distributed going forward to active stakers. This prevents
the incentive to wait for backlog accumulation.

---

## 7. Security Properties

### 7.1 No oracle attack surface

The protocol has no price feed. There is nothing to manipulate.

### 7.2 No admin sweep of principal

`withdrawReserve()` is bounded by `protocolReserve` and can only send to the
**immutable** `treasury` address. The admin cannot access staked principal.

### 7.3 Reentrancy

All public state-changing functions carry OpenZeppelin's `ReentrancyGuard`.
All token settlements follow CEI (Checks-Effects-Interactions): the debt/credit
is written to storage before the token transfer.

### 7.4 Flash-loan guard

A minimum of `MIN_DEPOSIT_BLOCKS = 10` blocks must pass between a deposit (or
a repayment that clears debt) and a withdrawal, claim, or lock operation. This
prevents same-transaction or same-block flash-loan attacks.

### 7.5 Single-writer boost accounting

`_applyBoost` is the **only** function that writes to `totalBoostedEffective` and
`totalBoostedPure`. It uses plain checked arithmetic:

```solidity
totalBoostedEffective = totalBoostedEffective
                      - u.trackedBoostedEffective
                      + newBE;
```

If `totalBoostedEffective < u.trackedBoostedEffective`, the subtraction reverts.
This is the correct behaviour: it would mean the global total has drifted below
a single user's contribution, which is impossible in correct operation. A revert
here signals a real bug, not a DoS.

### 7.6 Emergency paths

Two halt paths exist:

| Path | Trigger | Restriction |
|---|---|---|
| `declareEmergency()` | GUARDIAN discretion | Any off-chain reason |
| `tripBreaker()` | `_hardBreach()` proven on-chain | Objective insolvency only |

Both are **pull-only**: `emergencyWithdraw()` returns a user's net equity
(`staked − debt`). No admin can sweep funds.

In a **breached** emergency the contract may physically hold less than the sum of
net equities. Paying full equity first-come-first-served would let early exiters
drain the pot and leave late (and pure) stakers with nothing. `emergencyWithdraw`
therefore scales the payout by the physical pot when — and only when — a real
shortfall exists:

```
payout = equity × pot / claims        (iff pot < claims)
```

where `pot` is the contract's raw balance and `claims` is the sum of remaining net
equities. The fraction is **exit-order invariant**: each exit removes `payout` from
the pot and `equity` from the claims, so `pot/claims` is unchanged for everyone who
follows — no advantage to racing the exit queue. In solvent operation `pot ≥ claims`,
the scale factor is ≥ 1, and every exit pays full equity exactly as before.

Accrued-but-unpaid rewards are **forfeited** on an emergency exit (the hatch does no reward
maths by design). The forfeited amount remains inside the `totalRewardDistributed −
totalRewardsPaid` term of `owed()`, so post-emergency the ledger *overstates* what it owes —
i.e. the error is in the **conservative direction**: the protocol can only look *less* solvent
than it really is, never more. The corresponding tokens stay in the contract as unclaimable
surplus backing.

`cancelEmergency()` requires ADMIN role and that `_hardBreach()` is currently
false. This prevents cancelling while the breach still exists.

### 7.7 Token assumption (deploy invariant)

The protocol assumes BZPX is a **standard, well-behaved ERC-20**:

- **No receiver blacklist / freeze.** A token that can refuse to pay a specific address (USDC-style)
  could otherwise make a borrower un-liquidatable on the direct keeper path. The autonomous path
  is already defended (the `maintStep` try/catch isolates such a position — §3.2), but the direct
  `liquidate(user)` path would revert for the keeper.
- **No transfer pause that can trap the protocol.**
- **No fee-on-transfer / rebasing.** The conservation identity assumes the amount sent equals the
  amount received. A fee-on-transfer token would break the `Δbalance == Δowed` equality.
- **No reentrancy beyond what `nonReentrant` covers.** Transfer hooks are tolerated (every public
  entry-point is `nonReentrant`), but a token actively designed to corrupt accounting is out of scope.

Because BZPX is the protocol's own token, these properties hold by construction. They are listed
here as explicit deploy invariants for any fork or re-deployment against a different asset.

---

## 8. Mathematical Notation Summary

| Symbol | Solidity | Description |
|---|---|---|
| B | `rawBalanceOf(bzpx, address(this))` | Physical balance |
| S | `totalStaked` | Sum of all staked amounts |
| D | `totalDebt` | Sum of all borrowed amounts |
| RR | `rewardReserve` | Unfunded emission |
| PR | `protocolReserve` | Protocol revenue |
| RD | `totalRewardDistributed` | Cumulative emission distributed |
| RP | `totalRewardsPaid` | Cumulative rewards paid out |
| BD | `totalBadDebt` | Recorded liquidation losses |
| O | `_owed()` | `S − D + RR + PR + (RD − RP) − BD` |

**Conservation (floor-free form, as enforced by `conserves`):**
`B + D + BD = S + RR + PR + (RD − RP)` — every term a plain non-negative state
variable; the guard compares the delta of the two sides (§2.2)

**Solvency:** `B + DUST ≥ O`

**Breach:** `B + DUST < O`

---

## 9. Test Coverage

The protocol is tested by two complementary suites:

### 9.1 Offline real-EVM harness

`test/run.mjs` — runs on Node.js using `@ethereumjs/vm` (no Foundry, no network):

- **80 checks across 18 scenarios**
- Boost curve exact values
- Mandatory lock (min, max, countdown cap)
- Extends-only top-up
- Per-wallet cap
- LTV boundary (exact limit and above)
- Withdraw requires debt == 0
- Flash-loan guard
- Interest accrual over 91 days
- Direct liquidation
- Autonomous liquidation (triggered by third-party tx)
- Emission distribution
- No-backlog capture (latecomer receives 0 for empty period)
- Emergency (declare → emergencyWithdraw → net equity)
- tripBreaker only on insolvency
- Access control (admin, guardian, anonymous)
- Standalone lock extension and expiry
- Solvency across a long mixed sequence

### 9.2 Foundry fuzz + invariant suite

`test/BlazePhoenixStaking.t.sol`:

- **12 unit tests** mirroring the JS suite (incl. incremental funding cap)
- **5 stress tests**:
  - `test_stress_gasExhaustion_maintMax` — fuzz: budget ≤ `MAINT_MAX_SCAN`, deposit gas bounded
  - `test_stress_timegap_budgetCap` — fuzz: budget clamped across 0..365-day gaps
  - `test_stress_solvency_maxKinkUtilization` — solvency + repayability under high utilisation
  - `test_stress_reentrancy_maliciousToken` — `nonReentrant` blocks a reentrant borrow hook
  - `test_stress_blacklist_maintenanceResilient` — a blacklisted borrower cannot DoS the sweep
  - `test_stress_lockerRegistryFlood_boundedAndSelfDraining` — fuzz: a 20..60-deep expired locker
    backlog keeps per-tx gas bounded and drains from organic flow alone
- **Hardening regressions** — `HardeningH04_UtilCap.t.sol` (LTV-first revert ordering, the
  exact 75% boundary borrow landing and one token more refusing, headroom reopening on another
  borrower's repay) and `HardeningH05_EmergencyHaircut.t.sol` (pro-rata haircut engages only on
  a real shortfall, exit-order invariance, solvent exits unchanged). The terminal-distress
  clamp coupling (§5.3.1) is pinned by the JS attack suite's single-window self-liquidation
  scenarios, whose odd-ratio books (1,000,000/499,000) exercise the rounding-dust path that
  exactly-dividing books cannot reach.
- **BP-2026-001 regression** — `test_StaleBoost_*` (Foundry) and `test/boost.mjs` B1..B10 (JS).
  B1 uses only the v3.0.0 ABI, so it runs verbatim against the vulnerable contract and fails there
  on the reported divergence itself (idle:active yield ratio 1.25× and a 2.25M denominator, against
  the corrected 1.00× and 2.0M) rather than on a missing function.
- **7 invariants** under random action sequences (256 runs × 128,000 calls each):
  - `invariant_solvent` — `isSolvent()` always true
  - `invariant_conservationBit` — bit 0 of `auditInvariants()` never set
  - `invariant_boostBounded` — boosted denominators never exceed `stake × maxBoost / base`
  - `invariant_backingCoversOwed` — `backing + dust ≥ owed` always
  - `invariant_everyLiveCommitmentIsTracked` — no live lock escapes the locker registry (a lock the
    engine cannot see is the original stale-boost bug returning)
  - `invariant_lockRegistryHasNoDuplicates` — the registry is a set, not a bag
  - `invariant_staleBoostExcessIsBounded` — transiently stale weight stays inside the
    `stake × maxBoost` envelope

**Result: 330/330 JS checks pass (80 integrity + 76 adversarial + 174 lock-expiry).** The Foundry
suite is run where Foundry is available; it is not installable in the offline sandbox.

---

## 10. Deployment Parameters

| Parameter | Value |
|---|---|
| Solidity | 0.8.28 |
| Optimiser | enabled, 200 runs |
| viaIR | required (stack depth) |
| Licence | BUSL-1.1, Change Date 2030-06-01 |

**Constructor arguments:**

```solidity
constructor(address bzpx_, address treasury_)
```

- `bzpx_` — the BZPX token address (immutable after deploy)
- `treasury_` — sole destination for protocol reserve withdrawals (immutable)

After deploy, the admin must:
1. Call `grantRole(keccak256("GUARDIAN_ROLE"), guardian)` to enable
   `pause()` / `declareEmergency()`
2. Call `fundEmission(amount)` to seed the reward reserve. This is **incremental** — it may be
   called multiple times, with cumulative funding hard-capped at 180,000,000 BZPX.

---

## 11. Licence

BUSL-1.1. See [LICENSE](../LICENSE).

On **2030-06-01** the Licensed Work converts to **GNU General Public License v2.0
or later**. Until that date, the Additional Use Grant permits use for any purpose
other than offering a competing staking, lending, or liquidity-mining service to
third parties.
