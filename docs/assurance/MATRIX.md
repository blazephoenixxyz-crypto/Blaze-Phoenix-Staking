# Assurance matrix — BlazePhoenixStaking

Which areas of the contract the Foundry suite exercises, on which axis, and where it does not.
Rows are areas (groups of entry points and internal mechanisms); columns are the 24 axes below.
Each cell is the **number of tests** that exercise that area on that axis, measured by grep.

Re-measured after the view readers were collapsed and the maintenance sweep was made to book
every loss before it pays (the parity tests in `test/hardening/MorphismParity.t.sol`, and the
third-party, seizure, carrier and order tests in `test/hardening/MaintenanceBeforePayment.t.sol`
and `test/fix1102/SelfCarrierNormalisation.t.sol`), and after a loss not yet recorded was pinned
reading solvent (`test/hardening/UnbookedLossReadIsALowerBound.t.sol`, with the emission reserve
empty and live), and after the reward debts were made to round up at the checkpoint (I7:
`test/attack/DebtRoundsUp.t.sol`) and the attack suite was added (`test/attack/`, with
`test/hardening/EmissionResidueOrigin.t.sol`), and after an attribution that no settle follows was
made to refresh the position's equity summand (`test/hardening/AttributionRefreshesEquity.t.sol`,
with the campaign invariants in `test/InvariantsFullSurface.t.sol`), and after the batch poke and
the direct seizure were made to book their caller's own loss before the bonus they pay (the
LOSS-FIRST carrier tests in `test/hardening/MaintenanceBeforePayment.t.sol`), and after bit 4 of `auditInvariants` was made to read the boost bound that holds on every clock (`test/hardening/AuditBit4Clock.t.sol`), and after the deferred credit was pinned to its one quote (`test/hardening/DeferredPureYieldQuote.t.sol`): **486 tests in 62 `.t.sol`
files** by the counting rule below, which also counts the report-only `check_*` specs.
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
| deposit / top-up / lock | - | 56 | 70 | 60 | 40 | 10 | 54 | 233 | 53 | 60 | 42 | 24 | 3 | - | - | 26 | 26 | 40 | **0** | 121 | 74 | **0** | - | - |
| withdraw | - | 1 | 4 | 7 | 5 | 3 | 14 | 26 | 4 | 9 | 12 | 1 | **0** | - | - | 6 | 4 | **0** | **0** | 14 | 4 | **0** | - | - |
| borrow / repay | - | 35 | 47 | 50 | 21 | 8 | 30 | 171 | 36 | 54 | 18 | 15 | 3 | - | - | 11 | 24 | 18 | **0** | 79 | 58 | **0** | - | - |
| interest | - | 3 | 4 | 7 | 6 | **0** | 3 | 24 | 4 | 11 | **0** | **0** | **0** | - | - | 2 | 3 | 6 | **0** | 6 | 15 | **0** | - | - |
| emission / rewards | - | 29 | 58 | 44 | 39 | 9 | 36 | 165 | 34 | 34 | 30 | 17 | 1 | - | - | 43 | 17 | 28 | **0** | 134 | 58 | **0** | - | - |
| pure yield | - | 7 | 9 | 9 | 7 | 2 | 7 | 32 | 6 | 11 | 4 | 5 | 1 | - | - | 3 | 4 | 6 | **0** | 15 | 23 | **0** | - | - |
| liquidation | - | 1 | 7 | 6 | 3 | **0** | 8 | 26 | 7 | 11 | 4 | 2 | **0** | - | - | **0** | 3 | **0** | **0** | 12 | 12 | **0** | - | - |
| maintenance windows | - | 3 | 8 | 3 | 3 | 2 | 6 | 20 | **0** | 5 | 6 | **0** | **0** | - | - | 1 | 1 | 4 | **0** | 4 | 6 | **0** | - | - |
| lock sweep / poke | - | 55 | 30 | 18 | 6 | 2 | 16 | 75 | 13 | 25 | 13 | 12 | 1 | - | - | 9 | 7 | 15 | **0** | 38 | 20 | **0** | - | - |
| emergency / breaker | - | 20 | 11 | 37 | 2 | 7 | 47 | 64 | 10 | 124 | 18 | 11 | 2 | - | - | 3 | 36 | 10 | **0** | 58 | 21 | **0** | - | - |
| admin / reserves | - | 19 | 40 | 60 | 30 | 7 | 37 | 150 | 32 | 48 | 32 | 11 | 2 | - | - | 27 | 38 | 26 | **0** | 161 | 48 | **0** | - | - |
| views / solvency | - | 22 | 33 | 44 | 22 | 11 | 29 | 133 | 20 | 42 | 26 | 11 | 1 | - | - | 14 | 25 | 23 | **0** | 79 | 48 | **0** | - | - |

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
| E | events | `expectEmit`, `recordLogs` | 21 `emit` sites in `src/` |
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
| deposit / top-up / lock | - | 61 | 72 | 62 | 40 | 10 | 54 | 241 | 53 | 62 | 42 | 24 | 3 | - | - | 26 | 28 | 40 | **0** | 123 | 77 | **0** | - | - |
| withdraw | - | 1 | 4 | 7 | 5 | 3 | 14 | 26 | 4 | 9 | 12 | 1 | **0** | - | - | 6 | 4 | **0** | **0** | 14 | 4 | **0** | - | - |
| borrow / repay | - | 36 | 49 | 52 | 21 | 8 | 30 | 175 | 36 | 56 | 18 | 15 | 3 | - | - | 11 | 26 | 18 | **0** | 81 | 60 | **0** | - | - |
| interest | - | 6 | 7 | 9 | 6 | **0** | 3 | 30 | 4 | 13 | **0** | **0** | **0** | - | - | 2 | 5 | 6 | **0** | 8 | 16 | **0** | - | - |
| emission / rewards | - | 31 | 60 | 45 | 39 | 9 | 36 | 171 | 34 | 35 | 30 | 17 | 1 | - | - | 43 | 18 | 28 | **0** | 135 | 60 | **0** | - | - |
| pure yield | - | 9 | 11 | 11 | 7 | 2 | 7 | 37 | 6 | 13 | 4 | 5 | 1 | - | - | 3 | 6 | 6 | **0** | 17 | 25 | **0** | - | - |
| liquidation | - | 1 | 7 | 6 | 3 | **0** | 8 | 26 | 7 | 11 | 4 | 2 | **0** | - | - | **0** | 3 | **0** | **0** | 12 | 12 | **0** | - | - |
| maintenance windows | - | 3 | 8 | 3 | 3 | 2 | 6 | 20 | **0** | 5 | 6 | **0** | **0** | - | - | 1 | 1 | 4 | **0** | 4 | 6 | **0** | - | - |
| lock sweep / poke | - | 61 | 31 | 19 | 6 | 2 | 16 | 81 | 13 | 26 | 13 | 12 | 1 | - | - | 9 | 8 | 15 | **0** | 39 | 21 | **0** | - | - |
| emergency / breaker | - | 21 | 13 | 39 | 2 | 7 | 47 | 66 | 10 | 126 | 18 | 11 | 2 | - | - | 3 | 38 | 10 | **0** | 60 | 21 | **0** | - | - |
| admin / reserves | - | 20 | 42 | 62 | 30 | 7 | 37 | 152 | 32 | 50 | 32 | 11 | 2 | - | - | 27 | 40 | 26 | **0** | 163 | 48 | **0** | - | - |
| views / solvency | - | 25 | 36 | 46 | 22 | 11 | 29 | 141 | 20 | 44 | 26 | 11 | 1 | - | - | 14 | 27 | 23 | **0** | 81 | 51 | **0** | - | - |

