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
| **v4 (final)** | **`4.0.0`** | **`3.0.0-staking`** | v3.1 **+** final tokenomics: 90M five-year-halving emission, closed-form O(1) |
| **v4 hardened** | **`4.0.0`** | **`3.0.0-staking`** | v4 **+** terminal-distress round: floor-free `conserves`, index-coupled clamp, 75% aggregate util cap, pro-rata emergency haircut, honest telemetry |

v3 = **v2 base**, with the two requested additions and the useful UX views that v2 had dropped
from v1 re-added.

---

## Bit 4 of `auditInvariants` reads the boost bound that holds on every clock (November 2026)

No ABI change; the meaning of one public view changes. Bit 4 compared the boosted weights with
`totalStaked x maxBoost`. The global interest debit lowers `totalStaked` at once, while a
position's weights keep the equity of its last resync, so the bit read set on a correct idle
book (60 max-boost borrowers, 30 and 60 years, accumulator equal to the sum of the tracked
weights). It now reads
`totalBoostedEffective * BOOST_BASE > (totalStaked + totalInterestAccruedGlobal) * boostByDays(MAX_LOCK_DAYS)`
or `totalBoostedPure > totalBoostedEffective`: stored stake plus all interest ever debited covers
the stake of every build, so the bit cannot read set on a correct book, idle, after an
attribution that no resync follows, or in an emergency after `syncEquity`. It is an upper bound,
not an equality, and it widens with the interest accrued (`docs/KNOWN_ISSUES.md`).

Pinned by `test/hardening/AuditBit4Clock.t.sol` (11 tests: the bit stays clear when unattributed
interest exceeds the debt at 30 and 60 years, on the carrier, emergency and fuzz books; the guard
fires one wei above the bound with and without interest accrued).

Measured: `auditInvariants` costs 1,977 gas more (one more cold read and one `boostByDays`).
Runtime: 24,574 bytes, 2 under the EIP-170 limit (24,561 before: 13 bytes for the bound).

---

## The batch poke books its caller's loss before the window it carries (November 2026)

No ABI change. `pokeExpiredLocks` carries the borrower window with its caller as the beneficiary
of every seizure the window makes, and that window reads `_hardBreach()` before it pays the
keeper bonus at par. The batch attributed the positions it names, not its caller: a caller whose
own interest had run past its stake was paid the bonus out of a pot that its own loss, booked by
its next transaction, left short. `pokeExpiredLocks` now runs `_attributeFirst(msg.sender)` right
before `_sweepBorrowers`, the order `_autoMaintain` already keeps for every other entry
(LOSS-FIRST): the caller's own loss is booked first, the window's seizures read it, and the bonus
stays in `protocolReserve`. A caller without debt is not touched; the lock window is still not
re-run (the batch normalises by name). `liquidate`, the direct seizure, books its caller's own
loss the same way before it seizes: `_attributeFirst(msg.sender)` right after `_updateGlobal`,
so the `_hardBreach()` the bonus is read against includes it.

Pinned by `test/hardening/MaintenanceBeforePayment.t.sol`
(`test_LOSSFIRST_theCarriersOwnLossIsBookedBeforeTheBatchPokesSeizureBonus`, red at `df0b092`;
`testFuzz_LOSSFIRST_everyBatchShapeBooksTheCarriersLossBeforeTheSeizureBonus` over every shape of
the batch, names, order and duplicates, read from the event order and the seizure's
`keeperBonus`; and the control `test_LOSSFIRST_documents_aDebtFreeCarriersBatchPokeIsStillPaidTheSeizureBonus`,
green before and after; `test_LOSSFIRST_theCarriersOwnLossIsBookedBeforeItsOwnLiquidationsBonus`,
red at `2ad030d`, with its control `test_LOSSFIRST_documents_aDebtFreeKeepersLiquidationIsStillPaidTheBonus`).
Two entries in the mutant register pair the attributions; the two entries that pin the order and
the clock of the batch were re-targeted to the new text.

Measured: a debt-free caller's batch costs 236 gas more when it names the caller and 2,236 more
when it does not (one cold read of the caller's debt); a batch that carries no borrower window
costs the same; a borrower's batch books the attribution its next transaction would have booked.
A debt-free keeper's `liquidate` costs 2,236 gas more (the same cold read of the keeper's debt).
Runtime: 24,561 bytes, 15 under the EIP-170 limit (24,543 before: 9 bytes for the batch, 9 for
`liquidate`).

