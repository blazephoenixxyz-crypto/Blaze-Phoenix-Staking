# Security Policy

BlazePhoenix-Staking is a financial protocol holding user principal. We take
security seriously and welcome responsible disclosure from researchers — this
codebase is measurably better because researchers have reported against it
before.

## Reporting a vulnerability

**Please do not open a public issue for security reports.**

Report privately to **contact@blazephoenix.xyz** (or a DM to
[@Sigmacrit](https://x.com/Sigmacrit)). Include:

- a description of the issue and its impact,
- the affected contract(s) and, where possible, `file:line`,
- a minimal proof-of-concept or the exact conditions to reproduce,
- your assessment of severity.

We aim to acknowledge a report within 72 hours and to keep you updated through
triage and remediation. Please give us a reasonable window to fix and deploy
before any public disclosure.

## Scope

In scope: the contracts in this repository (`BlazePhoenixStaking`,
`BlazePhoenixMathLib`) and their on-chain behaviour. Out of scope: the BZPX token
itself, RPC providers, and front-ends — but a vulnerability in how *this
contract* consumes them is in scope.

## Our security model, and where reports land hardest

The protocol enforces a single **Master Conservation Identity** on every
value-moving transaction: the change in the contract's real balance must equal
the change in what the ledger claims to owe, or the transaction reverts. A report
that reaches an insolvent state is the highest-value finding possible here.

But conservation is only half the model, and the more interesting half is the
other one. A ledger can balance to the wei on every block and still hand the
wrong person the money. Six of the seven defects previously found in this
protocol were **pure redistribution** — the totals never changed, and the
conservation guard was working perfectly the entire time while measuring the
wrong dimension. Reports are therefore especially valuable when they demonstrate:

- **Wrong recipient** — a participant earning from a window they were absent for
  (just-in-time capture), or holding weight from a commitment that has already
  elapsed.
- **Wrong price for a past window** — interest or emission stamped at a rate the
  caller could choose, rather than the rate that actually prevailed across the
  elapsed slice.
- **A state advance whose dual is never written** — a clock, index, or total that
  moves with no matching write anywhere.
- **Quote ≠ execution** — a view that reports an entitlement different from what
  a claim in the same block pays.
- **An unbounded path** — any code path where per-transaction gas grows with
  registry size, or where one poisoned position can stall the maintenance engine
  for everybody.
- **A recoverable-to-the-wrong-party residue** — emission or dust reachable by
  someone other than the treasury after the programme closes.

The reasoning behind this taxonomy, and the rules derived from it, are documented
in [`docs/INVARIANTS_AND_TIME.md`](./docs/INVARIANTS_AND_TIME.md). The invariant
summary for automated readers is in [`llms.txt`](./llms.txt).

Invariants are exercised in CI by the Foundry suites (unit, fuzz, structural
invariants) and by nine real-EVM suites running the compiled contract offline —
including an adversarial suite, a canonical DeFi attack-vector suite, and a
self-audit that treats each past remediation as a suspect, because one disclosed
finding was a hole opened by the fix for an earlier one. A report that defeats
one of these is especially welcome.

## Recognition

Valid, previously-unknown findings are credited in the **Security Hall of Fame**
in [`README.md`](./README.md), with your consent and under the name or handle you
choose. Credit is given for the finding, the root-cause analysis, and the
remediation reasoning where they came from you — attribution is not rounded down.

We do not currently run a paid bounty; this may change and will be announced
here.

## Authorship & integrity

This code is original work by **Fable & Mitra**, licensed BUSL-1.1 (Change Date
1 June 2030, converting to GPL-2.0-or-later).
