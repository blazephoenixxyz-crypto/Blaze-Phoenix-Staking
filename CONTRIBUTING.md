# Contributing

Thanks for reading the code. This file describes how work enters this repository. Security
questions do **not** belong here — see [`SECURITY.md`](SECURITY.md), and write to
contact@blazephoenix.xyz rather than opening a public issue or a public fix branch.

## The rule that matters most: red before green

A change that fixes a defect arrives with a test that **fails without it**. Not a test that passes
with it — one that **fails without it**. A test that has never been red proves nothing about the
fix it accompanies. If you cannot make the test fail on the unfixed code, you have not yet
understood the defect.

The same holds for a guard: adding a guard implies adding the mutant that proves the guard has a
watcher. `.github/scripts/mutants.py` pairs each curated mutant with the one test that must catch
it, and the CI job `mutant-guards` fails when a mutant's target line moves out from under it. A
guard without a watcher does not merge.

## Before opening a pull request

```bash
npm ci
forge build
forge test                                  # has to be green
forge build --sizes                         # nothing may cross EIP-170 (24 576 bytes)
bash .github/scripts/shared-quantities.sh   # the register must agree with the code
python3 .github/scripts/check_targets.py    # every curated mutant still finds its line (~1 s)
node test/<suite>.mjs                       # the real-EVM suites run offline; CI gates all nine
```

Run the mutation guard itself on a **green** suite, alone: `python3 .github/scripts/mutants.py`
rewrites `src/` in place (and restores it) one mutant at a time, so nothing else may be editing the
tree while it runs.

The `.mjs` harness runs in a real EVM **offline** — nine suites (`smoke`, `run`, `attack`, `boost`,
`vectors`, `dimensions`, `final`, `reporting`, `selfaudit`), all of them gate the build. There are
no fork tests.

## If your change touches a shared quantity

[`SHARED_QUANTITIES.md`](SHARED_QUANTITIES.md) lists every quantity with more than one producer or
consumer. If your change introduces a second producer of an existing quantity — or a new quantity
a second place will read — **add the row**. State the **question** the quantity answers, not only
its name: two consumers of `utilisation` asking *"what rate is in force?"* and *"what should I
assume it is?"* drift while looking identical in a grep.

If you declare a `PINNED` row, the test you name has to **exist** and **mention the quantity**.
The CI checks exactly that. If you declare a `SINGLE` row, the CI guard you name has to be present
in `.github/workflows/ci.yml`.

## House conventions

- **Solidity 0.8.28**, pinned (`foundry.toml`, `pragma`). `via_ir` is on. Do not move the pragma.
- **Comments carry the reason** for the line below. When you change that line, **update the reason
  above it** — a comment that survives the code it explains becomes a trap for the next reader.
- **One equation for the money.** The protocol's balances obey the Master Conservation Identity,
  and the `conserves` modifier checks it on every value-moving entry point that wears it.
- **Name the entry point.** Say which entry point your change is paid at (`deposit`, `lock`,
  `borrow`, `claimRewards`, `claimPureYield`, `pokeExpiredLocks`, `maintStep`, `lockStep`, …). An
  optimisation that does not name its entry point is worth nothing.
- **Say what it costs in bytes.** The contract runs close to the EIP-170 ceiling of 24 576 bytes.
  If your change grows it, say by how much.
- **English only** in source, tests, docs and pull requests.
- **No secrets in the clear.** Never commit keys, `.env`, or a seed.

## Commits and pull requests

Conventional prefixes (`fix:`, `feat:`, `test:`, `ci:`, `docs:`, `chore:`), scoped when it helps
(`fix(staking):`). Write the **why** in the body — the diff already shows the **what**. Keep one
pull request to one subject.

## Deliberately out of scope here

- A `release` build profile does not exist in this repository; `forge build --sizes` on the
  `default` profile is the measurement.
- Static analysers in `security.yml` (Slither, Aderyn) run report-only; they are not gates, so they
  are not on the checklist above.
- Halmos specs in `test/formal/` run report-only in CI; a check moves into a gate only after a
  report-only run has measured it discharging cleanly.