---

## An attribution refreshes the position's equity (November 2026)

No ABI change. `totalPositiveEquity`, the denominator of the pro-rata emergency haircut, is the sum
of every position's `trackedEquity`, and `_applyBoost` is the one writer of both. A settle reaches
it through `_resync`. An attribution that no settle follows now reaches it too: `_attribute`
charges the position's interest (`_accrueInterestFor`) and refreshes its summand at unchanged
weights, and it is the body of `syncEquity` and what `_attributeFirst` runs for the caller of
`pokeExpiredLock` and for every position `pokeExpiredLocks` names. The property, EQUITY-FRESH:
when a transaction ends, the accumulator is the sum of the stored `max(staked − debt, 0)`, before
an emergency and after every `syncEquity` and every exit inside one, so a breached haircut pays
each exit `equity · pot / Σ equity` in every exit order. The refresh moves no weight, no reward
debt and no checkpoint, and adds no revert. The refresh sits at the caller of the attribution and
not in `_accrueInterestFor`, whose other callers already reach `_applyBoost` in the same
transaction (`SHARED_QUANTITIES.md`, `trackedEquity`).

Pinned by `test/hardening/AttributionRefreshesEquity.t.sol` (twenty-one tests; seventeen are red at
`9731e05`, the other four are the controls and the walks through the two emergency doors, green
there by design): `trackedEquity` and the accumulator are read against raw storage after each poke
door (the caller, a self-named batch, a batch under a guardian pause, twelve borrowers past the
window, a refused `lockStep`, the second either side of the unlock, a borrower with no lock of its
own by each door), and every exit order is paid the oracle after a trip at the same timestamp.
Two stateful campaigns in `test/InvariantsFullSurface.t.sol` check the accumulator against the
stored sum after every call, one over ordinary traffic and one that enters an emergency and exits
through it (256 runs of 500 calls each by default). Seven entries in the mutant register pair
these readings.

Measured: a borrower's own `deposit`, `borrow`, `repay`, `claimRewards` and `lock` cost 2,238 gas
more; `pokeExpiredLock` called by a borrower, 13,838 more; `pokeExpiredLocks` over thirteen named
positions, twelve of them borrowers, 44,456 more. `withdraw`, `claimPureYield` and `liquidate`,
and every call by a debt-free caller with the borrower sweep it carries, cost the same as before.
Runtime: 24,543 bytes, 33 under the EIP-170 limit (24,538 before).

## Reward debts round up; attack suite (November 2026)

No ABI change. `_checkpoint` now rounds `rewardDebt` and `pureYieldDebt` up (`_wadUp`), in the
protocol's favour. A floored debt handed the position the dropped fraction (< 1 wei) at every
resync, and with a dust denominator the accumulator's own floor left nothing to absorb it. Rounded
up, each constant-weight segment pays floor(w·A1) − ceil(w·A0) ≤ w·(A1 − A0), so the sum paid in a
window stays within the sum distributed. Pinned by `test/attack/DebtRoundsUp.t.sol` (eight tests,
red at `1f54743` with the debts floored; one of them pins that an exact product is not bumped),
with four mutants; the register row is in `SHARED_QUANTITIES.md`.

The same round adds `test/attack/`: `EmissionAttack.t.sol` (eleven tests),
`EmissionShareInvariant.t.sol` (two) and `HookTokenReentrancy.t.sol` (a hook token that re-enters
every external door of the contract from inside its transfer), and
`test/hardening/EmissionResidueOrigin.t.sol` (six tests: where the emission left in `rewardReserve`
comes from, and that only the admin's `sweepUndistributedEmission` reaches it, only to the treasury,
only after the close). The deploy script funds its own amount, pinned to the deployed
`TOTAL_REWARDS()`, and any difference fails the run in simulation (`test/DeployEmissionPin.t.sol`,
five tests, four mutants). A further mutant pins the keeper bonus of a seizure to the seized
equity. The mutation harness reports a mutant whose tree does not compile as a void verdict, never
as INERT. The 90M schedule is described under v4 below; the solvency views read as lower bounds
under the next entry.

Measured in CI on the merge of pull request #32: 427 Foundry tests green, 235 mutant targets found
by `check_targets.py`, runtime 24,538 bytes, 38 under the EIP-170 limit of 24,576.

