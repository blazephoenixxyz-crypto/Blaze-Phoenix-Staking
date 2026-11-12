# Monte Carlo campaign 2: the eight-year emission curve, pre-registered

The campaign is BLIND. Everything above the `<!-- RESULTS -->` marker was written and committed
before the first run on a campaign seed, and is not edited after results are seen. A tolerance that
turns out to be wrong is a finding, recorded below as such, not loosened. Everything below the
marker is copied from the TSV lines the test prints
(`forge test --match-contract EmissionCurveWalk -vv`), so it can be rebuilt by anyone.

Campaign 1 (`docs/MONTE_CARLO.md`) walks the whole surface: borrowing, losses, the emergency. This
one walks the emission alone, with no debt in the book, so every settle can be compared wei for wei
with the schedule as it is stated: a linear base of 60M BZPX over 8 years plus a bonus of 16M, 8M,
4M and 2M over four 2-year periods (biennial halving of the bonus), 90M in all.

## Pre-registration

### Seeds (fixed before any data was seen)

Batch `k` uses `seed_k = uint256(keccak256(abi.encodePacked("385b297", uint256(k))))`: the short
hash of the commit that introduced the schedule, which nobody writing this campaign chose, plus the
batch index. Sequence `j` of batch `k` starts its generator at
`keccak256(abi.encodePacked(seed_k, uint256(j)))`, and draw `i` is
`keccak256(abi.encodePacked(state))`. A failing case is fully identified by `(k, j, i)`, and
`ECW_BATCH=k ECW_SEQ=j` replays it: every sequence opens from the same clock on a fresh deployment.

The campaign is batches `k = 0..3`, 24 sequences each, 160 actions per sequence
(`ECW_BATCHES=4 ECW_SEQS=24 ECW_ACTIONS=160`). The in-suite default is batch 0, sequences 0..2, 60
actions. The volume knobs are not tolerances.

Disclosure: before the seed commit existed, the harness was compiled and exercised with the
placeholder seed string `0000000`, to remove errors of the harness itself. No campaign seed was run
before this text was committed.

### Sampling (random over the whole space, boundary mass added on purpose)

Every draw is a mixture: one draw in five from a BOUNDARY set, two in five log-uniform, two in five uniform.

| variable | boundary set | log-uniform | uniform |
|---|---|---|---|
| stakers per sequence | none | none | 1..6 |
| deposit amount (wei) | 1, 2, 1e18-1, 1e18, MIN_EMISSION_WEIGHT-1, MIN_EMISSION_WEIGHT, MIN_EMISSION_WEIGHT+1, cap-1, cap, cap+1 | 1..30M BZPX | 1..30M BZPX |
| lock days | 90, 91, 2554, 2555, maxDaysNow-1, maxDaysNow, maxDaysNow+1, 0, 89 | 90..maxDaysNow | 90..maxDaysNow |
| time jump | 1 s; to the next 2-year turn -1/0/+1 s; to the close -1/0/+1 s; to a live unlock -1/0/+1 s; to the next year mark | 1 s..400 d | 1 h..60 d |
| funding amount (wei) | 0, 1, room-1, room, room+1 (room = 90M minus what was funded) | 1..room | 1..room |
| withdraw amount (wei) | 1, staked-1, staked, staked+1 | 1..staked | 1..staked |

The action at each step is drawn uniformly from: passTime (twice the weight of the others), deposit,
claimRewards by a staker, claimRewards by an address with no position (a bare settle), fundEmission,
withdraw, pokeExpiredLock. Every time jump is followed by a bare settle. One time jump in four is
first walked whole on a state snapshot, then in 2..5 equal pieces on the real state (EC-9).

One sequence in four is a SCHEDULE sequence: the full 90M is funded and one staker deposits at
least MIN_EMISSION_WEIGHT in the opening second, and the sequence then draws no withdraw and no
pokeExpiredLock, so no window runs empty, damped or short of reserve. Every sequence ends with a
jump past the close (if it is not there yet), one settle and the sweep of the undistributed
reserve.

### Invariants, tolerances and failure criteria (fixed before the first run)

The oracle is the schedule written from literals in the test file; the contract's constants are
never read to build an expectation. Every invariant is asserted after EVERY action of every
sequence, reverted actions included. One false assertion anywhere makes the test red and is
reported with its `(k, j, i)`; nothing is filtered.

