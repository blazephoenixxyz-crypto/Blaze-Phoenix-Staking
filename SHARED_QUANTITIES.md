# Shared-Quantity Register

> Every quantity in this system that has **more than one producer or more than one consumer**,
> and the mechanism that keeps them from drifting apart.

## Why this file exists

A common defect shape in a contract like this one is not a missing check and not a wrong formula:
it is **two places answering the same question with different answers, and nothing forcing them to
agree** — a view that publishes a borrowing maximum the borrow path refuses, a quote that does not
equal what the same block pays, a damper applied to one denominator and not its twin. This file
records which test binds which quantity, so the next drift is a failing check rather than a
surprise.

A type system cannot catch this class: both sides are legitimately measured, they just disagree.
What catches it is enumeration. This file is that enumeration.

**The rule.** A quantity with more than one producer must either

- **(a)** collapse to a single producer, with a CI guard forbidding copies, or
- **(b)** keep its producers and carry a named test that asserts they agree.

A row here records which, and — when the answer is "neither" — says so out loud.

Source references are function names in `src/BlazePhoenixStaking.sol`; line numbers, where given,
are at commit `cedd80d` and move with the code. The function name is the stable reference.

## How to read the Status column

| Status | Meaning |
|---|---|
| `SINGLE` | Collapsed to one producer. A CI guard fails the build if a copy reappears. |
| `PINNED` | Multiple producers, and a named test asserts agreement. The test **names the quantity**. |
| `WEAK` | A pin exists but does not fully bind: it is tolerance-based, or it pins a neighbouring primitive rather than the one actually consumed. Known escapes are listed. |
| `OPEN` | No pin. |
| `UNVERIFIED` | Listed because the code shows multiple consumers; the pin has not been confirmed by reading. Treat as `OPEN` until someone checks. |

A `WEAK` row is more dangerous than an `OPEN` one. `OPEN` is a known hole. `WEAK` is a hole with a
green test in front of it.

---

## The register

### Rates and utilisation

| Quantity | The question it answers | Producers / consumers | Status | Pin |
|---|---|---|---|---|
| `simulateRate` | "What interest rate is in force at this utilisation?" | Two bodies of the same kink: `_interestRate()` (live, reads `totalDebt` / `totalStaked`, caps utilisation at `WAD`) and `simulateRate()` (pure, caps its argument at `WAD`). Each restates the two-segment formula rather than sharing it. Consumers: `_interestSlice` prices with the live rate; `currentInterestRateBps`, `getUserInfo`, `getGlobalStats` and `_risk` (for `daysToLiquidation`) publish or project it | `PINNED` | `test/MetamorphicRelations.t.sol` — `test_RateEndpointsAndKink` and the monotonicity / clamp / Lipschitz relations on `simulateRate`; `test/final.mjs` — "simulateRate(utilisation) reproduces the live rate" |
| `utilization` | "How much of the stake is lent out?" | Two terminal conventions: `_utilization()` (views; `totalStaked == 0 && totalDebt > 0` → `type(uint256).max`, zero/zero → 0) and `_interestRate()` (the same terminal state → utilisation `WAD`, zero/zero → `RATE_R0`). Consumers: `utilizationRate`, `getGlobalStats`; `borrow` computes its aggregate cap inline | `WEAK` | No test forces the two conventions to agree. They differ only in the terminal and zero/zero states, and each difference is commented in place: a rate needs a number, a view may say `max` |

### Curves

| Quantity | The question it answers | Producers / consumers | Status | Pin |
|---|---|---|---|---|
| `boostByDays` | "What boost (bps) does an N-day lock pay?" | One producer: `boostByDays()`, with the constants `BOOST_BASE` / `BOOST_LINEAR` / `BOOST_QUAD`. Consumers, all calling it: `_computeBoost`, `auditInvariants`, `lockInfoOf`, `effectiveBoostOf`, `pureStakerApr`, `getUserInfo`, and the `LockSet` events of `deposit` / `lock` | `SINGLE` | `*Producer copy guard*` (CI: one definition and the two arithmetic lines exactly once each). `test/MetamorphicRelations.t.sol` checks it against the real-valued curve |
| `MIN_EMISSION_WEIGHT` | "What keeps a residual denominator from capturing the whole flow?" | Two channels, each on a live and a quoted path: emission in `_updateGlobal()` and `_pendingReward()`; pure yield through the one body `_dampPure()`, called by `_updateInterestIndex()`, `_pendingPure()` and `pureStakerApr()` | `PINNED` | `test/fix205/PureYieldDustDenominator.t.sol` — `test_DustPurePositionCannotCaptureTheProtocolsInterest`, `test_QuoteEqualsExecutionUnderResidualDenominator`; `test/assurance/DeliveryIndex.t.sol` — `test_OneWeiCannotCaptureTheSchedule` (emission channel, literal oracle) |
| `maxBorrowOf` | "What can this position borrow right now?" | One body `_risk()` produces `maxBorrowOf`, `healthFactor`, `daysToLiquidation` and `getUserInfo.maxBorrowAvailable`; the executable side is `borrow`, with two boundaries: the LTV cap and the aggregate utilisation cap `MAX_PROTOCOL_UTIL_WAD` | `PINNED` | `test/fix205/ViewsQuoteEqualsExecution.t.sol` — `test_MAXB_UTIL_maxBorrowOfIsBorrowableUnderAggregateCap` (oracle: `borrow` itself), `test_MAXB_INT_maxBorrowOfIncludesPendingInterest` |

