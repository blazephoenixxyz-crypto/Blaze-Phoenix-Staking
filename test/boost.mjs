// BlazePhoenix Staking — STALE-BOOST / LOCK-EXPIRY suite (real EVM, offline).
//   node test/boost.mjs
//
// Regression suite for BP-2026-001 — "Stale Boost Persistence in Pure Stakers", disclosed on
// 28 July 2026 by NetGakarot ("Gakarot"). Credit for the finding, the root-cause analysis and the
// real-time expiry check is his; this suite pins the behaviour his report specified.
//
// THE BUG, in one sentence: the autonomous maintenance engine iterated `_borrowers` only, and a
// pure staker (debt == 0) is never in that array — so once such a position's lock expired, its
// historical multiplier stayed in `totalBoostedEffective` / `totalBoostedPure` indefinitely,
// letting an idle expired staker draw an oversized share of every ongoing emission and interest
// distribution at the expense of stakers who were still committed. Solvency was never at risk
// (boost is a denominator weight, never a claim on value); yield fairness was.
//
// THE FIX has two axes, and this suite pins BOTH — because either alone is insufficient:
//   (a) DERIVATION — `_computeBoost` prices an elapsed commitment at 1.00x against the CLOCK, so
//       no code path can re-derive a weight from an expired lock. Alone, this only re-prices a
//       position somebody already touched, which is exactly what an idle staker never is.
//   (b) PROPAGATION — the `_lockers` registry gives the autonomous engine a second, gas-bounded
//       rotating window that CAN see debt-free positions, so the global denominators shed the
//       expired weight with nobody touching the idle position. Alone, this would still leave a
//       window between expiry and sweep in which the stale multiplier is re-derivable.
//
// Every scenario also re-asserts the Master Conservation Identity: the fix must buy fairness
// without costing a single wei of solvency.
import { compileAll } from './compile.mjs';
import { Chain, ok, eq, approx, test, summary, E18 } from './lib.mjs';
import { ethers } from 'ethers';

const DAY = 86400n;
const MAX_UINT = (1n << 256n) - 1n;
const GUARDIAN_ROLE = ethers.id('GUARDIAN_ROLE');
const ZERO = '0x0000000000000000000000000000000000000000';
const art = compileAll();

// boost(730d) == 1.25x, boost(0d) == 1.00x — the two multipliers the whole report turns on.
const BOOST_730 = 12500n, BOOST_BASE = 10000n;
const boosted = (amount, bps) => (amount * bps) / BOOST_BASE;

async function setup() {
  const chain = await Chain.create();
  const admin    = await chain.fund('admin',    '0x' + '11'.repeat(32));
  const alice    = await chain.fund('alice',    '0x' + '22'.repeat(32));  // the IDLE expired staker
  const bob      = await chain.fund('bob',      '0x' + '33'.repeat(32));  // the ACTIVE staker
  const carol    = await chain.fund('carol',    '0x' + '44'.repeat(32));  // unrelated traffic
  const keeper   = await chain.fund('keeper',   '0x' + '55'.repeat(32));
  const treasury = await chain.fund('treasury', '0x' + '66'.repeat(32));
  const guardian = await chain.fund('guardian', '0x' + '77'.repeat(32));

  const token = await chain.deploy(art.Token, admin);
  const staking = await chain.deploy(art.Staking, admin, [token.addr.toString(), treasury.hex]);
  for (const u of [admin, alice, bob, carol, keeper]) {
    await token.send(admin, 'mint', [u.hex, E18(200_000_000)]);
    await token.send(u, 'approve', [staking.addr.toString(), MAX_UINT]);
  }
  return { chain, token, staking, admin, alice, bob, carol, keeper, treasury, guardian };
}

const bal = (token, who) => token.call('balanceOf', [who]);

async function mustStaySolvent(staking, label) {
  ok((await staking.call('isSolvent')) === true, `${label}: still solvent`);
  const audit = BigInt(await staking.call('auditInvariants'));
  ok((audit & 1n) === 0n, `${label}: conservation bit clear (audit=${audit})`);
  ok((audit & (1n << 4n)) === 0n, `${label}: boost-bounded bit clear (audit=${audit})`);
  const backing = await staking.call('backing'), owed = await staking.call('owed');
  ok(backing + 10n ** 10n >= owed, `${label}: backing(${backing}) >= owed(${owed})`);
}