| name | statement | tolerance |
|---|---|---|
| EC-1 | `emittedAt(now)` equals the literal schedule (floored base rate times elapsed seconds, plus the bonus of every closed period, plus the floored bonus rate of the open period times its elapsed seconds; 90M from the close on) and `currentRewardPerSec()` equals the literal rate (0 from the close on) | 0 |
| EC-2 | `emittedAt(now)` is never above the exact rational line, and never further under it than the two floored rates can leave it: 197,376,000 wei (base) + 31,808,000 wei (last bonus period) | above: 2 wei (the floors of the reference line itself); under: 229,184,000 wei |
| EC-3 | one settle moves `accRewardPerShare` by exactly `release * 1e18 / weight`, where `release` is the schedule's window since the last settle, scaled by `weight / MIN_EMISSION_WEIGHT` below the mark, capped by the reserve, and zero while the weight is zero | 0 |
| EC-4 | `lastRewardTime` is where the shadow keeps it: it moves to now on every settle with zero weight, with a zero release, or with a release, and stays put once it is past the close | 0 |
| EC-5 | `totalRewardDistributed <= schedule(now)`, `totalRewardDistributed <= sum of the expected releases`, and `sum of the expected releases <= schedule(now)` | 0 |
| EC-6 | `totalRewardDistributed + rewardReserve == funded` until the sweep | 0 |
| EC-7 | the sum of `pendingRewards` over every staker is at most the tokens the contract holds outside stake and reserve | 0; the gap is reported |
| EC-8 | a quote read in a block equals what `claimRewards` pays that staker in that block (whenever the claim leaves `totalStaked` unchanged) | 0 |
| EC-9 | a window settled in `k` pieces releases no more than the window settled once, less by under `k` wei, and exactly the same when the weight is at or above MIN_EMISSION_WEIGHT. Compared only when no lock was normalised inside the window on either path (the total weight is unchanged on both) | under `k` wei, one way |
| EC-10 | at the close the expected releases never exceed 90M; a SCHEDULE sequence is clean and has released 90,000,000e18 exactly; the sweep moves exactly the reserve to the treasury and leaves none | 0 |

Reported per batch: sequences, actions, reverted actions, settles with a release, split comparisons,
clean full closes; and the maximisers, each with its `(j, i)`: the EC-7 gap, the EC-2 deficit under
the line, the EC-9 split loss.

<!-- RESULTS -->
## Results

### The first run, as it happened

The first run on the campaign seeds did not complete, and the cause was the test file, not the
contract.

- Batch 0 stopped at sequence 1 with an arithmetic panic inside the EC-9 bookkeeping of the test:
  the harness computed `reserve before - reserve after` for the whole-window path BEFORE testing
  that the window was comparable. In that window a settle normalised a lapsed lock, which hands
  the boost it did not earn back to `rewardReserve`, so the reserve stood above its value before
  the window and the subtraction underflowed. The other 23 sequences of batch 0, replayed one by
  one on the unchanged harness, passed.
- Batches 1 to 3 were terminated by the runner's memory ceiling: the state snapshots taken for
  EC-9 were never released.

Two lines of the harness changed, and nothing else: the EC-9 subtraction is now made only after
the comparability test that the pre-registration already states, and each snapshot is deleted when
it is reverted to. No seed, no sampling rule, no invariant and no tolerance was touched. One check
was added, and it is stricter than what was registered: on a comparable window (total weight
unchanged) a reserve that GROWS is a failure.

### The campaign (seeds from `385b297`, batches 0..3, 24 sequences, 160 actions)

Pre-registered failures: **0**.

| batch | sequences | calls observed | reverted | settles with a release | split comparisons | clean full closes |
|---|---|---|---|---|---|---|
| 0 | 24 | 4,377 | 1,414 | 332 | 188 | 5 |
| 1 | 24 | 4,480 | 1,346 | 335 | 223 | 9 |
| 2 | 24 | 4,334 | 1,461 | 312 | 187 | 6 |
| 3 | 24 | 4,368 | 1,332 | 327 | 199 | 6 |
| all | 96 | 17,559 | 5,553 | 1,306 | 797 | 26 |

Every one of the 26 clean full closes released 90,000,000e18 exactly (EC-10).

### Maximisers (wei; replay with `ECW_BATCH=k ECW_SEQ=j`)

| batch | EC-7 gap at `(j, i)` | EC-2 deficit under the line at `(j, i)` | EC-9 split loss at `(j, i)` |
|---|---|---|---|
| 0 | 1,100,103,642 at (19, 77) | 229,183,998 at (1, 23) | 2 at (11, 30) |
| 1 | 1,681,405,174,094,090,999,081,348 at (13, 161) | 229,183,998 at (1, 9) | 2 at (6, 58) |
| 2 | 2,484,866,005,016,137,688 at (1, 62) | 229,183,998 at (0, 47) | 3 at (1, 10) |
| 3 | 1,266,300,931 at (17, 89) | 229,183,998 at (0, 32) | 0 |

- **EC-2.** The deficit reaches 229,183,998 wei in every batch, 2 wei inside the registered
  bound of 229,184,000: the bound is the sum of the two floored rates' remainders and the walk
  gets within one second of it.
- **EC-9.** A window settled in pieces lost at most 3 wei against the window settled once, with
  at most 5 pieces.
- **EC-7.** The largest gap, 1,681,405.17 BZPX at `(1, 13, 161)`, is the forced close of a
  sequence in which one lock lapsed and was never touched again. It is replayed and taken apart
  in `test/montecarlo/EmissionCurveGap.t.sol`: the gap is the boost that lock stopped earning at
  its `unlockTime`, still booked as distributed because the position was not touched, and quoted
  to nobody. One call to `pokeExpiredLock` by any address pays the position exactly its quote
  and moves 1,681,405,174,094,088,484,754,067 wei back to `rewardReserve`, where a second treasury
  sweep takes it; 2,514,327,281 wei stay unassigned. The gaps of the other three batches were
  not taken apart.