### Accounting and identity

| Quantity | The question it answers | Producers / consumers | Status | Pin |
|---|---|---|---|---|
| `owed` | "What does the protocol owe right now?" | One identity `_owed()` (with `_pendingDistribution()`), checked on every value-moving transaction by the `conserves` modifier through `_conservationCheck()`. Consumers: `owed`, `isSolvent` (via `_hardBreach`), `collateralRatio`, `solvency`, `auditInvariants`, and the treasury exits, which accrue the book to now and read it after their own transfer (`sweepUndistributedEmission` and `withdrawReserve`: the emission residue or the reserve leaves only if the book, accrued to the current block, still reads solvent after it) | `PINNED` | `test/InvariantsFullSurface.t.sol` — INV-16: the campaign keeps `backing + DUST >= owed`, and `FullSurfaceConservationTest.test_INV16_everyValueMovingEntryPointConserves` walks every value-moving entry point in a fixed order; `test/hardening/UnbookedLossReadIsALowerBound.t.sol` — `test_OWEDREAD_unbookedLossReadsAsABreachBoundedByTheRealDeficit` (a loss not yet recorded reads as a breach, the read deficit is a lower bound of the real one, and `backing + totalBadDebt + unrecordedLoss >= owed`); `test/hardening/EmissionSweepKeepsTheBookSolvent.t.sol` — `test_SWEEP_residueThatCoversTheClaimsStaysInThePot` (red at d9b9b16: the sweep left a 28,544e18 deficit on a book that read solvent) and `test_SWEEP_reserveThatCoversTheClaimsStaysInThePot` (red at 67ba48f: `withdrawReserve` sent 628,946.65e18 and left a 197,900e18 deficit on a book that read solvent) |
| `totalBadDebt` | "Who absorbs a realised loss, and in what order?" | Three writers, one rule (the protocol reserve first, only the uncovered rest is booked): `_executeLiquidation()` (debt above collateral), `emergencyWithdraw()` (under-water exit, including a position whose attribution has eroded its stake to zero: it closes and books its whole debt) and the uncollectible-interest branch of `_accrueInterestFor()`; one reducer, `absorbBadDebt()` (reserve first, then the caller's tokens, capped at the loss). Consumers: `_owed()` (counted, never netted: an uncovered loss is a claim the contract cannot pay, so it reads as a breach), `solvency`, `getGlobalStats` | `PINNED` | `test/hardening/ReserveFirstLossAndDeployChecks.t.sol` — `test_reserveAbsorbsUncollectibleInterestBeforeBadDebt` (red without the rule in `_accrueInterestFor`) and `testFuzz_reserveFirstOrdering` (`totalBadDebt == 0 \|\| protocolReserve == 0` right after the loss); `test/hardening/OwedCountsBadDebt.t.sol` (red with the netting back in `_owed()`); `test/hardening/ErodedBorrowerEmergencyExit.t.sol` — `test_ERODED_emergencyExitClosesAnErodedBorrowerAndBooksItsDebt` |
| `stakedOverdraw` | "How much stake does the book still hold?" | One debit path, `_debitStaked()`, used by `withdraw`, `emergencyWithdraw` and `_executeLiquidation` (each site reachable past zero: a withdraw crosses it while an eroded borrower is unattributed and the emission residue keeps the book reading solvent): it takes `totalStaked` to zero at most and carries the rest in `stakedOverdraw`; one settling path, the uncollectible-interest branch of `_accrueInterestFor()`, which settles `stakedOverdraw` first and adds only the remainder back to `totalStaked`. `totalStaked − stakedOverdraw` is the exact signed total. Consumers: `conserves` reads both, on opposite sides of the identity; `_owed()`, `_interestRate()` and `_utilization()` read `totalStaked` | `PINNED` | `test/hardening/ErodedBorrowerEmergencyExit.t.sol` — `test_ERODED_stakedOverdrawIsSettledByTheLaterAttribution` (the overdraw is settled by the attribution that books the eroded borrower, through the conservation check) and `test_ERODED_latchOpensAfterEveryExitWithoutARawTransfer`; `test/hardening/TerminalDistressOrdering.t.sol` — `test_TERMDISTRESS_pureStakerWithdrawPastTotalStakedCarriesTheOverdraw` (the withdraw site) and the two ordering tests (both seizure orders and the neutral touch reach one end state, `stakedOverdraw` included) |
| `Liquidated` | "What was the liquidating caller actually paid?" | One producer: `_executeLiquidation()` decides the bonus, including the self-liquidation case (kept in `protocolReserve`, reported as 0), before emitting `Liquidated`. Consumers: the transfer in `liquidate()`, the transfer and `MaintenanceSwept` in `maintStep()` | `PINNED` | `test/assurance/EventPayloads.t.sol` — `test_E_Liquidated_self_reports_bonus_actually_paid` a self-liquidation with a positive surplus must emit a bonus of 0 (the caller is paid nothing) |
| `totalPositiveEquity` | "What is the aggregate positive equity?" | One writer: `_applyBoost()` (its NatSpec: "THE sole writer of the boosted totals AND of totalPositiveEquity"). Consumers: `totalEffectiveStaked`, and the emergency haircut denominator in `emergencyWithdraw` | `PINNED` | `test/EMG_HaircutUnderwater.t.sol` — `test_EMG_AccumulatorEqualsSumMaxEquity` asserts the accumulator equals `Σ max(staked_i − debt_i, 0)` built independently |

### Reward and interest projection

| Quantity | The question it answers | Producers / consumers | Status | Pin |
|---|---|---|---|---|
| `pendingRewards` | "How much emission falls in this window?" | Execution `_updateGlobal()` integrates the closed-form delta of `_emittedAt`; the quote `_pendingReward()` re-derives the same delta, the same `MIN_EMISSION_WEIGHT` throttle and the same `_min(r, rewardReserve)` clamp. Settlement pays through `_settlePendingRewards()`, which under a hard breach keeps what is due as a deferred credit (`_rewardDeferred`) instead of paying it; the breach is read after the position's own loss (the settle attributes the position's interest first, then adds to `_owed()` the part of `debt − staked` the reserve cannot cover, which its liquidation records as bad debt, in this transaction or a later one); every entry runs its maintenance sweep before its own settles (LOSS-FIRST), so the read also sees the third-party losses that transaction books; the quote adds that credit, so quote and payout stay one number across the breach | `PINNED` | `test/ViewsQuoteEqualsExecutionFuzz.t.sol` — `testFuzz_PendingQuotesAreWhatClaimRewardsPays` (quote vs the transfer `claimRewards` makes); `test/hardening/EmissionDeferredUnderBreach.t.sol` — `test_EMISDEFER_deferredCreditIsPaidOnceSolvent` (the credit deferred under a breach is paid exactly as quoted once solvent) and `test_EMISDEFER_liquidationThatBooksTheLossReadsThePotAfterIt` (red at d9b9b16: the liquidation that opened the breach paid the liquidated position 274,188e18 of emission first), `test_EMISDEFER_claimThatBooksItsOwnShortfallReadsThePotAfterIt` and the repay / lock-poke twins (red at 67ba48f: 274,188.78e18 paid at par, then the same transaction's attribution booked 212.13e18 of bad debt), `test_EMISDEFER_lockPokeWhoseSweepSeizesTheOwnerReadsThePotAfterIt` (red at 67ba48f: paid at par, then the poke's sweep seized the owner for 162.53e18 of bad debt) and `test_EMISDEFER_liquidationWhoseLossTheReserveCoversPaysAtPar` (a seizure the reserve covers still pays at par) |
| `pendingPureYield` | "What is the un-settled interest share of a position?" | Execution `_updateInterestIndex()` and the quote `_pendingPure()` both take the slice from `_interestSlice()` (its NatSpec: "SINGLE SOURCE"), with the same reserve factor and the same damper; settlement through `_settlePendingPureYield()` | `PINNED` | `test/ViewsQuoteEqualsExecutionFuzz.t.sol` — `testFuzz_PendingPureYieldIsWhatClaimPureYieldPays`; `test/fix205/ViewsQuoteEqualsExecution.t.sol` — `test_PEND_DISTRESS_pendingPureYieldEqualsClaimUnderClamp` (quote equals paid when the index clamp binds) |