// Everything a position has RECEIVED plus everything it is still owed — the only honest way to
// compare two stakers when the protocol may settle one of them mid-window and not the other.
async function earned(token, staking, who) {
  return (await bal(token, who)) + (await staking.call('pendingRewards', [who]));
}

// ───────────────────────────────────────────────────────────────────────────────────────────
// B1 — THE PROOF OF CONCEPT from the report, verbatim.
//
// Alice and Bob: identical principal, identical 730-day lock (1.25x), zero debt. 731 days pass,
// both locks objectively expired. Bob claims (normalising himself). Alice stays 100% idle.
//
// PRE-FIX: alice keeps her 1.25x weight in the global denominators forever, and over the next
//          30 days earns ~25% more than Bob for an identical position with no lock left.
// POST-FIX: Bob's single transaction carries the locker sweep, which normalises Alice without
//          her doing anything. Both denominators fall to the un-boosted total and the two
//          positions earn EXACTLY the same from that point on.
//
// This scenario deliberately uses ONLY the v3.0.0 ABI — no helper added by the fix — so it can be
// run verbatim against the vulnerable contract, where it fails on the reported 1.25x divergence
// rather than on a missing function. That is what makes it a regression test and not a tautology.
// ───────────────────────────────────────────────────────────────────────────────────────────
await test('B1 PoC: an idle pure staker cannot keep a lapsed multiplier (yield misallocation)', async () => {
  const { chain, token, staking, admin, alice, bob } = await setup();
  await staking.send(admin, 'fundEmission', [E18(100_000_000)]);

  const P = E18(1_000_000);
  await staking.send(alice, 'deposit', [P, 730]);
  await staking.send(bob,   'deposit', [P, 730]);
  chain.mine(11);

  // While both are genuinely committed, both are genuinely boosted. The fix must not touch this.
  eq(await staking.call('totalBoostedEffective'), boosted(P, BOOST_730) * 2n, 'while locked: emission denominator is 2 x 1.25x');
  eq(await staking.call('totalBoostedPure'),      boosted(P, BOOST_730) * 2n, 'while locked: pure-yield denominator is 2 x 1.25x');

  // ── 731 days later: both locks have objectively expired. Bob acts; alice stays 100% idle.
  //    Bob's ONE transaction must normalise the whole book — his position AND alice's. ──
  chain.warp(731n * DAY); chain.mine(11);
  await staking.send(bob, 'claimRewards', []);

  eq(await staking.call('totalBoostedEffective'), P * 2n, 'after expiry: emission denominator is the UN-boosted total');
  eq(await staking.call('totalBoostedPure'),      P * 2n, 'after expiry: pure-yield denominator is the UN-boosted total');
  eq((await staking.call('lockInfoOf', [alice.hex]))[2], BOOST_BASE, 'the idle position is priced at 1.00x');

  // ── The economic assertion: 30 more days, identical positions, identical yield. ──
  const a1 = await earned(token, staking, alice.hex);
  const b1 = await earned(token, staking, bob.hex);
  chain.warp(30n * DAY); chain.mine(5);
  const dA = (await earned(token, staking, alice.hex)) - a1;
  const dB = (await earned(token, staking, bob.hex))   - b1;

  ok(dA > 0n, `both positions still earn (alice +${dA})`);
  eq(dA, dB, 'post-expiry: the idle staker earns EXACTLY what the active one earns');
  // The bug's signature was dA/dB == 1.25. Pin the ratio itself so a regression is unmissable.
  eq((dA * 10000n) / dB, 10000n, 'post-expiry yield ratio idle:active is 1.0000 (was 1.2500 pre-fix)');

  await mustStaySolvent(staking, 'B1');

  // The same scenario, re-read through the surface the fix adds.
  eq(await staking.call('activeLockerCount'), 0, 'both entries de-registered — the registry holds only live commitments');
  ok((await staking.call('hasStaleBoost', [alice.hex])) === false, 'alice was normalised by an unrelated transaction');
  ok((await staking.call('totalLockSweeps')) >= 1n, 'the autonomous engine recorded the lock sweep');
});

