# Invariants in systems that carry time

*An engineering report drawn from the BlazePhoenix Staking findings — what the seven disclosed
defects had in common, why the protocol's own guards could not see any of them, and the rules
that fall out of that.*

---

## 1. The thesis

A conservation invariant is a statement about **quantity**. It answers *how much value exists*.

A system that accrues over time also needs statements about **trajectory** — *when* value was
earned, and *who was present while it accrued*. Those are different questions, and no amount of
conservation checking answers them.

> A ledger can balance to the wei on every single block and still hand the wrong person the money.

That sentence is the whole report. Everything below is evidence for it and consequences of it.

---

## 2. The evidence

Seven defects were found in this protocol. Every single one of them left the books balanced.

| Finding | What it broke | Conservation broken? |
|---|---|---|
| Expired lock boost persisting on idle positions | who earns | No |
| JIT stakers capturing already-accrued interest | who earns | No |
| Stale lock duration pricing new principal | who earns | No |
| Under-water exit not recording bad debt | ledger closure | Yes — the one exception |
| Interest priced at a rate the caller sets | when it was priced | No |
| Empty-window emission stranded | when it was earned | No |
| A dust position alone absorbing the schedule | who earns | No |

Six out of seven were **pure redistribution**. Value moved between participants and the totals
never changed. The protocol's `conserves` guard checks that the change in the real balance equals
the change in what the ledger claims to owe — and a redistribution is delta-neutral on both sides.

**The guard was working perfectly the entire time. It simply was not measuring the failing
quantity.** This is the single most important lesson available here: a correct invariant that
covers the wrong dimension gives false confidence, and false confidence is worse than no
confidence, because it stops you looking.

---

## 3. The shape of a time defect

Every quantity this class of protocol distributes has the same form — a path integral:

```
V_i(t₀→t₁)  =  ∫[t₀,t₁]  rate(s) · w_i(s) / W(s)  ds
```

- `rate(s)` — the rate in force at instant *s*
- `w_i(s)` — participant *i*'s weight at instant *s*
- `W(s)` — the total weight at instant *s*

Lazy implementations do not integrate. They evaluate a **rectangle sampled at the right endpoint**:

```
V_i  ≈  rate(t₁) · (t₁ − t₀) · w_i(t₁) / W(t₁)
```

That approximation is exact only when every factor is constant across the interval. Each factor
that is *not* constant gives a distinct defect family:

| Factor sampled at `t₁` | Defect family | What an attacker controls |
|---|---|---|
| `rate(t₁)` | Retroactive re-pricing | The price charged for a period already elapsed |
| `W(t₁)` | Just-in-time capture | Membership of a distribution they were absent for |
| `w_i` from a stale scalar | Unearned multiplier | A weight describing a commitment that no longer exists |

A second family has nothing to do with integration and everything to do with bookkeeping:

> **A state advance whose dual is never written.**

Two instances appeared here. `totalDebt` was reduced on an under-water exit with no matching
`totalBadDebt`. The emission clock advanced with no matching write anywhere. Both create a
quantity the system cannot account for — in the first case a phantom liability, in the second a
sum of money owed to nobody and reachable by nobody.

---

## 4. Rules that follow

These are stated as engineering rules because they are checkable, not as principles because they
sound good.

**R1 — Advance the accumulator before any write that changes its inputs.**
The rate is a function of two ledger totals. Any transaction that moves either of them must settle
the elapsed period *first*, or the period gets re-priced at a rate that never prevailed across it.
This one rule closes every retroactive re-pricing vector at once, including the ones nobody
reported: we confirmed that borrow-, repay- and withdraw-driven manipulation all charge identically
to the wei once it is in place.

**R2 — Distribution and collection must move in the same step.**
If value is credited to recipients before it is taken from payers, the ledger claims more than the
contract holds. If it is taken before being credited, the reverse. They must be one atomic
movement, or the conservation identity has to be weakened to accommodate the gap — and a weakened
identity is exactly the blind spot that hides the next bug.

**R3 — Price by what remains, never by a historical scalar.**
If a multiplier is the price of a commitment, it must be a function of the commitment that is
*still outstanding*. A stored number that once described the position will eventually describe
something else. The test is a pure equivalence: two positions identical in principal, debt and
unlock time must receive an identical multiplier. Nothing about how they arrived there may matter.

**R4 — Every clock advance needs a dual write.**
Advancing time is a state change. If the accumulator declines to distribute for that period —
which can be entirely correct — then the value must land *somewhere* nameable and reachable.
"Nowhere" is not an accounting outcome, and it corrupts the totals for the rest of the system's
life.

