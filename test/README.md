# Tests

Two complementary suites.

## 1. JS / real-EVM harness — runs anywhere with Node (no Foundry needed)

Executes the contract on a real EVM (`@ethereumjs/vm`), fully offline. This is what was run in the
cloud sandbox; **77 checks across 18 scenarios pass**.

```bash
npm install
node test/run.mjs        # full integrity + edge-case suite
node test/smoke.mjs      # quick deploy/sanity check
```

Files: `compile.mjs` (solc + a mock BZPX, viaIR), `lib.mjs` (EVM wrapper + assertions),
`run.mjs` (the suite), `smoke.mjs` (smoke test).

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

> Note: the constructor grants `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` to the deployer but does **not**
> grant `GUARDIAN_ROLE` to anyone — the admin must `grantRole(keccak256("GUARDIAN_ROLE"), guardian)`
> before `pause()` / `declareEmergency()` can be used. The tests do this explicitly.