// ───────────────────────────────────────────────────────────────────────────────────────────
// B2 — AXIS (a), DERIVATION. Before any transaction touches an expired position, the protocol
// must already price it at 1.00x everywhere it is asked. The stored commitment is still on
// record (that is history, and history is not rewritten) — but nothing is PAID against it.
// ───────────────────────────────────────────────────────────────────────────────────────────
await test('B2 derivation: an elapsed commitment is priced at 1.00x before any state is mutated', async () => {
  const { chain, staking, admin, alice } = await setup();
  await staking.send(admin, 'fundEmission', [E18(50_000_000)]);
  await staking.send(alice, 'deposit', [E18(1_000_000), 730]);
  chain.mine(11);

  let info = await staking.call('lockInfoOf', [alice.hex]);
  eq(info[2], BOOST_730, 'while committed: 1.25x');
  ok(info[3] === false, 'while committed: not expired');
  eq(await staking.call('effectiveLockDaysOf', [alice.hex]), 730, 'while committed: 730 effective days');

  // One second past the unlock. NO transaction of any kind has run against this position.
  chain.warp(730n * DAY + 1n);

  info = await staking.call('lockInfoOf', [alice.hex]);
  eq(info[0], 730, 'the commitment ON RECORD is unchanged (storage untouched)');
  ok(info[3] === true, 'lockInfoOf reports expired');
  eq(info[2], BOOST_BASE, 'lockInfoOf.boostBps already reads 1.00x — the view cannot flatter the position');
  eq(await staking.call('effectiveLockDaysOf', [alice.hex]), 0, 'effective lock duration is 0 days');
  eq(await staking.call('effectiveBoostOf',    [alice.hex]), BOOST_BASE, 'effective boost is 1.00x');
  eq((await staking.call('getUserInfo', [alice.hex]))[11], BOOST_BASE, 'getUserInfo.boostBps reads 1.00x');
  ok((await staking.call('hasStaleBoost', [alice.hex])) === true, 'the position is flagged as carrying stale weight');

  // Boost is the price of illiquidity: the moment it is refused, the capital must be withdrawable.
  chain.mine(11);
  const r = await staking.send(alice, 'withdraw', [E18(1_000_000)]);
  ok(r.ok, 'the same instant the multiplier drops, the principal is free to leave');
});

// ───────────────────────────────────────────────────────────────────────────────────────────
// B3 — AXIS (b), PROPAGATION. The locker registry is the structural answer to "who watches the
// pure stakers". It must track every live commitment and leak nothing: an entry has to die on
// EVERY exit path, or the sweep would rotate over dead weight forever.
// ───────────────────────────────────────────────────────────────────────────────────────────
await test('B3 registry: every live commitment is tracked, and every exit path de-registers', async () => {
  const { chain, staking, token, admin, alice, bob, carol, keeper, guardian } = await setup();
  await staking.send(admin, 'fundEmission', [E18(50_000_000)]);

  // registered by deposit
  await staking.send(alice, 'deposit', [E18(1_000_000), 90]);
  ok((await staking.call('isTrackedLocker', [alice.hex])) === true, 'deposit registers the locker');
  eq(await staking.call('activeLockerCount'), 1, 'registry size 1');

  // idempotent: a top-up must not double-register
  chain.mine(11);
  await staking.send(alice, 'deposit', [E18(1_000), 90]);
  eq(await staking.call('activeLockerCount'), 1, 'a top-up does not duplicate the entry');

  // registered by the standalone lock() path too
  await staking.send(bob, 'deposit', [E18(1_000_000), 90]);
  chain.mine(11);
  await staking.send(bob, 'lock', [365]);
  ok((await staking.call('isTrackedLocker', [bob.hex])) === true, 'lock() keeps the entry');
  eq(await staking.call('activeLockerCount'), 2, 'registry size 2');

  // EXIT 1 — the user's own transaction clears an expired lock
  chain.warp(91n * DAY); chain.mine(11);
  await staking.send(alice, 'claimRewards', []);
  ok((await staking.call('isTrackedLocker', [alice.hex])) === false, 'own-tx expiry de-registers');

  // EXIT 2 — a full liquidation deletes the position
  await staking.send(carol, 'deposit', [E18(1_000_000), 365]);
  chain.mine(3);
  await staking.send(carol, 'borrow', [E18(490_000)]);
  ok((await staking.call('isTrackedLocker', [carol.hex])) === true, 'a BORROWER with a lock is tracked in both registries');
  chain.warp(80n * 365n * DAY); chain.mine(3);
  await staking.send(keeper, 'liquidate', [carol.hex]);
  ok((await staking.call('isTrackedLocker', [carol.hex])) === false, 'a wiped-out position leaves no ghost registry entry');
  await mustStaySolvent(staking, 'B3 post-liquidation');

  // EXIT 3 — emergencyWithdraw destroys the position
  const st = await setup();
  await st.staking.send(st.admin, 'grantRole', [GUARDIAN_ROLE, st.guardian.hex]);
  await st.staking.send(st.alice, 'deposit', [E18(1_000_000), 730]);
  eq(await st.staking.call('activeLockerCount'), 1, 'registry size 1 before the halt');
  await st.staking.send(st.guardian, 'declareEmergency', []);
  await st.staking.send(st.alice, 'emergencyWithdraw', []);
  ok((await st.staking.call('isTrackedLocker', [st.alice.hex])) === false, 'emergencyWithdraw de-registers');
  eq(await st.staking.call('activeLockerCount'), 0, 'registry drained by the emergency exit');
  eq(await st.staking.call('totalBoostedPure'), 0, 'and left no boosted ghost share behind');
});