**R5 — One implementation per published quantity.**
Any figure computed in two places will diverge. Not may — will. In this project the pure-yield
projection existed in an aggregate view and a standalone getter; fixing one left the other behind,
and the divergence was found only because a test rebuilt the number independently. Collapsing the
duplicates also *reduced* the deployed bytecode, taking the contract from 243 bytes under the
EIP-170 limit to 617. **Deduplication is a security measure, not a tidiness measure.**

**R6 — Never express a guard as a cliff.**
A predicate over a continuous quantity — *below this line, nothing; above it, everything* — hands
a lever to anyone who can move the quantity across the line. Our own anti-dust guard was written
that way, and it meant a large holder could stop emission for every remaining staker simply by
leaving. The same protection expressed as a ramp, scaling the rate by `weight / mark` below the
mark, removes the lever entirely: it is continuous, monotone, and has no point of leverage
anywhere on its domain. A dust position earns dust, a small pool earns proportionally, and
nobody's exit is anybody else's cliff edge.

> Hard thresholds are brittle by construction. Wherever a guard must bound behaviour, prefer a
> function that bends over a rule that snaps.

---

## 5. The dimension map

Value and time are two axes. A deployed contract lives in more.

| # | Dimension | The question | What we found |
|---|---|---|---|
| 1 | **Value conservation** | Does the money add up? | Already sealed. Residual measured at exactly 0 wei across four decades of capital scale. |
| 2 | **Time trajectory** | When was it earned, and who was present? | Six of seven findings lived here. |
| 3 | **Liveness** | Can it be frozen or deadlocked? | Held. Runaway rates saturate; a poisoned position cannot stall a third party; sweeps stay bounded. |
| 4 | **Privilege** | Can authority drain it? | Held. Asking for `uint256.max` returns protocol revenue and nothing of principal. No redirect, rescue or upgrade entry point exists. |
| 5 | **Incentives** | Is anyone paid to keep it clean? | Held. An untended leveraged book self-cleans through ordinary traffic, no keeper asked. |
| 6 | **Asset boundary** | What if the token misbehaves? | Held. A fee-on-transfer token is rejected by the conservation guard rather than leaving the ledger over-credited. |
| 7 | **Reporting truthfulness** | Do the published numbers describe reality? | **Two defects.** Not in the original map. |
| 8 | **Deployment environment** | What does it assume about the world? | **One defect.** Not in the original map. |

### On dimension 7 — the one that hides the others

The protocol publishes `owed()`, `backing()`, `collateralRatio()`, `solvency()` and
`auditInvariants()` as trustless verification. Every other guarantee is checked *through* those
numbers — by users, by dashboards, by monitors, and by the test suites themselves.

A defect that corrupts the **instrument** rather than the **value** is therefore invisible to every
other dimension simultaneously. The stranded-emission finding did not break solvency; it made
`owed()` overstate real liabilities for the remaining life of the contract, which would have
silently distorted every reading anyone ever took.

The correct test is not to check that the views are self-consistent. It is to **rebuild every
published figure from primitive state and compare**. Self-consistency is what a wrong number has
with itself.

### On dimension 8 — what the code assumes about the world

Contracts encode assumptions about their deployment that never appear in their logic: that funding
arrives at genesis, that traffic is continuous, that the chain does not go quiet. Here, topping up
the emission reserve *after* a window that had run with nothing behind it retroactively paid that
window out — an assumption about deployment order, invisible in every other dimension.

---

## 6. Calibration lessons

Recorded because each one changed a conclusion we had already committed to.

**A severity bound asserted without measurement.** We claimed utilisation was algebraically capped
at one third, that the rate therefore could not exceed 266.7 bps, and that the steep branch of the
rate curve was dead code. All three were wrong. The first borrow on a debt-free position reaches
50% immediately, and because interest is charged against collateral, utilisation climbs on its own
past the 80% kink in about nineteen years. Two findings were under-rated on the strength of that
error, publicly, to the researchers who reported them.

**The near-miss that came from it.** Acting on the "dead code" conclusion would have deleted a live
branch of the interest-rate curve. It survived only because we measured before deleting.

**A regression introduced while fixing a bug.** Saturating arithmetic was swapped for reverting
arithmetic in the interest path. Given that the rate can genuinely explode, that would have frozen
`deposit`, `borrow`, `repay`, `claim` and the maintenance sweep precisely when the protocol was
already under stress — a liveness failure introduced by a correctness fix.

**A remediation that opened a fresh hole.** The anti-dust guard above was one of ours, and the
griefing lever it created was found by attacking our own fixes rather than the original code. A
separate disclosed finding was likewise a hole opened by an earlier remediation. Both point the
same way: **a fix is a state change, and it deserves the scrutiny given to the code it replaced.**
Regression suites usually ask whether old behaviour still works; the more valuable question is
what surface the repair itself introduced.