288 cells: 60 without object, 228 measured, **37 empty**.

## 5. Cells ordered empty-first

### 5.1 Whole axes empty (24 cells)

| axis | cells | why it is empty | what fills it |
|---|---|---|---|
| X artefact | 12 / 12 | `DeployedSizeGateTest` is the only artefact test and names no area; the gate is global | per-area: none needed while the size gate is global; the axis stays a single global row |
| U unmeasured | 12 / 12 | the only `check_` functions are the Halmos MathLib specs, which name no area | a report-only spec per area, if one is ever written |

The events axis (E), empty at `cedd80d`, is now covered by `test/assurance/EventPayloads.t.sol`
except in the maintenance-windows area.

### 5.2 Area cells empty (13 cells) — the first places to look

| cell | reading |
|---|---|
| M · interest | no interest-area test asserts a refusal (G · interest filled by `test/fix1027/StaleQuantityFamily.t.sol`, 3236) |
| S · interest, S · liquidation | no reentrancy / hook test in these areas (the maintenance windows and the lock sweep are reached by `test/attack/HookTokenReentrancy.t.sol`) |
| I · interest, I · maintenance windows | no parity- or mirror-named test |
| H · withdraw, H · interest, H · liquidation, H · maintenance windows | no test text records a fix commit or pre-fix state |
| O · withdraw, O · liquidation | no literal oracle: assertions compare contract readings only |
| K · liquidation | no test varies the constructor or the emission window |
| E · maintenance windows | no test watches `MaintenanceSwept` or the events a window emits |

### 5.3 Thinnest non-empty cells (count 1 and 2)

- **1** (9): A·withdraw, I·withdraw, H·emission / rewards, H·pure yield, A·liquidation,
  K·maintenance windows, W·maintenance windows, H·lock sweep / poke, H·views / solvency
- **2** (8): K·interest, S·pure yield, I·liquidation, S·maintenance windows, S·lock sweep / poke,
  Q·emergency / breaker, H·emergency / breaker, H·admin / reserves

The full ordering (every count) is printed by the script.

## 6. Limits of this matrix

- It counts mentions. A `G` cell counts tests that call `expectRevert`, not guards that have a
  watcher; the watcher of each guard is the mutant register (`.github/scripts/mutants.py`).
- Helper expansion is one level deep; a test that reaches an area only through a helper of a helper
  is not counted there.
- The `.mjs` suites are excluded, so axes they cover (for example real-EVM events) can read empty.
- Regexes are coarse: `withdraw` does not match `emergencyWithdraw` (different area) but an area can
  still pick up a test that only reads one of its views.