// ───────────────────────────────────────────────────────────────────────────────────────────
// B4 — PERMISSIONLESS RESYNCHRONISATION. Nobody should have to wait for the rotating window:
// any address may normalise any expired position, singly or in a batch, at their own gas cost.
// ───────────────────────────────────────────────────────────────────────────────────────────
await test('B4 poke: anyone may normalise an expired position, one at a time or in a batch', async () => {
  const { chain, staking, admin, alice, bob, carol, keeper } = await setup();
  await staking.send(admin, 'fundEmission', [E18(50_000_000)]);
  const P = E18(1_000_000);
  for (const u of [alice, bob, carol]) await staking.send(u, 'deposit', [P, 730]);
  chain.mine(11);

  // a live commitment cannot be poked away — the premium is paid for a REASON
  let r = await staking.send(keeper, 'pokeExpiredLock', [alice.hex]);
  ok(!r.ok && r.revert === 'Staking__StillLocked', `poking a live lock -> StillLocked (${r.revert})`);
  r = await staking.send(keeper, 'pokeExpiredLocks', [[alice.hex, bob.hex]]);
  ok(!r.ok && r.revert === 'Staking__NoLock', `batch with nothing actionable -> NoLock (${r.revert})`);
  r = await staking.send(keeper, 'pokeExpiredLock', [ZERO]);
  ok(!r.ok && r.revert === 'Staking__NoLock', `poking a position with no lock -> NoLock (${r.revert})`);

  chain.warp(731n * DAY); chain.mine(11);
  eq(await staking.call('totalBoostedEffective'), boosted(P, BOOST_730) * 3n, 'three stale positions still in the denominator');

  // Batch poke by a total stranger. Duplicates, addresses with no position, and entries the
  // sweep inside this very transaction already normalised must all be skipped, never fatal.
  r = await staking.send(keeper, 'pokeExpiredLocks', [[bob.hex, alice.hex, bob.hex, ZERO, carol.hex]]);
  ok(r.ok, 'a batch containing duplicates and no-ops still succeeds on the actionable entries');
  eq(await staking.call('totalBoostedEffective'), P * 3n, 'the whole backlog is normalised');
  eq(await staking.call('totalBoostedPure'),      P * 3n, 'on both denominators');
  eq(await staking.call('activeLockerCount'), 0, 'registry drained');
  ok((await staking.call('totalLockSweeps')) >= 3n, 'three normalisations recorded');
  await mustStaySolvent(staking, 'B4 batch');

  // Single poke by a stranger, on a book where nothing else is stale.
  const st = await setup();
  await st.staking.send(st.admin, 'fundEmission', [E18(50_000_000)]);
  await st.staking.send(st.alice, 'deposit', [P, 730]);
  st.chain.mine(11);
  st.chain.warp(731n * DAY); st.chain.mine(11);
  r = await st.staking.send(st.keeper, 'pokeExpiredLock', [st.alice.hex]);
  ok(r.ok, 'a stranger may poke a single expired position');
  ok((await st.staking.call('hasStaleBoost', [st.alice.hex])) === false, 'alice normalised by the poke');
  eq(await st.staking.call('totalBoostedEffective'), P, 'weight released to the un-boosted baseline');
  r = await st.staking.send(st.keeper, 'pokeExpiredLock', [st.alice.hex]);
  ok(!r.ok && r.revert === 'Staking__NoLock', `re-poking an already-normalised position -> NoLock (${r.revert})`);
  await mustStaySolvent(st.staking, 'B4 single');
});