### Time boundaries

| Quantity | The question it answers | Producers / consumers | Status | Pin |
|---|---|---|---|---|
| `lockInfoOf` | "Has this lock expired, and what is it paid right now?" | One predicate, several readers: `_processLockExpiry()` normalises storage, `_effectiveLockDays()` and `lockInfoOf()` answer for views, `pokeExpiredLock` enforces the boundary, `hasStaleBoost()` reports a not-yet-swept commitment | `PINNED` | `test/BoundaryEquality.t.sol` — `test_LockExpiryViewAndPokeAgreeOnTheBoundary` (view and poke on the same boundary; paired in `.github/scripts/mutants.py` with two boundary mutants) |

---

## Adding a row

Add one whenever you introduce a quantity that a second place will read or write. The row costs a
minute; finding the drift later costs far more.

State the **question**, not the variable name. Two consumers of `utilisation` that ask *"what rate
is in force?"* and *"what should I assume it is?"* are asking different questions, and that is
precisely how they drift while looking identical in a grep.

## What the CI check enforces

`.github/scripts/shared-quantities.sh` parses the tables above and fails when:

1. a row claims `PINNED` but the test file it names does not exist;
2. a row claims `PINNED` but that test file never mentions the quantity;
3. a row claims `SINGLE` and names a CI guard that is absent from `.github/workflows/ci.yml`.

Rule 2 is the one that bites: a pin that does not name its quantity is a green test in front of a
hole.

The check deliberately does **not** discover new shared quantities automatically. That requires
reading the code and asking what question each consumer is asking, which is a human job.
