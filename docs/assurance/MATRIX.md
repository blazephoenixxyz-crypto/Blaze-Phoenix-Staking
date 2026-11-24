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
LOSS-FIRST carrier tests in `test/hardening/MaintenanceBeforePayment.t.sol`), and after bit 4 of `auditInvariants` was made to read the boost bound that holds on every clock (`test/hardening/AuditBit4Clock.t.sol`), and after the deferred credit was pinned to its one quote (`test/hardening/DeferredPureYieldQuote.t.sol`), and after `syncEquity` was made to write off a position whose stake no longer exceeds its debt (`test/hardening/UnderwaterWriteOffUnblocksCancel.t.sol`). The counting rule below also counts
the report-only `check_*` specs; the script prints the totals (`tests counted: N in M files`), and
counts move with every change, so measure them rather than trusting a number written here.
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
| deposit / top-up / lock | - | 70 | 96 | 68 | 49 | 10 | 71 | 312 | 54 | 97 | 54 | 33 | 4 | - | - | 33 | 40 | 56 | **0** | 172 | 103 | **0** | - | - |
| withdraw | - | 1 | 4 | 7 | 5 | 3 | 14 | 29 | 4 | 9 | 12 | 3 | **0** | - | - | 8 | 4 | 2 | **0** | 17 | 6 | **0** | - | - |
| borrow / repay | - | 41 | 57 | 54 | 21 | 8 | 39 | 207 | 37 | 82 | 23 | 20 | 3 | - | - | 13 | 38 | 26 | **0** | 103 | 76 | **0** | - | - |
| interest | - | 9 | 9 | 9 | 6 | **0** | 6 | 37 | 5 | 17 | 3 | 1 | **0** | - | - | 2 | 8 | 8 | **0** | 12 | 22 | **0** | - | - |
| emission / rewards | - | 37 | 88 | 50 | 48 | 9 | 43 | 230 | 34 | 58 | 36 | 25 | 2 | - | - | 51 | 25 | 49 | **0** | 179 | 85 | **0** | - | - |
| pure yield | - | 10 | 12 | 12 | 7 | 2 | 8 | 45 | 6 | 18 | 5 | 6 | 1 | - | - | 5 | 6 | 12 | **0** | 25 | 34 | **0** | - | - |
| liquidation | - | 2 | 7 | 6 | 3 | **0** | 10 | 28 | 7 | 11 | 6 | 2 | **0** | - | - | **0** | 3 | 1 | **0** | 12 | 14 | **0** | - | - |
| maintenance windows | - | 7 | 8 | 3 | 3 | 2 | 6 | 26 | **0** | 10 | 6 | **0** | 1 | - | - | 1 | 3 | 5 | **0** | 8 | 6 | **0** | - | - |
| lock sweep / poke | - | 65 | 32 | 19 | 6 | 2 | 20 | 90 | 13 | 29 | 17 | 12 | 2 | - | - | 9 | 8 | 21 | **0** | 43 | 22 | **0** | - | - |
| emergency / breaker | - | 25 | 22 | 42 | 2 | 7 | 56 | 102 | 11 | 163 | 24 | 14 | 3 | - | - | 3 | 50 | 18 | **0** | 86 | 35 | **0** | - | - |
| admin / reserves | - | 29 | 60 | 65 | 36 | 7 | 42 | 203 | 33 | 77 | 37 | 18 | 3 | - | - | 32 | 52 | 41 | **0** | 211 | 67 | **0** | - | - |
| views / solvency | - | 30 | 47 | 48 | 24 | 11 | 38 | 175 | 21 | 70 | 31 | 16 | 2 | - | - | 14 | 37 | 30 | **0** | 99 | 67 | **0** | - | - |

288 cells: 60 without object, 228 measured, **32 empty**.

## 5. Cells ordered empty-first

### 5.1 Whole axes empty (24 cells)

| axis | cells | why it is empty | what fills it |
|---|---|---|---|
| X artefact | 12 / 12 | `DeployedSizeGateTest` is the only artefact test and names no area; the gate is global | per-area: none needed while the size gate is global; the axis stays a single global row |
| U unmeasured | 12 / 12 | the only `check_` functions are the Halmos MathLib specs, which name no area | a report-only spec per area, if one is ever written |

The events axis (E), empty at `cedd80d`, is now covered by `test/assurance/EventPayloads.t.sol`
except in the maintenance-windows area.

### 5.2 Area cells empty (8 cells) — the first places to look

| cell | reading |
|---|---|
| S · interest, S · liquidation | no reentrancy / hook test in these areas (the maintenance windows and the lock sweep are reached by `test/attack/HookTokenReentrancy.t.sol`) |
| I · maintenance windows | no parity- or mirror-named test |
| H · withdraw, H · interest, H · liquidation | no test text records a fix commit or pre-fix state |
| K · liquidation | no test varies the constructor or the emission window |
| E · maintenance windows | no test watches `MaintenanceSwept` or the events a window emits |

### 5.3 Thinnest non-empty cells (count 1 and 2)

- **1** (6): A·withdraw, I·interest, H·pure yield, O·liquidation, H·maintenance windows, K·maintenance windows
- **2** (11): O·withdraw, K·interest, H·emission / rewards, S·pure yield, A·liquidation, I·liquidation, S·maintenance windows, S·lock sweep / poke, H·lock sweep / poke, Q·emergency / breaker, H·views / solvency

The full ordering (every count) is printed by the script.

## 6. Limits of this matrix

- It counts mentions. A `G` cell counts tests that call `expectRevert`, not guards that have a
  watcher; the watcher of each guard is the mutant register (`.github/scripts/mutants.py`).
- Helper expansion is one level deep; a test that reaches an area only through a helper of a helper
  is not counted there.
- The `.mjs` suites are excluded, so axes they cover (for example real-EVM events) can read empty.
- Regexes are coarse: `withdraw` does not match `emergencyWithdraw` (different area) but an area can
  still pick up a test that only reads one of its views.