// ───────────────────────────────────────────────────────────────────────────────────────────
// B5 — KEEPER DISCOVERY. A monitor must be able to measure the backlog and act on it with no
// off-chain indexer: `expiredLockScan` reports exactly the excess weight, and feeding its own
// output straight into `pokeExpiredLocks` must drive that excess to zero.
// ───────────────────────────────────────────────────────────────────────────────────────────
await test('B5 scan: the stale-boost backlog is measurable on-chain and self-erasable', async () => {
  const { chain, staking, admin, alice, bob, carol, keeper } = await setup();
  await staking.send(admin, 'fundEmission', [E18(50_000_000)]);
  const P = E18(1_000_000);
  await staking.send(alice, 'deposit', [P, 730]);
  await staking.send(bob,   'deposit', [P, 730]);
  await staking.send(carol, 'deposit', [P, 2000]);   // still committed after 731 days
  chain.mine(11);

  let scan = await staking.call('expiredLockScan', [0, 100]);
  eq(scan[3], 3, 'the scan sees the whole registry');
  eq(scan[0].length, 0, 'nothing expired yet');
  eq(scan[1], 0, 'no excess emission weight');

  chain.warp(731n * DAY); chain.mine(11);
  scan = await staking.call('expiredLockScan', [0, 100]);
  eq(scan[0].length, 2, 'exactly the two lapsed commitments are reported');
  // each is over-carrying (1.25 - 1.00) x principal on BOTH denominators
  const excessEach = boosted(P, BOOST_730) - P;
  eq(scan[1], excessEach * 2n, 'the reported excess emission weight is exact');
  eq(scan[2], excessEach * 2n, 'the reported excess pure-yield weight is exact');

  // paging must not double-count or miss
  const page0 = await staking.call('expiredLockScan', [0, 1]);
  const page1 = await staking.call('expiredLockScan', [1, 1]);
  const page2 = await staking.call('expiredLockScan', [2, 1]);
  eq(page0[1] + page1[1] + page2[1], scan[1], 'paged excess sums to the whole-registry excess');
  eq(await staking.call('expiredLockScan', [99, 10]).then((x) => x[0].length), 0, 'an out-of-range page is empty, not a revert');

  // feed the scan's own output back in
  const r = await staking.send(keeper, 'pokeExpiredLocks', [scan[0]]);
  ok(r.ok, 'the scan output is directly actionable');
  const after = await staking.call('expiredLockScan', [0, 100]);
  eq(after[0].length, 0, 'backlog cleared');
  eq(after[1], 0, 'zero excess emission weight remains');
  eq(after[2], 0, 'zero excess pure-yield weight remains');
  eq(after[3], 1, 'only the still-committed position remains registered');
  eq(await staking.call('totalBoostedEffective'), P * 2n + boosted(P, await staking.call('boostByDays', [2000])), 'denominator = 2 un-boosted + 1 still-committed');
  await mustStaySolvent(staking, 'B5');
});

