# Assurance matrix — BlazePhoenixStaking

Which areas of the contract the Foundry suite exercises, on which axis, and where it does not.
Rows are areas (groups of entry points and internal mechanisms); columns are the 24 axes below.
Each cell is the **number of tests** that exercise that area on that axis, measured by grep.

Re-measured on `fix-staking-1022` (base `c31b6c5` plus the loss-first, reserve fresh-read, sweep
and deferral-boundary tests of the follow-up commit, and the withdraw's own-gate test): **312 tests in 42 `.t.sol` files**.
Regenerate with:

```bash
python3 .github/scripts/assurance_matrix.py          # the tables below
python3 .github/scripts/assurance_matrix.py --tsv    # one line per cell
```

## 1. The counting rule

- **A test** is one `function test*` / `testFuzz*` / `invariant*` / `check_*` in `test/**/*.t.sol`.
  Its **text** is the comment lines directly above it, its body, and the bodies of the helpers it
  calls by name (one level, same file first, then the shared `Base` in
  `test/BlazePhoenixStaking.t.sol`).
- **A test is in an area** when its text matches the area regex, and **on an axis** when it matches
  the axis regex. A test may sit in several areas and on several axes.
- Both regex lists live in `.github/scripts/assurance_matrix.py` and are the definition of the
  matrix: changing a regex changes the matrix.
- The real-EVM `.mjs` harness is **not** counted (its checks are not functions).

This is a census of what tests **mention**, not of what they reach. A cell above zero says some
test names both the area and the axis instrument; it does not say the property is pinned. A cell at
zero is a fact about the suite and the place to look first.

## 2. Areas

| area | what puts a test in it (regex summary) |
|---|---|
| deposit / top-up / lock | calls `deposit` or `lock` |
| withdraw | calls `withdraw` |
| borrow / repay | calls `borrow`, `repay`, or reads `maxBorrowOf` |
| interest | the interest index, global accrual, live or simulated rate, utilisation |
| emission / rewards | `claimRewards`, `pendingRewards`, `fundEmission`, the emission curve and reserve |
| pure yield | `claimPureYield`, `pendingPureYield`, `pureStakerApr`, the pure-weight accumulators |
| liquidation | `liquidate`, `healthFactor`, `daysToLiquidation`, the liquidation constants |
| maintenance windows | `maintStep`, the borrower registry and its views, `maintenanceBudget` |
| lock sweep / poke | `pokeExpiredLock(s)`, `lockStep`, the locker registry and lock-expiry views |
| emergency / breaker | `emergencyWithdraw`, `declareEmergency`, `cancelEmergency`, `tripBreaker`, `pause` |
| admin / reserves | `withdrawReserve`, `sweepUndistributedEmission`, `fundEmission`, roles |
| views / solvency | `owed`, `backing`, `isSolvent`, `collateralRatio`, `solvency`, `auditInvariants`, `getUserInfo`, `getGlobalStats` |

## 3. Axes

| # | axis | what puts a test on it (regex summary) | object in this repository |
|---|---|---|---|
| P | proxy / upgrade | — | **none**: the contract is not upgradeable (no `delegatecall`, `upgradeTo` or ERC-1967 in `src/`) |
| A | arrays / iteration | batch pokes, registry pages and indices | registries `_borrowers`, `_lockers` |
| D | dimensions / casts / bits | `type(uint…).max`, narrowing casts, shifts | casts, the emission shifts |
| V | vectors / hashes | `keccak256`, `abi.encode*` | role ids, encoded revert data |
| Q | quantities / thresholds | names a contract constant or a literal oracle | every constant and threshold |
| S | seams / dispatch | reentrancy, hooks, callbacks, mocked calls | token transfers out |
| G | guards | `expectRevert` | every refusal |
| T | time / regime | `vm.warp`, `vm.roll`, `skip`, `rewind` | locks, emission, interest, block guards |
| E | events | `expectEmit`, `recordLogs` | 22 `emit` sites in `src/` |
| Y | switches | `pause`, `unpause`, breaker, emergency | pause and emergency regimes |
| M | masking | `expectRevert(<X>.selector)` — the refusal is pinned to one selector | every refusal |
| I | siblings / mirror | the test name states an agreement, a twin, a split or a mirror | parity pairs |
| H | history | the test text records the commit or the pre-fix state | fixes |
| R | replication / census | — | **none**: one contract, not deployed |
| Z | deployed revision | — | **none**: not deployed from this tree |
| K | values / config | constructor, `emissionStart` / `emissionEnd`, token and treasury | constructor arguments and immutables |
| W | keys / roles | roles, `AccessControl`, `Unauthorized` | `ROLE_ADMIN`, `ROLE_GUARDIAN` |
| O | independent oracle | an `assertEq` against a numeric literal, or a named literal / expected value | every assertion |
| X | artefact | code size, `extcodesize`, the EIP-170 gate | the deployed bytecode |
| C | config / admin posture | acts as `admin` or names an admin role | privileged entry points |
| N | instrument / verdict | non-vacuity: a precondition, or `assertGt(x, 0)` | every test |
| U | unmeasured by `forge test` | `check_` functions (Halmos, report-only) | formal specs |
| L | live funds | — | **none**: not deployed |
| J | critical window | — | **none**: no on-chain history |

## 4. The matrix

`-` = the axis has no object here (section 3). **Bold zero** = empty cell.

| area | P | A | D | V | Q | S | G | T | E | Y | M | I | H | R | Z | K | W | O | X | C | N | U | L | J |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| deposit / top-up / lock | - | 20 | 40 | 38 | 18 | 5 | 46 | 155 | 32 | 51 | 41 | 12 | 3 | - | - | 12 | 28 | 30 | **0** | 76 | 51 | **0** | - | - |
| withdraw | - | 1 | 2 | 4 | 3 | 2 | 12 | 18 | 3 | 7 | 11 | **0** | **0** | - | - | 1 | 3 | **0** | **0** | 7 | 2 | **0** | - | - |
| borrow / repay | - | 6 | 29 | 27 | 13 | 4 | 18 | 102 | 22 | 33 | 15 | 6 | 3 | - | - | 3 | 17 | 16 | **0** | 47 | 38 | **0** | - | - |
| interest | - | 1 | 2 | 5 | 5 | **0** | **0** | 15 | 4 | 4 | **0** | **0** | **0** | - | - | 1 | 2 | 5 | **0** | 4 | 14 | **0** | - | - |
| emission / rewards | - | 10 | 33 | 31 | 12 | 5 | 26 | 92 | 19 | 34 | 24 | 4 | 1 | - | - | 21 | 21 | 13 | **0** | 73 | 32 | **0** | - | - |
| pure yield | - | 3 | 2 | 3 | 6 | 1 | 6 | 20 | 3 | 7 | 5 | 2 | 1 | - | - | 1 | 2 | 4 | **0** | 8 | 12 | **0** | - | - |
| liquidation | - | 1 | 6 | 3 | 2 | **0** | 5 | 17 | 4 | 10 | 3 | 2 | **0** | - | - | **0** | 2 | **0** | **0** | 8 | 8 | **0** | - | - |
| maintenance windows | - | 3 | 7 | 1 | 3 | **0** | 6 | 18 | **0** | 5 | 6 | **0** | **0** | - | - | 1 | 1 | 4 | **0** | 4 | 6 | **0** | - | - |
| lock sweep / poke | - | 21 | 15 | 5 | **0** | **0** | 13 | 30 | 4 | 12 | 11 | 4 | **0** | - | - | 2 | 3 | 6 | **0** | 13 | 9 | **0** | - | - |
| emergency / breaker | - | 5 | 8 | 35 | 1 | 5 | 44 | 40 | 6 | 105 | 22 | 3 | 1 | - | - | 2 | 37 | 10 | **0** | 54 | 15 | **0** | - | - |
| admin / reserves | - | 7 | 23 | 45 | 7 | 4 | 23 | 85 | 19 | 48 | 21 | 3 | 2 | - | - | 11 | 37 | 17 | **0** | 94 | 28 | **0** | - | - |
| views / solvency | - | 8 | 20 | 27 | 8 | 7 | 23 | 80 | 6 | 38 | 22 | 5 | 1 | - | - | 2 | 23 | 15 | **0** | 43 | 33 | **0** | - | - |

288 cells: 60 without object, 228 measured, **43 empty**.

## 5. Cells ordered empty-first

### 5.1 Whole axes empty (24 cells)

| axis | cells | why it is empty | what fills it |
|---|---|---|---|
| X artefact | 12 / 12 | `DeployedSizeGateTest` is the only artefact test and names no area; the gate is global | per-area: none needed while the size gate is global; the axis stays a single global row |
| U unmeasured | 12 / 12 | the only `check_` functions are the Halmos MathLib specs, which name no area | a report-only spec per area, if one is ever written |

The events axis (E), empty at `cedd80d`, is now covered by `test/assurance/EventPayloads.t.sol`
except in the maintenance-windows area.

### 5.2 Area cells empty (19 cells) — the first places to look

| cell | reading |
|---|---|
| G · interest, M · interest | no interest-area test asserts a refusal |
| S · interest, S · liquidation, S · maintenance windows, S · lock sweep / poke | no reentrancy / hook test in these areas |
| I · interest, I · withdraw, I · maintenance windows | no parity- or mirror-named test |
| H · withdraw, H · interest, H · liquidation, H · maintenance windows, H · lock sweep / poke | no test text records a fix commit or pre-fix state |
| O · withdraw, O · liquidation | no literal oracle: assertions compare contract readings only |
| K · liquidation | no test varies the constructor or the emission window |
| E · maintenance windows | no test watches `MaintenanceSwept` or the events a window emits |
| Q · lock sweep / poke | no test names a constant (e.g. `MAX_LOCK_DAYS`) |

### 5.3 Thinnest non-empty cells (count 1 and 2)

- **1** (16): A·withdraw, K·withdraw, A·interest, K·interest, H·emission / rewards, S·pure yield,
  H·pure yield, K·pure yield, W·pure yield, A·liquidation, V·maintenance windows, K·maintenance
  windows, W·maintenance windows, Q·emergency / breaker, H·emergency / breaker, H·views / solvency
- **2** (16): D·withdraw, S·withdraw, W·withdraw, N·withdraw, D·interest, W·interest, D·pure yield,
  V·pure yield, I·pure yield, Q·liquidation, I·liquidation, W·liquidation, K·lock sweep / poke,
  K·emergency / breaker, H·admin / reserves, K·views / solvency

The full ordering (every count) is printed by the script.

## 6. Limits of this matrix

- It counts mentions. A `G` cell counts tests that call `expectRevert`, not guards that have a
  watcher; the watcher of each guard is the mutant register (`.github/scripts/mutants.py`).
- Helper expansion is one level deep; a test that reaches an area only through a helper of a helper
  is not counted there.
- The `.mjs` suites are excluded, so axes they cover (for example real-EVM events) can read empty.
- Regexes are coarse: `withdraw` does not match `emergencyWithdraw` (different area) but an area can
  still pick up a test that only reads one of its views.
