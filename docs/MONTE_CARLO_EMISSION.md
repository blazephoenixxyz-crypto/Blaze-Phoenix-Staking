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

Not run yet.