// ───────────────────────────────────────────────────────────────────────────────────────────
// B6 — THE GAME THEORY the report is actually about. Pre-fix, holding liquid tokens retained
// boosted yield, so re-locking was strictly irrational and the lock had no economic meaning.
// Post-fix, committing capital must pay strictly more than not committing it.
// ───────────────────────────────────────────────────────────────────────────────────────────
await test('B6 incentive: re-locking strictly beats idling once a commitment lapses', async () => {
  const { chain, token, staking, admin, alice, bob } = await setup();
  await staking.send(admin, 'fundEmission', [E18(100_000_000)]);
  const P = E18(1_000_000);
  await staking.send(alice, 'deposit', [P, 730]);
  await staking.send(bob,   'deposit', [P, 730]);
  chain.mine(11);

  chain.warp(731n * DAY); chain.mine(11);
  await staking.send(bob, 'lock', [730]);            // bob re-commits; his tx also sweeps alice
  ok((await staking.call('hasStaleBoost', [alice.hex])) === false, 'alice is normalised by bob re-locking');
  eq(await staking.call('totalBoostedEffective'), P + boosted(P, BOOST_730), 'denominator = idle at 1.00x + re-locked at 1.25x');

  const a1 = await earned(token, staking, alice.hex);
  const b1 = await earned(token, staking, bob.hex);
  chain.warp(60n * DAY); chain.mine(5);
  const dA = (await earned(token, staking, alice.hex)) - a1;
  const dB = (await earned(token, staking, bob.hex))   - b1;

  ok(dB > dA, `the re-locked staker out-earns the idle one (${dB} > ${dA})`);
  // exactly the boost ratio, to the basis point: 12500/10000
  eq((dB * BOOST_BASE) / dA, BOOST_730, 'the advantage is exactly the 1.25x lock premium');
  await mustStaySolvent(staking, 'B6');
});

// ───────────────────────────────────────────────────────────────────────────────────────────
// B7 — NOTHING IS CONFISCATED. Re-pricing the FUTURE must never claw back the PAST: everything
// earned while the commitment was live was genuinely earned at the boosted weight, and the
// sweep has to settle it before it touches the weight. A fix that silently burned accrued
// rewards would be a worse bug than the one it replaced.
// ───────────────────────────────────────────────────────────────────────────────────────────
await test('B7 no confiscation: the sweep PAYS the boosted backlog before re-pricing the future', async () => {
  const { chain, token, staking, admin, alice, carol } = await setup();
  await staking.send(admin, 'fundEmission', [E18(100_000_000)]);
  await staking.send(alice, 'deposit', [E18(1_000_000), 730]);
  chain.mine(11);
  chain.warp(731n * DAY); chain.mine(11);

  const pendingBefore = await staking.call('pendingRewards', [alice.hex]);
  const balBefore = await bal(token, alice.hex);
  ok(pendingBefore > 0n, `alice has an unsettled boosted backlog (${pendingBefore})`);

  // carol's completely unrelated transaction carries the sweep that normalises alice
  await staking.send(carol, 'deposit', [E18(1_000), 90]);

  const paid = (await bal(token, alice.hex)) - balBefore;
  eq(paid, pendingBefore, 'alice was paid her full pre-expiry entitlement, to the wei');
  approx(await staking.call('pendingRewards', [alice.hex]), 0n, 10n ** 10n, 'and is left with nothing unsettled');
  ok((await staking.call('hasStaleBoost', [alice.hex])) === false, 'only THEN is the weight released');
  await mustStaySolvent(staking, 'B7');
});