## Losses before payments inside the sweep (November 2026)

No ABI change. LOSS-FIRST put every loss the maintenance sweep books ahead of the caller's own
payments, but not ahead of the sweep's own. The borrower window paid each position it settled as
it went, so a position settled early in the window was paid out of a pot that a later step of the
same window left short; the lock window, which runs after it, could pay one position and then
attribute a lapsed borrower's loss; and the caller's own interest was attributed only after the
sweep had paid. Now the caller's interest, and that of the positions `pokeExpiredLock` and
`pokeExpiredLocks` name, is attributed before anything is paid; the borrower window credits what
it settles (`_rewardDeferred`, paid by the position's next settlement outside the window); and the
lock window acts on a lapsed borrower only once its interest is attributed. The keeper bonus of a
seizure is still paid inside the window (`docs/KNOWN_ISSUES.md`). Pinned by
`test/hardening/MaintenanceBeforePayment.t.sol` (seventeen tests, red at `35dc558`; two replay one
transaction in every order of the borrower registry and of the batch, and each user is paid the
same in all of them; an eighteenth documents the keeper bonus, capped at the seized equity, that
the window still pays at par) and `test/fix1102/SelfCarrierNormalisation.t.sol`, with fourteen
mutants. The solvency views now say they are lower bounds (NatSpec only): `owed()`, `solvency()`
and `isSolvent()` read a loss not yet recorded only in part, and can read solvent with no deficit
until the borrower window reaches the position (`docs/KNOWN_ISSUES.md`); pinned by
`test/hardening/UnbookedLossReadIsALowerBound.t.sol`, with a fifteenth mutant; the same two books
run again with the emission reserve live at the breach, where the read nets it with the protocol
reserve and the caller's emission is deferred with her pure yield, with two more mutants.
Runtime: 24,489 bytes, 87 under the EIP-170 limit (24,299 before).

## One reading per question (November 2026)

No ABI change, no behaviour change. Three readings that each view wrote for itself are now one
primitive each, the view being the only coordinate: the page of the locker registry
(`_lockerPage`, read by `getLockers` and `expiredLockScan`), the elapsed commitment on record
(`_lockElapsed`, read by `lockInfoOf`, `hasStaleBoost` and `expiredLockScan`) and backing over owed
(`solvency()` reports `collateralRatio()`). `_processLockExpiry` keeps its own trigger: the views
read the class, the processor acts on it, and a test pins the two equal
(`test/hardening/MorphismParity.t.sol`, three tests, five mutants). The full suite gives the same
verdict on every test before and after. Runtime: 24,299 bytes, 277 under the EIP-170 limit
(24,545 before).

## Lapsed locks earn 1.00x from `unlockTime` (November 2026)

No ABI change. A lock that lapsed between two touches used to be paid its boost for the whole
window up to its next settle. Every settle and every quote now split an accrued window at
`unlockTime`: the part before it at the boost, the part after it at 1.00x (`_postUnlockAtBase`),
read on the emission curve for emission and on time for pure yield. What the lapsed boost did not
earn returns to `rewardReserve` (emission) or `protocolReserve` (pure yield) and leaves
`totalRewardDistributed`, so the identity is unchanged. Inside an emergency the split reads the
trip time, where both flows stopped (`_flowEnd`), so a quote read during the halt stays at its
value at the trip. `UserInfo.lastAccrueTime` is renamed `checkpointTime` (written only by
`_checkpoint`): it marks where the next settle's window starts. Three internal helpers now hold
bodies that were written twice: `_windowReward` (the emission of a window, with the
minimum-weight damper and the reserve clamp; `_updateGlobal` and the quote), `_poolShare` (the
pure share of an interest slice; the index update and the quote) and `_checkLockBounds` (the
static bounds of `deposit` and `lock`). Runtime: 24,545 bytes, 31 under the EIP-170 limit
(24,507 before). The split is exact where the flow inside the window followed its clock;
`docs/KNOWN_ISSUES.md` states and measures where it is not.

## v4 pre-deployment surface trim (October 2026)

v4 is not deployed yet, so its ABI can still shrink without breaking a caller. Seven views that
nothing reads (no test, script, SDK, MCP server or website call) were removed to return 831 bytes
of runtime under the EIP-170 ceiling. Each is derivable from state that stays public:

| Removed | Read instead |
|---|---|
| `timeSinceEmissionStart()` | `block.timestamp - emissionStart()` |
| `timeUntilEmissionEnd()` | `emissionEnd() - block.timestamp` (0 once past) |
| `emissionProgress()` | `emittedAt(block.timestamp) * 1e18 / TOTAL_REWARDS()` (WAD; the removed view returned exactly `1e18` from `emissionEnd` on) |
| `timeUntilUnlock(address)` | `unlockTime` from `lockInfoOf(address)` |
| `borrowerAt(uint256)`, `getBorrowers(uint256,uint256)` | `activeBorrowerCount()`, `isTrackedBorrower(address)`, and the `Borrowed`/`Repaid` events |
| `lockerAt(uint256)` | `getLockers(offset, limit)` |

### Uncovered bad debt is owed (October 2026)

`_owed()` used to subtract `totalBadDebt`, so a loss the protocol reserve could not cover left
`isSolvent()` reading true while claims exceeded the backing; exits were then paid
first-come-first-served. It now counts the loss: the protocol reads insolvent, the full-value
channels (`withdraw`, `deposit`, `borrow`, `claimRewards`, `claimPureYield`, `withdrawReserve`)
close together, anyone may trip the breaker into the pro-rata exit, and anyone may recapitalise
the loss with the new `absorbBadDebt(uint256)` (reserve first, capped at the loss, pays the
caller nothing). New event: `BadDebtAbsorbed(address indexed by, uint256 fromReserve, uint256 fromCaller)`.

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

## v4 — final tokenomics: the five-year-halving emission curve

The only economic change: the schedule moves from **180M linear over 7 years** to **90M on a
five-year-halving curve** — period `p` (0-indexed, 5 years each) emits `60M >> p` over 2 periods:
12M/year in years 1–5 (60M), 6M/year in years 6–10 (30M), 90M exactly. The curve is cut from the
series S = 120M, and `S − (S >> 2) = 90M = TOTAL_REWARDS` by construction. Chosen over the
linear schedule because a flat curve ends in a cliff at its full rate (documented
mercenary-capital exodus at linear ends): over the same ten years a flat schedule would close on
a 9M/year step, the two five-year periods close on 6M/year, and from there the real-yield regime
(borrow interest + DEX fee-share) carries on.

Revised 2026-11-06, before launch and with `VERSION` unchanged: the first v4 cut emitted 180M on
a biennial halving (8 two-year periods, 16 years, a 180M >> 8 = 703,125 BZPX tail the schedule
never emitted). The budget moved to 90M over 10 years; the closed form now reads a series
constant of its own (`HALVING_SERIES` = 120M) instead of the budget, and the accumulator and the
sweep are unchanged.

Mechanics:

- Cumulative emission is **closed-form O(1)** — one division, two shifts, one multiplication;
  no loop, no oracle, no exp/log:
  `emitted(t) = (S − (S >> p)) + (R0 >> p)·(t − start − p·PERIOD)`, `p = ⌊(t−start)/PERIOD⌋`.
- `_updateGlobal` integrates the **delta** of that curve per window, replacing the flat
  `REWARD_PER_SEC × elapsed` term. Everything else in the accumulator is untouched.
- The programme **hard-closes after 2 periods (10 years)** at exactly `TOTAL_REWARDS` = 90M,
  with no tail; anything stranded by empty windows is recoverable via the pre-existing
  `sweepUndistributedEmission`, pro-protocol.
- Rounding is always pro-protocol: the floored rate's sub-wei remainder (< 1e-10 BZPX per
  rollover) folds into the `S − (S >> p)` term, keeping the curve on the exact series.

Surface changes:

- Constants: `EMISSION_PERIOD` / `REWARD_PER_SEC` → `HALVING_PERIOD`, `EMISSION_PERIODS`,
  `EMISSION_LENGTH`, `INITIAL_REWARD_PER_SEC`.
- New view `emittedAt(timestamp)` exposes the curve for free on-chain verification (same ethos
  as `solvency()`); `emissionProgress()` now reports emitted/TOTAL (the curve, not the clock).
- `MAX_LOCK_DAYS` stays 2555 — now a policy cap (the boost curve and its overflow proof are
  calibrated on d ≤ 2555), no longer equal to the programme length. `maxLockDaysAvailable()`
  stays pinned at 2555 until fewer than 2555 days remain to the 10-year close.

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
