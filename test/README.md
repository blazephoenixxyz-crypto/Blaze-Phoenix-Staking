# Tests

Two complementary suites.

**Security credits.** `boost.mjs` and the `test_StaleBoost_*` / `test_stress_lockerRegistryFlood_*`
Foundry cases exist because of **BP-2026-001 — "Stale Boost Persistence in Pure Stakers"**,
disclosed on 28 July 2026 by **[NetGakarot](https://github.com/NetGakarot)** ("Gakarot").

## 1. JS / real-EVM harness — runs anywhere with Node (no Foundry needed)

Executes the contract on a real EVM (`@ethereumjs/vm`), fully offline. This is what was run in the
cloud sandbox; **77 checks across 18 scenarios pass**.

```bash
npm install
node test/run.mjs        # full integrity + edge-case suite      (80 checks)
node test/attack.mjs     # adversarial suite, 16 exploit vectors (76 checks)
node test/boost.mjs      # stale-boost / lock-expiry, B1..B10   (174 checks)
node test/smoke.mjs      # quick deploy/sanity check
```

Files: `compile.mjs` (solc + a mock BZPX, viaIR), `lib.mjs` (EVM wrapper + assertions),
`run.mjs` (the integrity suite), `attack.mjs` (the adversarial suite), `boost.mjs` (the
lock-expiry suite), `smoke.mjs` (smoke test).

### `boost.mjs` — the BP-2026-001 regression suite

The bug: `_autoMaintain` iterated `_borrowers` only, and a **pure staker** (`debt == 0`) is never in
that array — so an idle staker whose lock had expired kept its historical multiplier in
`totalBoostedEffective` / `totalBoostedPure` indefinitely, drawing an oversized share of every
ongoing distribution. Solvency was never reachable (boost is a denominator weight, never a claim on
value); yield fairness and the incentive to re-lock were.

The fix has two axes and the suite pins both, because **either alone is insufficient**:

- **(a) derivation** — expiry is evaluated against `block.timestamp`, so no path can re-price a
  lapsed commitment. *Alone, it only re-prices a position somebody already touched.*
- **(b) propagation** — the `_lockers` registry gives the autonomous engine a second window that
  **can** see debt-free positions. *Alone, it leaves the stale multiplier re-derivable between
  expiry and sweep.*

| | Scenario |
|---|---|
| B1 | the PoC from the report — idle vs active staker, identical principal, lapsed 730d lock |
| B2 | an elapsed commitment is priced at 1.00× before any state is mutated |
| B3 | registry lifecycle — every live commitment tracked, every exit path de-registers |
| B4 | `pokeExpiredLock` / `pokeExpiredLocks` — permissionless, batch-safe, duplicate-safe |
| B5 | `expiredLockScan` quantifies the backlog exactly; its own output clears it |
| B6 | game theory — re-locking beats idling by exactly the lock premium |
| B7 | no confiscation — the sweep **pays** the boosted backlog before re-pricing the future |
| B8 | gas bound — a 40-deep expired backlog cannot make an ordinary tx expensive |
| B9 | a locker the token refuses to pay cannot stall the sweep or grief a user |
| B10 | `lockStep` is self-only; conservation holds across a long expiry-heavy sequence |

**B1 deliberately uses only the v3.0.0 ABI.** Run it against the vulnerable contract and it fails on
the reported divergence itself — idle:active yield ratio `12500` (1.25×) and a `2.25M` denominator,
against the corrected `10000` and `2.0M` — not on a missing function. That is what makes it a
regression test rather than a tautology.

Covers: boost curve; mandatory-lock deposit (90..2555 + countdown); top-up extend-only; per-wallet
cap; borrow LTV; **withdraw requires full repayment**; interest accrual; liquidation (direct +
**autonomous via another user's tx**); emission funding/claim; **deterministic emission (no
backlog capture)**; emergency halt + `emergencyWithdraw`; `tripBreaker` only on insolvency;
access control; standalone lock extend/expiry; and **solvency holds across a long mixed sequence**.

## 2. Foundry suite — for Termux / any machine with Foundry

`BlazePhoenixStaking.t.sol` adds **fuzz + invariant** testing (Foundry's strength), which the JS
harness does not do. It was **not** run in the cloud sandbox (no network there to install Foundry).

```bash
forge install foundry-rs/forge-std      # once
forge test -vvv                         # unit tests
forge test --match-contract Invariant -vvv
```

Invariants asserted under random action sequences (deposit / borrow / repay / withdraw / claim /
liquidate / time-warp):

- `invariant_solvent` — `isSolvent()` is always true.
- `invariant_conservationBit` — the on-chain conservation bit is never set.
- `invariant_boostBounded` — boosted denominators never exceed `stake · maxBoost / base`.
- `invariant_backingCoversOwed` — `backing + dust ≥ owed` always.
- `invariant_everyLiveCommitmentIsTracked` — **the load-bearing BP-2026-001 invariant.** The locker
  registry is the only window that can see a debt-free position, so a live lock that escapes it is a
  lock the engine can never normalise — i.e. the original stale-boost bug returning, whatever the
  boost derivation says.
- `invariant_lockRegistryHasNoDuplicates` — the registry is a set, not a bag: a duplicated entry
  would release one position's weight twice and underflow the single-writer subtraction.
- `invariant_staleBoostExcessIsBounded` — weight transiently outstanding between an expiry and its
  sweep stays inside the same `stake · maxBoost` envelope as the denominators themselves.

The handler adds `relock`, `poke` and `passLockPeriod` (60–800 days) so lock **expiry** is inside
the fuzzed state space rather than a case only the unit tests reach.

> Note: the constructor grants `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` to the deployer but does **not**
> grant `GUARDIAN_ROLE` to anyone — the admin must `grantRole(keccak256("GUARDIAN_ROLE"), guardian)`
> before `pause()` / `declareEmergency()` can be used. The tests do this explicitly.