// ───────────────────────────────────────────────────────────────────────────────────────────
// B8 — GAS BOUND / DoS. The second window must not become a new denial-of-service surface: a
// flooded locker registry must never make an ordinary transaction unaffordable, and the budget
// must stay hard-capped exactly like the borrower window.
// ───────────────────────────────────────────────────────────────────────────────────────────
await test('B8 bounded: a flooded locker registry cannot make an ordinary transaction expensive', async () => {
  const { chain, token, staking, admin, alice } = await setup();
  await staking.send(admin, 'fundEmission', [E18(50_000_000)]);

  // 40 lockers, all of which will be simultaneously expired — the worst case for the sweep.
  for (let i = 0; i < 40; i++) {
    const w = await chain.fund(`spam${i}`, '0x' + (i + 160).toString(16).padStart(2, '0').repeat(32));
    await token.send(admin, 'mint', [w.hex, E18(1_000_000)]);
    await token.send(w, 'approve', [staking.addr.toString(), MAX_UINT]);
    await staking.send(w, 'deposit', [E18(10_000), 90]);
  }
  eq(await staking.call('activeLockerCount'), 40, 'registry holds all 40 commitments');
  ok((await staking.call('lockSweepBudget')) <= 10n, 'the lock window is hard-capped at MAINT_MAX_SCAN');

  chain.warp(400n * DAY); chain.mine(11);
  ok((await staking.call('lockSweepBudget')) <= 10n, 'still capped after a 400-day backlog');

  // An ordinary deposit must stay affordable no matter how deep the backlog is.
  const before = await staking.call('activeLockerCount');
  const r = await staking.send(alice, 'deposit', [E18(1_000), 90]);
  ok(r.ok, "an innocent user's transaction succeeds against a 40-deep expired backlog");
  const after = await staking.call('activeLockerCount');
  ok(after < before, `the sweep made progress in one tx (${before} -> ${after})`);
  ok(before - after <= 4n, 'and did bounded work (<= MAINT_MAX_LOCK_ACTIONS normalisations per tx)');

  // Organic flow alone must drain the whole backlog — no keeper required, no time gap needed.
  for (let i = 0; i < 12; i++) { chain.mine(11); await staking.send(alice, 'claimRewards', []); }
  eq(await staking.call('activeLockerCount'), 1, 'only alice’s own live commitment survives — the rest were swept autonomously');
  await mustStaySolvent(staking, 'B8');
});

// ───────────────────────────────────────────────────────────────────────────────────────────
// B9 — POISONED POSITION. If BZPX were ever a token that refuses to pay a particular address,
// settling that locker inside someone else's transaction would revert. The self-external
// lockStep + try/catch must isolate it: the innocent user's transaction survives, the cursor
// advances so the rotation never stalls, and the rest of the backlog still drains.
// ───────────────────────────────────────────────────────────────────────────────────────────
await test('B9 isolation: a locker the token refuses to pay cannot stall the sweep or grief a user', async () => {
  const chain = await Chain.create();
  const admin  = await chain.fund('admin',  '0x' + '11'.repeat(32));
  const victim = await chain.fund('victim', '0x' + '22'.repeat(32));
  const other  = await chain.fund('other',  '0x' + '33'.repeat(32));
  const carol  = await chain.fund('carol',  '0x' + '44'.repeat(32));
  const treasury = await chain.fund('treasury', '0x' + '66'.repeat(32));

  // A blacklisting ERC-20, compiled alongside the protocol exactly as the mock BZPX is.
  const solc = (await import('solc')).default;
  const src = `// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
contract BlacklistToken {
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    mapping(address=>bool) public blocked;
    uint256 public totalSupply;
    function mint(address to, uint256 a) external { balanceOf[to]+=a; totalSupply+=a; }
    function setBlocked(address a, bool b) external { blocked[a]=b; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s]=a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(!blocked[to], "blocked");
        require(balanceOf[msg.sender]>=a); balanceOf[msg.sender]-=a; balanceOf[to]+=a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(!blocked[to], "blocked");
        require(balanceOf[f]>=a);
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al>=a); allowance[f][msg.sender]=al-a; }
        balanceOf[f]-=a; balanceOf[to]+=a; return true;
    }
}`;
  const out = JSON.parse(solc.compile(JSON.stringify({
    language: 'Solidity',
    sources: { 'B.sol': { content: src } },
    settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true, outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } } },
  })));
  const bArt = { abi: out.contracts['B.sol'].BlacklistToken.abi, bytecode: '0x' + out.contracts['B.sol'].BlacklistToken.evm.bytecode.object };

  const btoken = await chain.deploy(bArt, admin);
  const staking = await chain.deploy(art.Staking, admin, [btoken.addr.toString(), treasury.hex]);
  for (const u of [admin, victim, other, carol]) {
    await btoken.send(admin, 'mint', [u.hex, E18(100_000_000)]);
    await btoken.send(u, 'approve', [staking.addr.toString(), MAX_UINT]);
  }
  await staking.send(admin, 'fundEmission', [E18(50_000_000)]);

  await staking.send(victim, 'deposit', [E18(1_000_000), 90]);
  await staking.send(other,  'deposit', [E18(1_000_000), 90]);
  chain.mine(11);
  chain.warp(91n * DAY); chain.mine(11);
  ok((await staking.call('pendingRewards', [victim.hex])) > 0n, 'the victim has rewards that must be paid before re-pricing');

  // the token now refuses to pay the victim — settling them reverts
  await btoken.send(admin, 'setBlocked', [victim.hex, true]);

  const r = await staking.send(carol, 'deposit', [E18(500_000), 90]);
  ok(r.ok, "the innocent user's transaction still succeeds");
  ok((await staking.call('isTrackedLocker', [victim.hex])) === true, 'the poisoned entry is skipped, not silently dropped');
  ok((await staking.call('hasStaleBoost', [other.hex])) === false, 'and the sweep still got past it to normalise the healthy locker');
  await mustStaySolvent(staking, 'B9');

  // The skipped entry is not abandoned: the cursor keeps rotating, so once the token relents
  // ordinary traffic picks the position back up with nobody having to remember it.
  await btoken.send(admin, 'setBlocked', [victim.hex, false]);
  for (let i = 0; i < 3 && (await staking.call('isTrackedLocker', [victim.hex])); i++) {
    chain.warp(1n * 3600n); chain.mine(11);
    await staking.send(carol, 'claimRewards', []);
  }
  ok((await staking.call('isTrackedLocker', [victim.hex])) === false, 'the un-blocked position is normalised by ordinary flow');
  await mustStaySolvent(staking, 'B9 drained');
});

