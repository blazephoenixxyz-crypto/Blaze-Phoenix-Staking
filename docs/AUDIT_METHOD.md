# Audit method

What makes a test a piece of evidence here, and what the suite can and cannot say about the
contract. The debts are listed as debts.

The chain every guarantee is routed through:

> threat → property → guard → test → **mutant** → register

If a link is missing, the guarantee is a claim, not evidence. The first four are the usual work;
the last two are what this document exists to keep honest: a guard with no mutation test may be a
tautology, and a quantity with two producers that no test compares will drift.

## 1. Red before green

A test that guards a change is written red against the tree without it, and its header records the
commit where that was measured. A test that never failed has not been shown to depend on anything.
`CONTRIBUTING.md` carries this as the standing rule.

## 2. A curated mutation guard, not mutation coverage

Every guard is paired, by hand, with one **exact** line of source in `.github/scripts/mutants.py`:
alter that one line and the named test must go red. Three ways a verdict is void, all reported as
failures rather than skipped:

- the paired test is **already red** at baseline (it is not watching the mutant);
- the **target line is gone** (`check_targets.py` fails before anything is mutated);
- the mutant's deployed bytecode is **byte-identical** to pristine (INERT — usually a masked or
  dead branch), flagged separately so it cannot masquerade as a caught mutant.

The run needs a green suite and rewrites `src/` in place — run it alone. What this buys over
coverage: each mutant names the sentence it falsifies. What it does not buy: any statement about
the mutants nobody wrote. There is no mutation score; the register is the population, and the
register is deliberately small.

Constants are mutated too, by value. A test that reads a constant back from the contract moves
with the mutant and cannot catch it, so constants are pinned by **literal** oracles taken from the
published specification (`test/assurance/ConstantOracles.t.sol`,
`test/assurance/DeliveryIndex.t.sol`).

## 3. One question, one answer

A quantity with two producers is named in [`../SHARED_QUANTITIES.md`](../SHARED_QUANTITIES.md):
the question it answers, both producers, and the one test that pins them equal.
`.github/scripts/shared-quantities.sh` fails a `PINNED` row whose test file is missing or never
names the quantity. This is the anti-regression device for the parity family: the test already
exists, and the row stops it being deleted or renamed away by a later refactor.

## 4. Caller data is a coordinate

There is no in-protocol price oracle; the inputs that matter are the axes the caller cannot move:
time (lock start, unlock horizon, emission schedule), regime (normal / paused / emergency), position
health (stake vs debt), and block ordering. Tests are written to occupy **regimes**, not lines:
`MetamorphicRelations.t.sol` states relations that must hold across the boost, rate and emission
curves, `ViewsQuoteEqualsExecutionFuzz.t.sol` fuzzes the parity property, and the conservation walk
(`FullSurfaceConservationTest`) checks the identity after each value-moving entry point in a fixed
order. Entry points that fork on caller state (`deposit`, `lock`, `borrow`, `withdraw`) get their
refusal geometry enumerated in the boundary suite before their happy path is decorated.

## 5. Every refusal has a watcher

A static census of `src/BlazePhoenixStaking.sol` at `cedd80d` counted **25 refusal selectors across
62 `revert` sites**; two selectors were named by no test, and now have watchers
(`test/GuardWatchers.t.sol`). This is a census, not an instrument: it proves a selector is
*named* somewhere, not that the discriminating variable is *reachable* at that site, and not that
the refusal is *distance-sensitive*. Reachability is argued per mutant, in the register.

## 6. Beyond line coverage

`forge coverage` numbers are not used as evidence. What stands in their place:

- **Boundary equality** — each bound asserted at the bound and one wei past it.
- **Regime suites** — `test/fix205/` pins the hardening fixes; `test/hunt/` holds the adversarial
  campaigns (push-side reentrancy, admin surface, attribution lag, exact attribution).
- **Canonical oracles** — expected values computed by an independent route (closed form,
  geometric series, published literals), never by re-running the code under test.
- **Metamorphic relations** — equalities between runs that differ only in a parameter that must not
  matter.
- **The coverage matrix** — [`assurance/MATRIX.md`](assurance/MATRIX.md) counts tests per area and
  axis and lists the empty cells first.

There is **no covering array** (no t-way combinatorial generator) and no symbolic execution outside
`test/formal/` (Halmos, report-only). If a future surface needs those, it gets its own artefact —
the register is not widened silently.

## 7. The compiled artefact, not the source

`DeployedSizeGateTest` deploys the contract and asserts its runtime size against EIP-170, logging
the signed margin, under the same profile `forge test` runs (`default`, `via_ir`, optimizer 200).
Bytecode can pass a behavioural test and still not fit the chain; sizes are asserted where sizes
are enforced.

Not done here: comparing deployed bytecode against the source revision (no artefact fingerprint
step). Behaviour is checked by tests.

## 8. Independent evidence

The `.mjs` harness (`test/*.mjs`) runs against a real EVM **offline**: deployment, realistic
sequences, and the same properties in a second environment that does not share cheatcodes with
Foundry. Parity tests check the two existing producers of a value; the conservation walk checks
the identity after every step; fuzz spends the budget where a regime is continuous.

## 9. Reports from outside

`SECURITY.md` carries the disclosure policy. A report is not "fixed" until it has a red-first test
and, where it ties a guard, a mutant.

## 10. What is deployed

This document measures **this tree**. Nothing here should be read as a statement about deployed
bytecode unless a revision is quoted.

## 11. What is deliberately not claimed

- No probability that the contract is correct, and no score. The absence of a mutant is not
  evidence of safety.
- No mutation coverage of any population other than the register.
- No fork traffic, no mainnet state (the `.mjs` suites are a real EVM, but offline and synthetic).
- The refusal census measures *mention*, not reachability (§5).
- Halmos is report-only and `forge test` does not execute `check_` functions; passing CI does not
  mean those specs hold.
- Invariant depth in CI is modest; the deep campaign exists but is not a gate. One deterministic
  walk is promoted instead, and it is a walk, not a proof.

## 12. Applying the method to a new surface

1. State the property as a sentence — that sentence becomes the test name.
2. Find the regime, not the line: which time, regime, health and ordering values make the property
   *mean* something.
3. Write it red if it guards a change; record where.
4. Make it green, asserting the effect exactly (selector, or an independent oracle).
5. Add the mutant pair and run `check_targets.py`.
6. If two producers exist, add the register row.
7. Update the matrix cell and publish the debt: if the mutant population is partial, the document
   says so (as this one does).
