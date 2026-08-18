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

## Verification pipeline and track record

An independent external audit has not happened yet; it is planned before
launch. What runs on every push, today, in public CI: the Foundry suite
(build, tests, EIP-170 size gate) and a real-EVM Node harness of 9 suites.
Solvency is enforced per-transaction on-chain — every value-moving call proves
the conservation identity or reverts — and is publicly readable at any time
via `isSolvent()` or https://blazephoenix.xyz/solvency

Track record so far, across this repo and the DEX sibling: **21 external
reports triaged (8 public + 13 private), every confirmed finding fixed with
regression tests, zero Critical.** Three HIGHs against this contract were
confirmed and closed in public, red-first: the finding becomes a failing CI
test before the fix is written. Credits live in the Security Hall of Fame.

## Bounty programme

**40,000,000 BZPX is allocated to security research** — 4% of a fixed
1,000,000,000 supply, carved out of the token allocation for this and nothing
else. The pool is shared with
[BlazePhoenix-Dex](https://github.com/blazephoenixxyz-crypto/Blaze-Phoenix-Dex);
a finding against either protocol draws from it.

Three things stated up front, because a researcher deserves to decide with open
eyes rather than discover the terms after doing the work:

1. **Rewards are paid in BZPX, not in stablecoins or ETH.** The token is not
   liquid at the time of writing, so the value of an award at the moment it is
   granted is not something we can promise. What we can promise is the quantity
   and the schedule.
2. **Payouts begin after October 2026.** Reports are accepted, triaged and
   acknowledged from now; settlement of awards starts after that date. If that
   timing does not suit you, waiting is an entirely reasonable choice — the
   scope is not going anywhere.
3. **Severity is our assessment, and we will show our reasoning.** Where we
   disagree with a reporter's rating we will say why in writing rather than
   silently downgrading.

| Severity | Award |
|---|---|
| Critical — direct theft or permanent freezing of user funds; a reachable insolvent state | 2,000,000 – 6,000,000 BZPX |
| High — theft under specific conditions, or a redistribution that systematically pays the wrong party | 500,000 – 2,000,000 BZPX |
| Medium — griefing, temporary denial of service, recoverable residue reaching the wrong party | 100,000 – 500,000 BZPX |
| Low — demonstrated impact below the above | up to 100,000 BZPX |

A report must be previously unknown to us and must demonstrate impact rather than
describe a theoretical concern. Duplicates are settled by the timestamp of the
first report received.

One note specific to this protocol, and it is the whole reason the taxonomy above
exists: **a finding does not have to break conservation to be Critical here.**
The guard can be working perfectly while the money goes to the wrong person. If
your report shows that, do not downgrade it yourself on the grounds that the
totals still balance — that is precisely the class we most want to hear about.

## Authorship & integrity

This code is original work by **Fable & Mitra**, licensed BUSL-1.1 (Change Date
1 June 2030, converting to GPL-2.0-or-later).