**Apparent defects that were not.** Several results that first read as protocol bugs turned out to
be faults in how they were measured. Not one of them survived investigation.

> **A negative result is a hypothesis, not a finding.** Verify your own instrument before you
> believe what it tells you about the system.

---

## 7. Risk posture: systems that carry time

An AMM or a swap lives in the instant. A transaction opens and closes; the state carries no
history. A defect has a window measured in blocks and its blast radius is local.

A system like this one **accounts for time as if it were mass**. A seven-year emission schedule.
Locks from ninety days to seven years. Interest integrating across decades. Every invariant that
depends on the clock carries a value nobody can observe directly — it becomes visible only when
somebody touches the position, and by then the error has been compounding.

That is a structurally harder safety problem than an ephemeral system, for three reasons:

1. **Errors accumulate silently.** There is no transaction boundary at which the mistake surfaces.
2. **The failure is distributional, so totals look correct.** The instrument most people trust
   keeps reporting health.
3. **The exploit window is unbounded.** A defect present at deployment is still exploitable years
   later, and the longer it goes unnoticed the more value has flowed through it.

The design instinct behind this protocol — seal conservation first, with an on-chain identity that
makes an insolvent state unreachable rather than merely observable — was the right first move, and
the awareness that time would be the harder axis was correct. What the findings show is that
recognising the risk is not the same as covering it. **The mass was sealed. The time was not.**

---

## 8. Design checklist

For any protocol that distributes value over time:

- [ ] Every accumulator is advanced before any write that changes its inputs
- [ ] Distribution and collection move in the same atomic step
- [ ] No multiplier or weight is keyed to a stored value that time can invalidate
- [ ] Every clock advance has a named, reachable destination for the value it represents
- [ ] Every published quantity has exactly one implementation
- [ ] A participant absent for a window receives nothing from that window
- [ ] The same operation costs the same regardless of which transaction drives it
- [ ] Every published figure is reproducible from primitive state by an independent party
- [ ] Every health metric has been driven into a known-bad state to prove it responds
- [ ] Severity is assigned after reachability is measured, not before

---

## 9. Standing caveats

The suites pass. That is evidence, not proof.

The change that made interest accrue continuously alters how `totalStaked` and the distribution
denominators are maintained — the most invasive change in this work, and the one whose failure
modes are least likely to be covered by tests written by the same author. It warrants external
audit before deployment.

Dimensions 7 and 8 were absent from the original map and each contained a defect. **The most
reliable predictor of where the next bug lives is the dimension nobody has named yet.**

---

## 10. Postscript — v4 applies §3 to its own emission

v4 replaced the flat emission rate with a biennial-halving curve, which made `rate(s)`
time-varying for the first time. The rectangle approximation of §3 —
`rate(t₁) · (t₁ − t₀)` — would now be a live instance of the *retroactive re-pricing* family:
a window crossing a halving boundary would be paid entirely at whichever period's rate the
touching transaction happened to land in.

The implementation instead distributes `emittedAt(t₁) − emittedAt(t₀)`, the exact integral of
the schedule in closed form. The delta of a monotone cumulative curve is correct across any
number of boundary crossings, for windows of any length, with no dependence on when somebody
happened to poke the contract — the property this report exists to demand. Dimension 12's
freeze-at-`emissionEnd` test and Dimension 13's period-boundary anchors pin it.

---

## 11. Postscript — the terminal-distress round confirms §6

The August 2026 hardening round is §6's thesis run three times on the same fix, and is
recorded here for that reason.

The first cut of the clamp reconcile (C-03) **over-corrected**: it restored to `totalStaked` a
shortfall computed off an index that had advanced further than the global debit, manufacturing
a phantom that re-opened clamp headroom and was distributable as unbacked yield. Two
independent adversarial reviewers found it — in the remediation, not in the original code. The
second cut coupled the index to the clamp in *every* window and shifted healthy-regime interest
by a rounding amount; both CI suites caught assertions pinned to exact numbers. The third cut
coupled only when the clamp binds, and still left a floor-dust residue that a non-dividing
book (1,000,000/499,000 — the exactly-dividing test fixture could never see it) turned into a
checked underflow that re-froze liquidation: the precise DoS the companion fix (LIQ-01)
existed to remove.

Three iterations, each caught by a different instrument — adversarial review, exact-value
regression, and an attack-suite fixture whose numbers were chosen not to divide. The rule from
§6 stands as written: **a fix is a state change, and it deserves the scrutiny given to the
code it replaced.** The corollary this round adds: *choose test fixtures whose arithmetic does
not flatter the implementation* — a book that divides exactly proves less than one that
leaves a remainder.

---

*Security credit for the disclosed findings is recorded in the
[Hall of Fame](../README.md#-security-hall-of-fame).*
