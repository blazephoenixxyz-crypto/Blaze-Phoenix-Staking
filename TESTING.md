# Testing

How the suite is organised, how to run every gate, and what a test has to satisfy before it counts
as evidence here. The method behind it is in [`docs/AUDIT_METHOD.md`](docs/AUDIT_METHOD.md); the
coverage of the suite, area by axis, is in [`docs/assurance/MATRIX.md`](docs/assurance/MATRIX.md).

The suite has two harnesses: Foundry (`test/**/*.t.sol`) and nine real-EVM `.mjs` suites that run
**offline**. There are no fork tests. Halmos specs under `test/formal/` run report-only —
`forge test` does not execute `check_` functions. Counts move with every change; measure them with
`forge test --list` and `grep -c 'dict(nome' .github/scripts/mutants.py` rather than trusting a
number written here.

## Running

```bash
npm ci                                          # first time only — OpenZeppelin is an npm dependency
forge build
forge test                                      # unit, fuzz, property, invariant, parity

# Contract size against the EIP-170 limit, and the in-suite size gate
forge build --sizes
forge test --match-contract DeployedSizeGateTest

# The guards that judge the suite
python3 .github/scripts/check_targets.py        # every curated mutant still finds its line (~1 s)
python3 .github/scripts/mutants.py              # the mutation guard; run on a GREEN suite, alone
bash    .github/scripts/shared-quantities.sh    # the register must agree with the code

# The real-EVM harness — run it the same way CI does
for s in smoke run attack boost vectors dimensions final reporting selfaudit; do node "test/$s.mjs"; done
```

`mutants.py` rewrites `src/` in place (and restores it) one mutant at a time: run it alone, never
in a command that can be cut short, and check `git status` afterwards.

The suite and the deployed-size gate run on the **same** profile (`default`, `via_ir`, optimizer
200). `[profile.ci]` exists in `foundry.toml`; `profile_parity.py` (CI job `mutant-guards`) checks
that every profile generates the same code.

Fuzz runs at 256 by default. The deeper invariant / fuzz pass in CI is **report-only**, because a
campaign is a search, not a bound. One deterministic fragment is promoted into its own gating step:
the `FullSurfaceConservationTest` walk (see below).

## How the suite is organised

| Where | What lives there |
|---|---|
| `test/*.t.sol` | unit, boundary, metamorphic and parity tests — named for the property each pins |
| `test/fix205/` | regression tests for the hardening fixes (views quote == execution, dust denominator, interest attribution, emergency and exit) |
| `test/hunt/` | adversarial campaigns: push-side reentrancy, admin surface, attribution lag, exact attribution |
| `test/assurance/` | literal oracles: the emission delivery index and the constants no other test pinned by value |
| `test/InvariantsFullSurface.t.sol` | the stateful campaign (`FullSurfaceHandler` + `InvariantsFullSurfaceTest`) **and** the fixed-order conservation walk (`FullSurfaceConservationTest`) |
| `test/GuardWatchers.t.sol` | watchers for refusal selectors no other test named |
| `test/formal/` | Halmos specification for the MathLib primitives (report-only) |
| `test/*.mjs` | the real-EVM harness: nine suites (`smoke`, `run`, `attack`, `boost`, `vectors`, `dimensions`, `final`, `reporting`, `selfaudit`) plus the shared `lib.mjs` / `compile.mjs` |

Three families of test do the load-bearing work:

- **Boundary equality.** Each refusal bound is asserted at the bound and one wei past it
  (`BoundaryEquality.t.sol`), so a `>` that becomes `>=` cannot pass unnoticed — and the mutant
  register watches each of those boundaries by name.
- **Parity.** Two producers of one quantity are asserted equal on the same block: the view quote
  and the transfer `claimRewards` / `claimPureYield` make, `maxBorrowOf` and what `borrow` accepts,
  the projected slice and the executed slice. These are the tests `SHARED_QUANTITIES.md` names.
- **Regression probes.** For each hardening fix, a test whose fixture reaches the regime the fix
  closes and asserts the effect is no longer reachable — beside a control that shows the honest
  case still passes.

## What a test must satisfy here

Before a test is counted, it is read against one question: *what change to the contract would make
this fail?* Three things every test carries:

- **Red first.** A test that guards a fix was red against the code without the fix, and the header
  says at which commit. A guard without a mutant does not merge.
- **An exact effect.** A refusal is asserted by its selector, never a bare `expectRevert()`; a value
  by an oracle that is not the code under test.
- **The property as its name.** The test name is the sentence the property states, so a failure
  reads as a falsified claim.

## What the suite is measured by

- **The mutation guard** — curated mutants in `.github/scripts/mutants.py`, each pairing one exact
  line of source with the one test that must go red once that line is altered. Three ways a
  verdict is void and reported as a failure: the paired test is already red at baseline; the
  target line is gone; the deployed bytecode is byte-identical to pristine (INERT).
- **The shared-quantity register** — each row states the question a multi-producer quantity
  answers and the named test that binds it (`SHARED_QUANTITIES.md`). The check fails a `PINNED` row
  whose test file is missing or never names the quantity.
- **The in-suite size gate** — `DeployedSizeGateTest` asserts the deployed runtime size against
  EIP-170 and logs the signed margin, on the profile the suite runs under.
- **The regime-facing suites** — `MetamorphicRelations.t.sol` (relations and canonical oracles over
  the boost, rate and emission curves), `ViewsQuoteEqualsExecutionFuzz.t.sol` (the parity property,
  fuzzed), and the fixed-order `FullSurfaceConservationTest` walk, which gates.

## Extending the suite

1. Write the property as a sentence. That sentence is the test's name.
2. Build the fixture that reaches the regime the sentence is about, and assert that it did.
3. Write the test red against the current tree if it guards a change; record the commit in the
   header.
4. Make it green. Assert the effect by exact value or exact selector.
5. Add the mutant to `.github/scripts/mutants.py`, run `check_targets.py`, and run that mutant.
6. If the property ties two producers, add or update the row in `SHARED_QUANTITIES.md` and run
   `shared-quantities.sh`.
7. Update the cell it fills in `docs/assurance/MATRIX.md`.

A pull request that adds a guard without steps 5 and 6 is not complete. Conventions and the pre-PR
checklist are in [`CONTRIBUTING.md`](CONTRIBUTING.md).
