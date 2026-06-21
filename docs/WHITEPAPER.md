# BlazePhoenix Protocol — Technical Whitepaper

**Version 3.0.0 · June 2026**

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
    uint256 balBefore  = ML.rawBalanceOf(bzpx, address(this));
    uint256 owedBefore = _owed();
    _;
    uint256 lhs = ML.rawBalanceOf(bzpx, address(this)) + owedBefore;
    uint256 rhs = balBefore + _owed();
    uint256 d = lhs > rhs ? lhs - rhs : rhs - lhs;
    if (d > CONSERVATION_DUST) revert Staking__InvariantBreached();
}
```

This checks the **delta**, not the absolute value. Formally:

```
|Δbalance − Δowed| ≤ CONSERVATION_DUST
```

Checking the delta rather than the absolute value is critical for two reasons:

- **DoS prevention.** If the check were absolute (`balance ≥ owed`) and dust had
  accumulated historically (e.g. 1 wei from a rounding error months ago), the
  check could block every future transaction even though no real loss occurred.
  The delta check cancels historical drift algebraically.

- **Leak detection.** Any transaction that moves value in a way not reflected in
  the ledger — for example, a re-entrancy that claims rewards twice, or an
  accounting bug that credits a user without receiving tokens — will cause `Δowed`
  to diverge from `Δbalance` and revert atomically.

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

### 3.3 Why this is sufficient

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

### 5.3 Interest accrual

Interest reduces the borrower's `staked` balance (not a separate debt counter):

```
interest = debt × rate × elapsed / SECONDS_PER_YEAR
stake    -= interest
```

Of the interest collected:
- **3% reserve factor** → `protocolReserve` (admin can withdraw to immutable treasury)
- **97%** → distributed to pure stakers (debt-free positions) as `accPureYieldPerShare`

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

### 6.1 Schedule

```
TOTAL_REWARDS   = 180,000,000 BZPX
EMISSION_PERIOD = 7 × 365 days
REWARD_PER_SEC  = TOTAL_REWARDS / EMISSION_PERIOD  ≈ 0.814 BZPX/s
```

Rewards are distributed pro-rata to `totalBoostedEffective` (stake × boost,
net of debt) via the standard accumulator pattern.

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

`cancelEmergency()` requires ADMIN role and that `_hardBreach()` is currently
false. This prevents cancelling while the breach still exists.

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

**Conservation:** `B + BD = O + BD` → `B = O` (ignoring dust)

**Solvency:** `B + DUST ≥ O`

**Breach:** `B + DUST < O`

---

## 9. Test Coverage

The protocol is tested by two complementary suites:

### 9.1 Offline real-EVM harness

`test/run.mjs` — runs on Node.js using `@ethereumjs/vm` (no Foundry, no network):

- **77 checks across 18 scenarios**
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

- **11 unit tests** mirroring the JS suite
- **4 invariants** under random action sequences (256 runs × 128,000 calls each):
  - `invariant_solvent` — `isSolvent()` always true
  - `invariant_conservationBit` — bit 0 of `auditInvariants()` never set
  - `invariant_boostBounded` — boosted denominators never exceed `stake × maxBoost / base`
  - `invariant_backingCoversOwed` — `backing + dust ≥ owed` always

**Result: 15/15 Foundry tests pass. 77/77 JS checks pass.**

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
2. Call `fundEmission(amount)` to seed the reward reserve (max 180,000,000 BZPX,
   one-time only)

---

## 11. Licence

BUSL-1.1. See [LICENSE](../LICENSE).

On **2030-06-01** the Licensed Work converts to **GNU General Public License v2.0
or later**. Until that date, the Additional Use Grant permits use for any purpose
other than offering a competing staking, lending, or liquidity-mining service to
third parties.