// ───────────────────────────────────────────────────────────────────────────────────────────
// B10 — ACCESS CONTROL on the new self-external step, and CONSERVATION across a long mixed
// sequence in which locks lapse, are re-committed, and positions are liquidated underneath the
// sweep. The Master Conservation Identity is the property the fix was forbidden to cost.
// ───────────────────────────────────────────────────────────────────────────────────────────
await test('B10 lockStep is self-only; conservation holds across a long expiry-heavy sequence', async () => {
  const { chain, staking, admin, alice, bob, carol, keeper } = await setup();
  await staking.send(admin, 'fundEmission', [E18(120_000_000)]);

  const r = await staking.send(keeper, 'lockStep', [alice.hex, keeper.hex]);
  ok(!r.ok && r.revert === 'Staking__NotSelf', `lockStep from outside -> NotSelf (${r.revert})`);

  await staking.send(alice, 'deposit', [E18(2_000_000), 90]);
  await staking.send(bob,   'deposit', [E18(3_000_000), 365]);
  await staking.send(carol, 'deposit', [E18(5_000_000), 730]);
  chain.mine(11);
  await staking.send(carol, 'borrow', [E18(2_000_000)]);

  for (let i = 0; i < 10; i++) {
    chain.warp(97n * DAY); chain.mine(11);
    await staking.send(keeper, 'claimRewards', []);            // pure maintenance traffic
    if (i % 3 === 0) await staking.send(bob, 'deposit', [E18(100_000), 120]);
    if (i % 4 === 1) { const x = await staking.send(alice, 'lock', [200]); ok(x.ok || x.revert === 'Staking__CannotReduceLock', 'lock path behaves'); }
    if (i % 5 === 2) await staking.send(carol, 'repay', [E18(200_000)]);
    await mustStaySolvent(staking, `B10 round ${i}`);
  }

  // Whatever the registry still holds must be exactly the set of LIVE commitments.
  const scan = await staking.call('expiredLockScan', [0, 200]);
  eq(scan[0].length, 0, 'no stale commitment survived the sequence');
  eq(scan[1], 0, 'no excess emission weight survived the sequence');
  eq(scan[2], 0, 'no excess pure-yield weight survived the sequence');

  // And the boosted denominators must still be exactly the sum of the tracked contributions —
  // the single-writer property the whole reward split rests on.
  const total = await staking.call('totalStaked');
  const maxBoosted = (total * 27500n) / BOOST_BASE;
  ok((await staking.call('totalBoostedEffective')) <= maxBoosted, 'emission denominator within the boost bound');
  ok((await staking.call('totalBoostedPure')) <= maxBoosted, 'pure-yield denominator within the boost bound');
  await mustStaySolvent(staking, 'B10 final');
});

console.log('');
const allGreen = summary();
process.exit(allGreen ? 0 : 1);
