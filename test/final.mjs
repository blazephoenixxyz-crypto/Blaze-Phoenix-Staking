// ════════════════════════════════════════════════════════════════════════════════════════
//  BlazePhoenix Staking — time-axis regression suite
//
//    node test/final.mjs
//
//  Conservation invariants bound how much value exists; they say nothing about WHEN it was
//  earned or WHO was present while it accrued. This suite covers that second axis. Each
//  property below is a relation that must hold between two executions, so it needs no
//  hard-coded expected value to compare against.
//
//  Layers:
//    1. randomised stateful campaign — reproducible from its seed, invariants after every tx
//    2. paired-execution relations   — one property per time-dependent accumulator
//    3. scaling study                — separates rounding dust from a real leak by exponent
// ════════════════════════════════════════════════════════════════════════════════════════
import { compileAll } from './compile.mjs';
import { Chain, E18 } from './lib.mjs';
import { ethers } from 'ethers';

const DAY = 86400n, YEAR = 365n * DAY;
const MAX_UINT = (1n << 256n) - 1n;
const WAD = 10n ** 18n;
const REWARD_PER_SEC = (180_000_000n * WAD) / (7n * 365n * DAY);
const DUST = 10n ** 10n;

const art = compileAll();

// ── reproducible PRNG (mulberry32) — every campaign is replayable from its seed ──────────
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const pick = (r, arr) => arr[Math.floor(r() * arr.length)];
const between = (r, lo, hi) => lo + BigInt(Math.floor(r() * Number(hi - lo)));

// ── result accounting ────────────────────────────────────────────────────────────────────
let PASS = 0, FAIL = 0;
const FINDINGS = [];
function check(cond, label, detail = '') {
  if (cond) { PASS++; console.log(`  ✓ ${label}`); }
  else { FAIL++; FINDINGS.push({ label, detail }); console.log(`  ✗ ${label}${detail ? '  ::  ' + detail : ''}`); }
  return cond;
}
const fmt = (x, d = 18) => {
  const neg = x < 0n; if (neg) x = -x;
  const s = x.toString().padStart(d + 1, '0');
  return (neg ? '-' : '') + s.slice(0, -d) + '.' + s.slice(-d).slice(0, 6);
};

// ── world ────────────────────────────────────────────────────────────────────────────────
async function world({ fundAll = true, actors = 6 } = {}) {
  const chain = await Chain.create();
  const admin    = await chain.fund('admin',    '0x' + '11'.repeat(32));
  const treasury = await chain.fund('treasury', '0x' + '66'.repeat(32));
  const guardian = await chain.fund('guardian', '0x' + '77'.repeat(32));
  const users = [];
  for (let i = 0; i < actors; i++) {
    users.push(await chain.fund('u' + i, '0x' + (20 + i).toString(16).padStart(2, '0').repeat(32)));
  }
  const token = await chain.deploy(art.Token, admin);
  const staking = await chain.deploy(art.Staking, admin, [token.addr.toString(), treasury.hex]);
  const S = staking.addr.toString();
  for (const u of [admin, ...users]) {
    await token.send(admin, 'mint', [u.hex, E18(500_000_000)]);
    await token.send(u, 'approve', [S, MAX_UINT]);
  }
  await staking.send(admin, 'grantRole', [ethers.id('GUARDIAN_ROLE'), guardian.hex]);
  if (fundAll) await staking.send(admin, 'fundEmission', [E18(180_000_000)]);
  const t0 = chain.time;
  return { chain, token, staking, admin, treasury, guardian, users, t0 };
}

// ── the invariant monitor: every metric below is an EQUATION, not a heuristic ────────────
async function probe(w) {
  const { staking, chain, t0 } = w;
  const [owed, backing, rewardReserve, funded, tStaked, tDebt, tBE, tBP, badDebt, protoRes] =
    await Promise.all([
      staking.call('owed'), staking.call('backing'), staking.call('rewardReserve'),
      staking.call('totalEmissionFunded'), staking.call('totalStaked'), staking.call('totalDebt'),
      staking.call('totalBoostedEffective'), staking.call('totalBoostedPure'),
      staking.call('totalBadDebt'), staking.call('protocolReserve'),
    ]);

  // I1 — Master Conservation Identity (the contract's own guard, one-sided)
  const solvencyResidual = BigInt(owed) - BigInt(backing);   // >0 ⇒ breach

  // I2 — Emission closure.  Ideal linear schedule vs what the accumulator actually released.
  //      stranded = REWARD_PER_SEC·Δt  −  (funded − remaining)
  const elapsed = chain.time - t0;
  const idealEmitted = REWARD_PER_SEC * elapsed;
  const actualEmitted = BigInt(funded) - BigInt(rewardReserve);
  const stranded = idealEmitted - actualEmitted;

  // I3 — Boost weight closure.  Σ over known actors of the weight DERIVED from live state,
  //      against the TRACKED global total. Any gap is stale weight sitting in a denominator.
  let derivedBE = 0n, derivedBP = 0n;
  for (const u of w.users) {
    const info = await staking.call('getUserInfo', [u.hex]);
    const staked = BigInt(info[0]), debt = BigInt(info[1]), boost = BigInt(info[11]);
    const eff = staked > debt ? staked - debt : 0n;
    derivedBE += (eff * boost) / 10_000n;
    derivedBP += (debt === 0n && staked > 0n) ? (staked * boost) / 10_000n : 0n;
  }
  const staleBE = BigInt(tBE) - derivedBE;
  const staleBP = BigInt(tBP) - derivedBP;

  const audit = BigInt(await staking.call('auditInvariants'));

  return {
    owed: BigInt(owed), backing: BigInt(backing), solvencyResidual, stranded,
    idealEmitted, actualEmitted, staleBE, staleBP, audit,
    totalStaked: BigInt(tStaked), totalDebt: BigInt(tDebt),
    tBE: BigInt(tBE), tBP: BigInt(tBP), badDebt: BigInt(badDebt), protocolReserve: BigInt(protoRes),
  };
}

// ════════════════════════════════════════════════════════════════════════════════════════
//  LAYER 1 — STATEFUL RANDOMISED CAMPAIGN
//  Random actor × random action × random Δt. Invariants evaluated after EVERY step.
//  Reverts are legal outcomes and are recorded, not treated as failures: the point is that
//  no reachable state may violate an invariant.
// ════════════════════════════════════════════════════════════════════════════════════════
async function fuzzCampaign(seed, steps, { capScale = 1n, timeScale = 1n } = {}) {
  const r = rng(seed);
  const w = await world();
  const { staking, chain, users } = w;

  const stat = {
    seed, steps, actions: {}, reverts: {},
    maxSolvencyResidual: -(2n ** 200n), maxStranded: 0n, maxStaleBE: 0n, maxStaleBP: 0n,
    auditViolations: 0n, txOk: 0, txRevert: 0,
  };
  const bump = (m, k) => { m[k] = (m[k] || 0) + 1; };

  for (let s = 0; s < steps; s++) {
    const u = pick(r, users);
    const act = pick(r, [
      'deposit', 'deposit', 'deposit', 'borrow', 'borrow', 'repay', 'withdraw',
      'claimRewards', 'claimPureYield', 'lock', 'liquidate', 'poke', 'idle',
    ]);
    bump(stat.actions, act);

    // random time advance, log-uniform with a heavy tail on purpose: the defects this suite
    // looks for scale with Δt, so the sampler has to reach long gaps. decade <= 5 puts the
    // maximum at 10^5 x 60 s, about 69 days.
    const decade = Math.floor(r() * 6);
    const dt = BigInt(Math.max(1, Math.floor(r() * Math.pow(10, decade) * 60))) * timeScale;
    chain.warp(dt);
    chain.mine(1 + Math.floor(r() * 12));

    let res = { ok: true };
    try {
      const info = await staking.call('getUserInfo', [u.hex]);
      const staked = BigInt(info[0]), debt = BigInt(info[1]), maxBorrow = BigInt(info[3]);
      const maxDays = BigInt(info[13]);

      if (act === 'deposit') {
        const maxDep = BigInt(info[12]);                     // remainingCap
        if (maxDep > E18(10)) {
          const amt = between(r, E18(1), (maxDep > E18(20_000_000) ? E18(20_000_000) : maxDep)) * capScale;
          const d = maxDays >= 90n ? between(r, 90n, maxDays > 2555n ? 2556n : maxDays + 1n) : 0n;
          if (d >= 90n && amt > 0n) res = await staking.send(u, 'deposit', [amt, d]);
        }
      } else if (act === 'borrow') {
        if (maxBorrow > E18(1)) res = await staking.send(u, 'borrow', [between(r, E18(1), maxBorrow)]);
      } else if (act === 'repay') {
        if (debt > 0n) res = await staking.send(u, 'repay', [between(r, 1n, debt + 1n)]);
      } else if (act === 'withdraw') {
        if (staked > 0n && debt === 0n) res = await staking.send(u, 'withdraw', [between(r, 1n, staked + 1n)]);
      } else if (act === 'claimRewards') {
        res = await staking.send(u, 'claimRewards', []);
      } else if (act === 'claimPureYield') {
        res = await staking.send(u, 'claimPureYield', []);
      } else if (act === 'lock') {
        if (staked > 0n && maxDays >= 90n) res = await staking.send(u, 'lock', [between(r, 90n, maxDays + 1n)]);
      } else if (act === 'liquidate') {
        const victim = pick(r, users);
        res = await staking.send(u, 'liquidate', [victim.hex]);
      } else if (act === 'poke') {
        const victim = pick(r, users);
        res = await staking.send(u, 'pokeExpiredLock', [victim.hex]);
      }
    } catch (e) { res = { ok: false, revert: 'harness:' + e.message.slice(0, 40) }; }

    if (res.ok) stat.txOk++; else { stat.txRevert++; bump(stat.reverts, res.revert || 'unknown'); }

    const p = await probe(w);
    if (p.solvencyResidual > stat.maxSolvencyResidual) stat.maxSolvencyResidual = p.solvencyResidual;
    if (p.stranded > stat.maxStranded) stat.maxStranded = p.stranded;
    if (p.staleBE > stat.maxStaleBE) stat.maxStaleBE = p.staleBE;
    if (p.staleBP > stat.maxStaleBP) stat.maxStaleBP = p.staleBP;
    stat.auditViolations |= p.audit;
  }
  stat.final = await probe(w);
  return stat;
}

// ════════════════════════════════════════════════════════════════════════════════════════
//  LAYER 2 — METAMORPHIC RELATIONS
//  Each MR is a predicted relation between two executions. No oracle needed: the RELATION
//  is the oracle. This is where the pattern is isolated from the anecdote.
// ════════════════════════════════════════════════════════════════════════════════════════

// Build the identical pre-state in every arm so the arms differ ONLY in the transformation.
async function stagedWorld({ borrowers = 3, stake = E18(10_000_000), ltv = 40n, idleDays = 120n,
                             pureStake = E18(15_000_000), lever = false }) {
  const w = await world();
  const { staking, chain, users } = w;
  // u0 = honest pure staker (present for the whole interval)
  await staking.send(users[0], 'deposit', [pureStake, 365]);
  // u1..uN = borrowers who will be left untouched to build a backlog
  for (let i = 1; i <= borrowers; i++) {
    await staking.send(users[i], 'deposit', [stake, 365]);
    chain.mine(11);
    const info = await staking.call('getUserInfo', [users[i].hex]);
    const maxB = BigInt(info[3]);
    await staking.send(users[i], 'borrow', [(maxB * ltv) / 50n]);
  }
  // u5 = the LEVER. Staked BEFORE the idle window so that at measurement time its only
  // remaining action is a single borrow(). It carries a token seed debt so its own pure-yield
  // weight is already zero — a debt-free lever would hand the windfall it
  // creates to the honest stakers instead of capturing it.
  if (lever) {
    await staking.send(users[5], 'deposit', [E18(30_000_000), 365]);
    chain.mine(11);
    await staking.send(users[5], 'borrow', [E18(1000)]);          // seed debt
  }
  chain.warp(idleDays * DAY); chain.mine(11);
  return w;
}

async function collateralOf(w, i) { return BigInt((await w.staking.call('getUserInfo', [w.users[i].hex]))[0]); }

// ── DRIVER-INVARIANCE ───────────────────────────────────────────────────────────────────
//  Relation: for a FIXED pre-state and a FIXED final timestamp, the interest charged to a
//  borrower must not depend on WHICH transaction drove the maintenance sweep.
//      ∀ drivers d1,d2 :  interest_i(d1) == interest_i(d2)
async function MR_driver() {
  console.log('\n── MR-DRIVER :: interest must not depend on who drives the sweep ────────────');
  // Every arm shares an IDENTICAL pre-state (same stakes, same lever, same backlog, same
  // final timestamp). The arms differ in exactly one transaction: the one that drives the
  // sweep. Anything the arms do not share would confound the measurement, so the lever is
  // staked during staging, not here.
  const drivers = {
    'tiny deposit': async (w) => { await w.staking.send(w.users[4], 'deposit', [E18(1000), 90]); },
    'claimRewards': async (w) => { await w.staking.send(w.users[0], 'claimRewards', []); },
    'lever borrow': async (w) => {
      const info = await w.staking.call('getUserInfo', [w.users[5].hex]);
      await w.staking.send(w.users[5], 'borrow', [(BigInt(info[3]) * 99n) / 100n]);  // ONE tx: moves the rate, then sweeps
    },
  };
  const out = {};
  for (const [name, drive] of Object.entries(drivers)) {
    const w = await stagedWorld({ lever: true });
    const before = [];
    for (let i = 1; i <= 3; i++) before.push(await collateralOf(w, i));
    const rate0 = BigInt(await w.staking.call('currentInterestRateBps'));
    await drive(w);
    let charged = 0n;
    for (let i = 1; i <= 3; i++) charged += before[i - 1] - (await collateralOf(w, i));
    const rate1 = BigInt(await w.staking.call('currentInterestRateBps'));
    out[name] = { charged, rate0, rate1 };
    console.log(`     driver=${name} : rate ${rate0}→${rate1} bps, collateral confiscated = ${fmt(charged)}`);
  }
  const vals = Object.values(out).map((o) => o.charged);
  const lo = vals.reduce((a, b) => (a < b ? a : b)), hi = vals.reduce((a, b) => (a > b ? a : b));
  const spread = lo === 0n ? 0n : ((hi - lo) * 10_000n) / lo;
  check(spread <= 10n, 'MR-DRIVER: charge is driver-independent',
        `spread = ${Number(spread) / 100}% (min ${fmt(lo)}, max ${fmt(hi)}) — excess principal taken: ${fmt(hi - lo)}`);
  return { lo, hi, spread };
}

// ── TIME-ADDITIVITY ─────────────────────────────────────────────────────────────────────
//  Relation: accruing over [0,T] in ONE step must equal accruing in N steps.
//      A(0→T) == Σ A(t_k → t_{k+1})
//  A correct time-integral satisfies this by construction. A right-endpoint rectangle only
//  satisfies it when the integrand is constant. Applied to BOTH accumulators, it says
//  precisely which one is defective — with no attack narrative involved.
async function MR_additivity() {
  console.log('\n── MR-ADD :: 1 step over T  vs  N steps over T ─────────────────────────────');
  const T = 360n * DAY;

  // arm A: interest accumulator
  const runInterest = async (splits) => {
    const w = await stagedWorld({ idleDays: 1n });
    const before = await collateralOf(w, 1);
    for (let k = 0; k < splits; k++) {
      w.chain.warp(T / BigInt(splits)); w.chain.mine(11);
      await w.staking.send(w.users[0], 'claimRewards', []);   // neutral driver, touches the sweep
    }
    // force realisation of any residue on the borrower itself
    w.chain.mine(11);
    await w.staking.send(w.users[1], 'repay', [1n]);
    return before - (await collateralOf(w, 1));
  };
  const i1 = await runInterest(1), i6 = await runInterest(6), i24 = await runInterest(24);
  console.log(`     interest  1 step: ${fmt(i1)}`);
  console.log(`     interest  6 steps: ${fmt(i6)}`);
  console.log(`     interest 24 steps: ${fmt(i24)}`);
  const iSpread = i1 === 0n ? 0n : (((i24 > i1 ? i24 - i1 : i1 - i24)) * 10_000n) / i1;
  check(iSpread <= 10n, 'MR-ADD (interest): accrual is time-additive',
        `1-step vs 24-step differ by ${Number(iSpread) / 100}%  (Δ = ${fmt(i24 > i1 ? i24 - i1 : i1 - i24)})`);

  // arm B: emission accumulator — the CONTROL. Same transformation, correct implementation.
  const runEmission = async (splits) => {
    const w = await world();
    await w.staking.send(w.users[0], 'deposit', [E18(10_000_000), 365]);
    const p0 = await probe(w);
    for (let k = 0; k < splits; k++) {
      w.chain.warp(T / BigInt(splits)); w.chain.mine(11);
      await w.staking.send(w.users[0], 'claimRewards', []);
    }
    const p1 = await probe(w);
    return p1.actualEmitted - p0.actualEmitted;
  };
  const e1 = await runEmission(1), e24 = await runEmission(24);
  console.log(`     emission  1 step: ${fmt(e1)}`);
  console.log(`     emission 24 steps: ${fmt(e24)}`);
  const eSpread = e1 === 0n ? 0n : (((e24 > e1 ? e24 - e1 : e1 - e24)) * 10_000n) / e1;
  check(eSpread <= 10n, 'MR-ADD (emission): accrual is time-additive  [CONTROL]',
        `1-step vs 24-step differ by ${Number(eSpread) / 100}%`);
  return { iSpread, eSpread };
}

// ── TEMPORAL FAIRNESS ───────────────────────────────────────────────────────────────────
//  Relation: a participant's share of a distribution covering [t0,T] must be proportional to
//  their TIME-WEIGHTED presence ∫w dt over that window, not to their presence at instant T.
//  A participant absent for the whole window must receive zero.
async function MR_jit() {
  console.log('\n── MR-JIT :: yield share must track ∫w·dt, not w(T) ────────────────────────');
  // control arm: nobody enters late
  const ctrl = await stagedWorld({ borrowers: 1, idleDays: 30n });
  await ctrl.staking.send(ctrl.users[4], 'claimRewards', []);   // neutral realisation
  const ctrlYield = BigInt(await ctrl.staking.call('pendingPureYield', [ctrl.users[0].hex]));

  // treatment arm: identical timeline, then a JIT staker enters immediately before realisation
  const jit = await stagedWorld({ borrowers: 1, idleDays: 30n });
  await jit.staking.send(jit.users[4], 'deposit', [E18(30_000_000), 90]);  // enters + triggers sweep
  const jitIncumbent = BigInt(await jit.staking.call('pendingPureYield', [jit.users[0].hex]));
  const jitNewcomer = BigInt(await jit.staking.call('pendingPureYield', [jit.users[4].hex]));

  console.log(`     incumbent yield, no JIT : ${fmt(ctrlYield)}`);
  console.log(`     incumbent yield, w/ JIT : ${fmt(jitIncumbent)}`);
  console.log(`     JIT newcomer captured   : ${fmt(jitNewcomer)}  (presence during window: 0 s)`);
  const captured = jitNewcomer;
  const lost = ctrlYield > jitIncumbent ? ctrlYield - jitIncumbent : 0n;
  check(captured * 10_000n <= ctrlYield, 'MR-JIT: zero-presence participant receives ~zero',
        `captured ${fmt(captured)} of a ${fmt(ctrlYield)} distribution; incumbent lost ${fmt(lost)} (${ctrlYield === 0n ? 0 : Number((lost * 10_000n) / ctrlYield) / 100}%)`);
  return { ctrlYield, jitIncumbent, jitNewcomer, lost };
}

// ── BOOST EQUIVALENCE ───────────────────────────────────────────────────────────────────
//  Relation: boost is the price of illiquidity, therefore it is a function of the capital's
//  REMAINING commitment. Two positions with identical (principal, debt, unlockTime) are
//  economically identical and must receive an identical multiplier.
async function MR_boost() {
  console.log('\n── MR-BOOST :: equal principal + equal unlockTime ⇒ equal multiplier ───────');
  const w = await world();
  const { staking, chain, users } = w;
  const seeder = users[0], honest = users[1];

  // seeder arms a maximal lock with dust, then waits until only ~91 days remain on it
  await staking.send(seeder, 'deposit', [1n, 2555]);
  const su = await staking.call('getUserInfo', [seeder.hex]);
  const seedUnlock = BigInt(su[10]);

  chain.warp((2555n - 91n) * DAY); chain.mine(11);

  // both wallets now commit the SAME capital to the SAME unlock timestamp
  const principal = E18(10_000_000);
  await staking.send(seeder, 'deposit', [principal, 90]);     // discarded: lands before seedUnlock
  const remainingDays = (seedUnlock - chain.time) / DAY;
  await staking.send(honest, 'deposit', [principal, remainingDays]);

  const a = await staking.call('getUserInfo', [seeder.hex]);
  const b = await staking.call('getUserInfo', [honest.hex]);
  const [aBoost, aUnlock, aLockDays] = [BigInt(a[11]), BigInt(a[10]), BigInt(a[9])];
  const [bBoost, bUnlock, bLockDays] = [BigInt(b[11]), BigInt(b[10]), BigInt(b[9])];

  console.log(`     seeded wallet : stored lockDays=${aLockDays}, unlock=${aUnlock}, boost=${aBoost} bps`);
  console.log(`     honest wallet : stored lockDays=${bLockDays}, unlock=${bUnlock}, boost=${bBoost} bps`);
  const unlockGap = aUnlock > bUnlock ? aUnlock - bUnlock : bUnlock - aUnlock;
  console.log(`     unlock timestamps differ by ${unlockGap} s; real commitment both ≈ ${remainingDays} days`);
  check(aBoost === bBoost, 'MR-BOOST: identical commitment ⇒ identical boost',
        `${aBoost} bps vs ${bBoost} bps  (${Number((aBoost * 100n) / bBoost) / 100}x advantage on identical illiquidity)`);

  // The re-key fires on incoming principal, NOT as a decay. A position that commits long and
  // never touches itself keeps its multiplier for the whole term. Asserted here so the design
  // choice is on the record rather than assumed, and so a future change to it breaks a test.
  {
    const d = await world();
    await d.staking.send(d.users[0], 'deposit', [E18(1_000_000), 2555]);
    const atOpen = BigInt(await d.staking.call('effectiveBoostOf', [d.users[0].hex]));
    d.chain.warp(2000n * DAY); d.chain.mine(11);
    const late = BigInt(await d.staking.call('effectiveBoostOf', [d.users[0].hex]));
    const remaining = 2555n - 2000n;
    const fresh = BigInt(await d.staking.call('boostByDays', [remaining]));
    console.log(`     7-year lock with ${remaining}d left is paid ${late} bps; a fresh ${remaining}d lock is paid ${fresh} bps`);
    check(late === atOpen, 'MR-BOOST: a committed position keeps its multiplier for the whole term',
          `${atOpen} → ${late}`);
    check(late > fresh, 'MR-BOOST: that is strictly more than a fresh lock of the remaining length — by design',
          `the two are equal, so the multiplier is decaying`);
  }

  // Monotonicity: an untouched position's paid multiplier must never increase with time.
  let prev = BigInt(await staking.call('effectiveBoostOf', [honest.hex]));
  let mono = true;
  for (let k = 0; k < 6; k++) {
    chain.warp(20n * DAY); chain.mine(2);
    const now = BigInt(await staking.call('effectiveBoostOf', [honest.hex]));
    if (now > prev) mono = false;
    prev = now;
  }
  check(mono, 'MR-BOOST: paid multiplier is monotone non-increasing while untouched');
  return { aBoost, bBoost, remainingDays };
}

// ── EXIT-PATH CLOSURE ───────────────────────────────────────────────────────────────────
//  Every exit path must move `owed` and `backing` by the same amount:  Δowed == Δbacking.
//  The interesting branch is an under-water exit, where the position's debt exceeds its
//  collateral. Reaching it takes a fully leveraged pool left untended under a pause — a pause
//  disables every liquidation path, and utilisation climbs on its own because interest is
//  charged against collateral.
async function exitClosure() {
  console.log('\n── EXIT CLOSURE :: Δowed must equal Δbacking on every exit path ────────────');
  const w = await world();
  const { staking, chain, users, guardian, admin } = w;

  for (const u of users) await staking.send(u, 'deposit', [E18(10_000_000), 365]);
  chain.mine(11);
  for (const u of users) {
    const i = await staking.call('getUserInfo', [u.hex]);
    await staking.send(u, 'borrow', [BigInt(i[3])]);
  }
  await staking.send(guardian, 'pause', []);      // the ordinary incident-response first step

  let staked = 0n, debt = 0n, years = null;
  for (let y = 1; y <= 60; y++) {
    chain.warp(YEAR); chain.mine(11);
    for (const u of users) await staking.send(u, 'repay', [1n]);
    const i = await staking.call('getUserInfo', [users[0].hex]);
    staked = BigInt(i[0]); debt = BigInt(i[1]);
    if (y % 10 === 0) {
      const util = BigInt(await staking.call('utilizationRate'));
      console.log(`     +${String(y).padStart(2)}y paused : collateral ${fmt(staked)} debt ${fmt(debt)} util ${(Number(util) / 1e16).toFixed(1)}%`);
    }
    if (staked > 0n && staked < debt) { years = y; break; }
  }
  console.log(`     under water after ${years} paused years: collateral ${fmt(staked)}, debt ${fmt(debt)}`);
  if (!check(years !== null, 'EXIT CLOSURE: the under-water branch was reached (precondition)',
             'never reached — the branch below is untested')) return { reached: false };

  await staking.send(guardian, 'declareEmergency', []);
  const p0 = await probe(w);
  const r = await staking.send(users[0], 'emergencyWithdraw', []);
  const p1 = await probe(w);
  const dOwed = p1.owed - p0.owed, dBacking = p1.backing - p0.backing;
  const gap = dOwed - dBacking;
  console.log(`     emergencyWithdraw ok=${r.ok}  Δowed=${fmt(dOwed)}  Δbacking=${fmt(dBacking)}  totalBadDebt=${fmt(p1.badDebt)}`);

  check(gap <= DUST && gap >= -DUST, 'EXIT CLOSURE: an under-water exit conserves the identity',
        `Δowed − Δbacking = ${fmt(gap)} (equals the unrecorded shortfall debt−collateral = ${fmt(debt - staked)})`);
  // The shortfall must be ACCOUNTED FOR, which is not the same as always landing in totalBadDebt:
  // protocol revenue absorbs it first and only the uncovered remainder is socialised, exactly as
  // the liquidation path has always done. What must hold is that the two together equal the gap.
  const shortfall = debt > staked ? debt - staked : 0n;
  const absorbed = (p0.protocolReserve - p1.protocolReserve) + (p1.badDebt - p0.badDebt);
  console.log(`     shortfall ${fmt(shortfall)} = reserve absorbed ${fmt(p0.protocolReserve - p1.protocolReserve)}` +
              ` + bad debt recorded ${fmt(p1.badDebt - p0.badDebt)}`);
  check(absorbed === shortfall, 'EXIT CLOSURE: the realised loss is fully accounted for',
        `accounted ${fmt(absorbed)} vs shortfall ${fmt(shortfall)}`);
  const solvent = await staking.call('isSolvent');
  check(solvent === true, 'EXIT CLOSURE: the protocol remains solvent after the exit',
        `isSolvent=${solvent}, audit=${p1.audit}, residual=${fmt(p1.solvencyResidual)}`);
  const cancel = await staking.send(admin, 'cancelEmergency', []);
  check(cancel.ok, 'EXIT CLOSURE: emergency can still be lifted (no freeze)',
        `cancelEmergency reverted with ${cancel.revert} — ${fmt(p1.backing)} BZPX immobilised`);
  return { gap, years, reached: true };
}

// ── RATE CURVE REACH ────────────────────────────────────────────────────────────────────
//  How far up its own curve can the protocol actually travel? This matters because the kinked
//  curve is gentle below 80% utilisation (S1 = 500) and extremely steep above it (S2 = 72500),
//  so whether the kink is reachable decides whether the steep branch is live code.
//
//  The first borrow on a debt-free position is capped at half the effective stake, which is the
//  whole stake — so utilisation reaches 50% immediately. From there interest is charged against
//  COLLATERAL while debt stays fixed, so utilisation climbs on its own with no further borrowing.
//  The kink is therefore reachable, and the steep branch is live.
async function rateCurveReach() {
  console.log('\n── RATE CURVE :: how far up the kinked curve the protocol can travel ───────');
  const w = await world();
  const { staking, chain, users } = w;

  // every participant is a borrower at maximum LTV — no pure stake diluting the denominator
  for (const u of users) await staking.send(u, 'deposit', [E18(10_000_000), 365]);
  chain.mine(11);
  for (const u of users) {
    const i = await staking.call('getUserInfo', [u.hex]);
    await staking.send(u, 'borrow', [BigInt(i[3])]);
  }
  const util0 = BigInt(await staking.call('utilizationRate'));
  const rate0 = BigInt(await staking.call('currentInterestRateBps'));
  console.log(`     immediately after max borrows: util ${(Number(util0) / 1e16).toFixed(2)}%  rate ${rate0} bps`);
  check(util0 >= 499_000_000_000_000_000n && util0 <= 501_000_000_000_000_000n,
        'RATE CURVE: a single round of max borrowing reaches 50% utilisation', `got ${util0}`);

  let crossed = false, yearsToKink = null;
  for (let y = 1; y <= 40 && !crossed; y++) {
    chain.warp(YEAR); chain.mine(11);
    for (const u of users) await staking.send(u, 'repay', [1n]);
    const util = BigInt(await staking.call('utilizationRate'));
    const rate = BigInt(await staking.call('currentInterestRateBps'));
    if (y % 10 === 0) console.log(`     +${String(y).padStart(2)}y : util ${(Number(util) / 1e16).toFixed(2)}%  rate ${rate} bps`);
    if (util > 800_000_000_000_000_000n) {
      crossed = true; yearsToKink = y;
      console.log(`     +${String(y).padStart(2)}y : util ${(Number(util) / 1e16).toFixed(2)}%  rate ${rate} bps  ← past the 80% kink`);
    }
  }
  check(crossed, 'RATE CURVE: the 80% kink is reachable, so the steep S2 branch is LIVE code',
        'never crossed within 40 years — S2 would then be unreachable');
  console.log(`     ⇒ the steep branch engages after ~${yearsToKink} years of a fully leveraged, untended pool.`);
  console.log(`       The rate is NOT bounded near the base of the curve; do not treat S2 as dead.`);
  return { util0, rate0, yearsToKink };
}

// ── STALE-BOOST REGRESSION (BP-2026-001, fixed in v3.1) ─────────────────────────────────
//  The Layer-1 metric `staleBP` only means something if it CAN be non-zero. Here we construct
//  the exact BP-2026-001 scenario — an idle pure staker whose lock has lapsed — and confirm
//  (a) the metric is sensitive to it, and (b) the paid multiplier is already re-priced.
async function MR_stale() {
  console.log('\n── MR-STALE :: idle pure staker past unlock (BP-2026-001 regression) ───────');
  const w = await world();
  const { staking, chain, users } = w;
  await staking.send(users[0], 'deposit', [E18(10_000_000), 730]);   // 1.25x
  await staking.send(users[1], 'deposit', [E18(10_000_000), 730]);
  const boost0 = BigInt(await staking.call('effectiveBoostOf', [users[0].hex]));

  chain.warp(731n * DAY); chain.mine(11);                            // both locks lapse
  const boost1 = BigInt(await staking.call('effectiveBoostOf', [users[0].hex]));
  const stale = await staking.call('hasStaleBoost', [users[0].hex]);
  const p = await probe(w);
  console.log(`     boost while locked: ${boost0} bps → after expiry (untouched): ${boost1} bps`);
  console.log(`     hasStaleBoost=${stale}  tracked-vs-derived weight gap (pure) = ${fmt(p.staleBP)}`);
  console.log(`     isTrackedLocker=${await staking.call('isTrackedLocker', [users[0].hex])}  ` +
              `activeLockerCount=${await staking.call('activeLockerCount')}`);

  check(boost1 === 10_000n, 'MR-STALE: paid multiplier drops to 1.00x the instant the lock lapses');
  check(p.staleBP > 0n, 'MR-STALE [SENSITIVITY]: the staleness metric is non-vacuous',
        `metric read 0 even in the known-stale state — the Layer-1 "0 stale weight" result would be meaningless`);

  // now let ordinary traffic drive the autonomous locker sweep and confirm it self-heals
  for (let k = 0; k < 8; k++) { chain.mine(2); await staking.send(users[2], 'claimRewards', []); }
  const p2 = await probe(w);
  console.log(`     after 8 ordinary txs — tracked-vs-derived weight gap (pure) = ${fmt(p2.staleBP)}`);
  check(p2.staleBP === 0n, 'MR-STALE: autonomous locker sweep clears stale weight without the idle user acting',
        `residual gap ${fmt(p2.staleBP)}`);
  return { boost0, boost1, staleBefore: p.staleBP, staleAfter: p2.staleBP };
}

// ── EMISSION BUDGET CLOSURE ─────────────────────────────────────────────────────────────
//  Relation: the emission budget is closed. Over the programme's life,
//      TOTAL_FUNDED == distributed + recoverable
//  i.e. no term may be created that is neither payable to a staker nor reclaimable.
async function MR_emission() {
  console.log('\n── MR-EMISSION :: budget closure over an empty window ──────────────────────');
  const w = await world();
  const { staking, chain, users, admin } = w;
  const emptyDays = 30n;

  chain.warp(emptyDays * DAY); chain.mine(11);        // pool empty: clock runs, nothing accrues
  // NB: the lock must fit inside the remaining emission window (maxLockDaysAvailable shrinks
  // with the clock), otherwise the deposit reverts and the whole arm measures nothing.
  const maxDays = BigInt(await staking.call('maxLockDaysAvailable'));
  const dep0 = await staking.send(users[0], 'deposit', [E18(10_000_000), maxDays]);
  check(dep0.ok, 'MR-EMISSION: staging deposit succeeded', `reverted with ${dep0.revert}`);
  const p = await probe(w);
  console.log(`     empty window: ${emptyDays} days`);
  console.log(`     ideal emitted : ${fmt(p.idealEmitted)}`);
  console.log(`     actual emitted: ${fmt(p.actualEmitted)}`);
  console.log(`     stranded      : ${fmt(p.stranded)}  (= REWARD_PER_SEC × empty seconds)`);

  const predicted = REWARD_PER_SEC * emptyDays * DAY;
  const err = p.stranded > predicted ? p.stranded - predicted : predicted - p.stranded;
  console.log(`     predicted     : ${fmt(predicted)}   |model error| = ${fmt(err)}`);

  // Run the programme to completion with the pool CONTINUOUSLY populated, then ask whether
  // any route can still move the residue. The pool stays full for the whole remaining window,
  // so anything left over is attributable solely to the empty window at the start.
  for (let k = 0; k < 10; k++) {
    chain.warp(YEAR); chain.mine(11);
    await staking.send(users[0], 'claimRewards', []);
  }
  const residue = BigInt(await staking.call('rewardReserve'));
  console.log(`     after emissionEnd — rewardReserve still holds: ${fmt(residue)}`);

  // Enumerate every route that could conceivably move it.
  const dep = await staking.send(users[1], 'deposit', [E18(1000), 90]);
  const clm = await staking.send(users[0], 'claimRewards', []);
  const protoRes = BigInt(await staking.call('protocolReserve'));
  const wd = await staking.send(admin, 'withdrawReserve', [residue > 0n ? residue : 1n]);
  const residueAfter = BigInt(await staking.call('rewardReserve'));
  console.log(`     recovery: deposit→${dep.ok ? 'ok' : dep.revert} | claimRewards→${clm.ok ? 'ok' : clm.revert} | ` +
              `withdrawReserve(${fmt(residue)})→${wd.ok ? 'ok' : wd.revert} (protocolReserve was only ${fmt(protoRes)})`);
  console.log(`     rewardReserve after every recovery attempt: ${fmt(residueAfter)}`);

  // Declining to accrue while the pool is empty is deliberate and stays — it is what stops a
  // latecomer harvesting a backlog. The property that must hold is that the resulting residue is
  // RECOVERABLE rather than owed to nobody and reachable by nobody.
  const treBefore = BigInt(await w.token.call('balanceOf', [w.treasury.hex]));
  const sweep = await staking.send(admin, 'sweepUndistributedEmission', []);
  const residueAfterSweep = BigInt(await staking.call('rewardReserve'));
  const treGain = BigInt(await w.token.call('balanceOf', [w.treasury.hex])) - treBefore;
  console.log(`     sweepUndistributedEmission → ${sweep.ok ? 'ok' : sweep.revert}; ` +
              `treasury received ${fmt(treGain)}, rewardReserve now ${fmt(residueAfterSweep)}`);
  check(sweep.ok && residueAfterSweep === 0n && treGain === residue,
        'MR-EMISSION: the undistributable residue is recoverable in full',
        `swept=${sweep.ok ? 'ok' : sweep.revert}, left ${fmt(residueAfterSweep)}, treasury +${fmt(treGain)}`);
  const pAfter = await probe(w);
  check(pAfter.solvencyResidual <= DUST, 'MR-EMISSION: the sweep conserves the identity',
        `residual ${pAfter.solvencyResidual} wei`);
  check(err <= REWARD_PER_SEC * 120n, 'MR-EMISSION: stranding matches the closed-form model rate×Δt',
        `|model error| = ${fmt(err)}`);
  return { stranded: p.stranded, residue, predicted };
}

// ════════════════════════════════════════════════════════════════════════════════════════
//  MOCK SCENARIOS
//  Behavioural coverage against a mock BZPX: role separation, the emergency lifecycle,
//  registry bookkeeping, view/state agreement, and a token that can refuse to pay. These are
//  ordinary assertions rather than paired-execution relations — they pin down behaviour that
//  is supposed to be exact, so that any later change to the time-axis logic cannot quietly
//  move it.
// ════════════════════════════════════════════════════════════════════════════════════════
const ADMIN_ROLE = ethers.id('ADMIN_ROLE');
const GUARDIAN_ROLE = ethers.id('GUARDIAN_ROLE');

async function mockScenarios() {
  console.log('\n── MOCK :: emission funding cap and accounting ─────────────────────────────');
  {
    const w = await world({ fundAll: false });
    const { staking, admin } = w;
    const a = await staking.send(admin, 'fundEmission', [E18(100_000_000)]);
    const b = await staking.send(admin, 'fundEmission', [E18(80_000_000)]);
    const c = await staking.send(admin, 'fundEmission', [1n]);
    check(a.ok && b.ok, 'MOCK: emission funds incrementally up to the cap');
    check(!c.ok && c.revert === 'Staking__CapExceeded', 'MOCK: funding past TOTAL_REWARDS reverts',
          `got ${c.revert}`);
    const funded = BigInt(await staking.call('totalEmissionFunded'));
    const reserve = BigInt(await staking.call('rewardReserve'));
    check(funded === E18(180_000_000) && reserve === funded,
          'MOCK: totalEmissionFunded == rewardReserve before any accrual',
          `funded=${fmt(funded)} reserve=${fmt(reserve)}`);
    const z = await staking.send(admin, 'fundEmission', [0n]);
    check(!z.ok && z.revert === 'Staking__ZeroAmount', 'MOCK: zero-amount funding reverts', `got ${z.revert}`);
  }

  console.log('\n── MOCK :: role separation ─────────────────────────────────────────────────');
  {
    const w = await world();
    const { staking, admin, guardian, users, treasury, token } = w;
    const outsider = users[3];

    const r1 = await staking.send(outsider, 'fundEmission', [E18(1)]);
    check(!r1.ok, 'MOCK: non-admin cannot fund emission', `got ok=${r1.ok}`);
    const r2 = await staking.send(outsider, 'pause', []);
    check(!r2.ok, 'MOCK: non-guardian cannot pause', `got ok=${r2.ok}`);
    const r3 = await staking.send(outsider, 'declareEmergency', []);
    check(!r3.ok, 'MOCK: non-guardian cannot declare emergency', `got ok=${r3.ok}`);
    const r4 = await staking.send(guardian, 'unpause', []);
    check(!r4.ok, 'MOCK: guardian cannot unpause (admin-only, asymmetric by design)', `got ok=${r4.ok}`);
    const r5 = await staking.send(outsider, 'withdrawReserve', [E18(1)]);
    check(!r5.ok, 'MOCK: non-admin cannot withdraw reserve', `got ok=${r5.ok}`);

    check(await staking.call('hasRole', [ADMIN_ROLE, admin.hex]) === true, 'MOCK: deployer holds ADMIN_ROLE');
    check(await staking.call('hasRole', [GUARDIAN_ROLE, guardian.hex]) === true, 'MOCK: guardian holds GUARDIAN_ROLE');
    check(await staking.call('hasRole', [ADMIN_ROLE, outsider.hex]) === false, 'MOCK: outsider holds no role');

    // reserve can only ever land on the immutable treasury
    await staking.send(users[0], 'deposit', [E18(5_000_000), 365]);
    await staking.send(users[1], 'deposit', [E18(5_000_000), 365]);
    w.chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[1].hex]);
    await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
    w.chain.warp(120n * DAY); w.chain.mine(11);
    await staking.send(users[0], 'claimRewards', []);
    const pr = BigInt(await staking.call('protocolReserve'));
    const tBefore = BigInt(await token.call('balanceOf', [treasury.hex]));
    const wd = await staking.send(admin, 'withdrawReserve', [pr]);
    const tAfter = BigInt(await token.call('balanceOf', [treasury.hex]));
    check(wd.ok && tAfter - tBefore === pr && pr > 0n,
          'MOCK: withdrawReserve pays the immutable treasury, exactly protocolReserve',
          `pr=${fmt(pr)} delta=${fmt(tAfter - tBefore)}`);
    check(BigInt(await staking.call('protocolReserve')) === 0n, 'MOCK: protocolReserve drains to zero');
  }

  console.log('\n── MOCK :: reserve factor splits interest 3% / 97% ─────────────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    await staking.send(users[0], 'deposit', [E18(10_000_000), 365]);
    await staking.send(users[1], 'deposit', [E18(10_000_000), 365]);
    chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[1].hex]);
    await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
    const c0 = BigInt((await staking.call('getUserInfo', [users[1].hex]))[0]);
    const pr0 = BigInt(await staking.call('protocolReserve'));
    chain.warp(200n * DAY); chain.mine(11);
    await staking.send(users[0], 'claimRewards', []);
    const c1 = BigInt((await staking.call('getUserInfo', [users[1].hex]))[0]);
    const pr1 = BigInt(await staking.call('protocolReserve'));
    const interest = c0 - c1, cut = pr1 - pr0;
    const bps = interest === 0n ? 0n : (cut * 10_000n) / interest;
    console.log(`     interest charged ${fmt(interest)} → reserve ${fmt(cut)} (${Number(bps)} bps)`);
    check(interest > 0n && bps >= 299n && bps <= 301n,
          'MOCK: protocol takes exactly RESERVE_FACTOR_BPS (300) of realised interest', `got ${bps} bps`);
  }

  console.log('\n── MOCK :: flash-loan / same-block guards ──────────────────────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    await staking.send(users[0], 'deposit', [E18(1_000_000), 90]);
    chain.warp(91n * DAY);                       // lock expired, but blocks not yet elapsed
    const early = await staking.send(users[0], 'withdraw', [E18(1)]);
    check(!early.ok && early.revert === 'Staking__FlashLoanProtection',
          'MOCK: withdraw within MIN_DEPOSIT_BLOCKS reverts', `got ${early.revert}`);
    chain.mine(11);
    const late = await staking.send(users[0], 'withdraw', [E18(1)]);
    check(late.ok, 'MOCK: withdraw succeeds once the block delay has passed', `got ${late.revert}`);
  }

  console.log('\n── MOCK :: lock semantics ──────────────────────────────────────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    await staking.send(users[0], 'deposit', [E18(1_000_000), 730]);
    chain.mine(11);                              // lock() carries the same block-delay guard
    const shorter = await staking.send(users[0], 'lock', [365]);
    check(!shorter.ok && shorter.revert === 'Staking__CannotReduceLock',
          'MOCK: lock() refuses to shorten an existing commitment', `got ${shorter.revert}`);
    const longer = await staking.send(users[0], 'lock', [1825]);
    check(longer.ok, 'MOCK: lock() extends', `got ${longer.revert}`);
    check(BigInt(await staking.call('effectiveBoostOf', [users[0].hex])) === 20_000n,
          'MOCK: extended lock is priced at the 5-year multiplier (2.00x)');
    const noStake = await staking.send(users[4], 'lock', [365]);
    check(!noStake.ok, 'MOCK: lock() on an empty position reverts', `got ok=${noStake.ok}`);

    // withdrawal is blocked while the commitment is live
    chain.mine(11);
    const stillLocked = await staking.send(users[0], 'withdraw', [E18(1)]);
    check(!stillLocked.ok && stillLocked.revert === 'Staking__StillLocked',
          'MOCK: withdraw blocked while locked', `got ${stillLocked.revert}`);
  }

  console.log('\n── MOCK :: boost curve boundaries ──────────────────────────────────────────');
  {
    const w = await world();
    const { staking } = w;
    const pairs = [[0, 10_000], [90, 10_199], [365, 11_000], [730, 12_500], [1825, 20_000], [2555, 27_500]];
    let allOk = true;
    for (const [d, want] of pairs) {
      const got = BigInt(await staking.call('boostByDays', [d]));
      if (got !== BigInt(want)) { allOk = false; console.log(`     d=${d}: got ${got}, want ${want}`); }
    }
    check(allOk, 'MOCK: boost curve matches its closed form at every documented point');
    check(BigInt(await staking.call('boostByDays', [99_999])) === 27_500n,
          'MOCK: boost clamps above MAX_LOCK_DAYS');
    // monotone non-decreasing across the whole domain
    let prev = 0n, mono = true;
    for (let d = 0; d <= 2600; d += 50) {
      const b = BigInt(await staking.call('boostByDays', [d]));
      if (b < prev) mono = false;
      prev = b;
    }
    check(mono, 'MOCK: boost curve is monotone non-decreasing in committed duration');
  }

  console.log('\n── MOCK :: LTV bounds and borrow guards ────────────────────────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    await staking.send(users[0], 'deposit', [E18(10_000_000), 365]);   // lending liquidity
    await staking.send(users[1], 'deposit', [E18(1_000_000), 365]);
    chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[1].hex]);
    const cap = BigInt(inf[3]);
    const over = await staking.send(users[1], 'borrow', [cap + E18(1)]);
    check(!over.ok && over.revert === 'Staking__LTVExceeded', 'MOCK: borrowing past the LTV cap reverts',
          `got ${over.revert}`);
    check(cap === E18(500_000), 'MOCK: first borrow cap is 50% of effective stake', `cap=${fmt(cap)}`);
    const zero = await staking.send(users[1], 'borrow', [0n]);
    check(!zero.ok && zero.revert === 'Staking__ZeroAmount', 'MOCK: zero borrow reverts', `got ${zero.revert}`);
    const okBorrow = await staking.send(users[1], 'borrow', [cap]);
    check(okBorrow.ok, 'MOCK: borrowing exactly at the cap succeeds', `got ${okBorrow.revert}`);
    const wd = await staking.send(users[1], 'withdraw', [E18(1)]);
    check(!wd.ok && wd.revert === 'Staking__HasDebt', 'MOCK: a borrower cannot withdraw before repaying',
          `got ${wd.revert}`);
    const noDebt = await staking.send(users[0], 'repay', [E18(1)]);
    check(!noDebt.ok && noDebt.revert === 'Staking__NoDebt', 'MOCK: repaying with no debt reverts',
          `got ${noDebt.revert}`);
  }

  console.log('\n── MOCK :: per-wallet stake cap ────────────────────────────────────────────');
  {
    const w = await world();
    const { staking, users } = w;
    const ok1 = await staking.send(users[0], 'deposit', [E18(30_000_000), 365]);
    check(ok1.ok, 'MOCK: deposit up to MAX_STAKE_PER_WALLET succeeds', `got ${ok1.revert}`);
    check(BigInt((await staking.call('getUserInfo', [users[0].hex]))[12]) === 0n,
          'MOCK: remaining capacity reads zero at the cap');
    const over = await staking.send(users[0], 'deposit', [E18(1), 365]);
    check(!over.ok && over.revert === 'Staking__CapExceeded', 'MOCK: exceeding the wallet cap reverts',
          `got ${over.revert}`);
  }

  console.log('\n── MOCK :: registry bookkeeping (borrowers / lockers) ──────────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    await staking.send(users[0], 'deposit', [E18(10_000_000), 365]);
    check(await staking.call('isTrackedBorrower', [users[0].hex]) === false,
          'MOCK: a pure staker is not in the borrower registry');
    check(await staking.call('isTrackedLocker', [users[0].hex]) === true,
          'MOCK: a locked position IS in the locker registry');
    chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[0].hex]);
    await staking.send(users[0], 'borrow', [BigInt(inf[3]) / 2n]);
    check(await staking.call('isTrackedBorrower', [users[0].hex]) === true,
          'MOCK: borrowing registers the position');
    check(BigInt(await staking.call('activeBorrowerCount')) === 1n, 'MOCK: borrower count is exact');
    await staking.send(users[0], 'repay', [MAX_UINT]);
    check(await staking.call('isTrackedBorrower', [users[0].hex]) === false,
          'MOCK: full repayment de-registers the borrower');
    check(BigInt(await staking.call('activeBorrowerCount')) === 0n, 'MOCK: borrower count returns to zero');
    // lock expiry de-registers the locker
    chain.warp(366n * DAY); chain.mine(11);
    await staking.send(users[0], 'pokeExpiredLock', [users[0].hex]);
    check(await staking.call('isTrackedLocker', [users[0].hex]) === false,
          'MOCK: an expired lock is de-registered from the locker registry');
    check(BigInt(await staking.call('activeLockerCount')) === 0n, 'MOCK: locker count returns to zero');
  }

  console.log('\n── MOCK :: view/state agreement ────────────────────────────────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    await staking.send(users[0], 'deposit', [E18(8_000_000), 730]);
    await staking.send(users[1], 'deposit', [E18(4_000_000), 365]);
    chain.mine(11);
    const inf1 = await staking.call('getUserInfo', [users[1].hex]);
    await staking.send(users[1], 'borrow', [BigInt(inf1[3]) / 2n]);
    chain.warp(45n * DAY); chain.mine(11);

    for (const u of [users[0], users[1]]) {
      const info = await staking.call('getUserInfo', [u.hex]);
      const staked = BigInt(info[0]), debt = BigInt(info[1]), effView = BigInt(info[2]), boost = BigInt(info[11]);
      const effStandalone = BigInt(await staking.call('effectiveStakeOf', [u.hex]));
      const boostStandalone = BigInt(await staking.call('effectiveBoostOf', [u.hex]));
      check(effView === effStandalone && effView === (staked > debt ? staked - debt : 0n),
            `MOCK: effectiveStake agrees across views (${u.name})`);
      check(boost === boostStandalone, `MOCK: boost agrees across views (${u.name})`);
    }
    const rateView = BigInt(await staking.call('currentInterestRateBps'));
    const util = BigInt(await staking.call('utilizationRate'));
    const simulated = BigInt(await staking.call('simulateRate', [util]));
    check(rateView === simulated, 'MOCK: simulateRate(utilisation) reproduces the live rate',
          `live=${rateView} simulated=${simulated}`);

    // pendingRewards must be paid out to the wei
    const pending = BigInt(await staking.call('pendingRewards', [users[0].hex]));
    const balBefore = BigInt(await w.token.call('balanceOf', [users[0].hex]));
    await staking.send(users[0], 'claimRewards', []);
    const paid = BigInt(await w.token.call('balanceOf', [users[0].hex])) - balBefore;
    check(paid >= pending, 'MOCK: claimRewards pays at least the quoted pendingRewards',
          `quoted ${fmt(pending)}, paid ${fmt(paid)}`);
  }

  console.log('\n── MOCK :: hostile token (transfer returns false) ──────────────────────────');
  {
    const w = await world();
    const { staking, token, users } = w;
    await staking.send(users[0], 'deposit', [E18(1_000_000), 90]);
    w.chain.warp(30n * DAY); w.chain.mine(11);
    await token.send(users[0], 'setFailNextTransfer', [true]);
    const r = await staking.send(users[0], 'claimRewards', []);
    check(!r.ok && r.revert === 'Staking__TransferFailed',
          'MOCK: a refused payout reverts the whole claim rather than losing the entitlement',
          `got ${r.revert}`);
    // The mock clears its own flag before returning false, but that write is rolled back with
    // the reverting transaction — so the flag genuinely survives. Clear it explicitly.
    await token.send(users[0], 'setFailNextTransfer', [false]);
    const after = await staking.send(users[0], 'claimRewards', []);
    check(after.ok, 'MOCK: the claim succeeds once the token behaves again', `got ${after.revert}`);
    const p = await probe(w);
    check(p.solvencyResidual <= DUST, 'MOCK: solvency intact after a failed transfer',
          `residual ${p.solvencyResidual}`);
  }

  console.log('\n── MOCK :: pause / emergency lifecycle ─────────────────────────────────────');
  {
    const w = await world();
    const { staking, chain, users, guardian, admin } = w;
    await staking.send(users[0], 'deposit', [E18(5_000_000), 90]);
    chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[0].hex]);
    await staking.send(users[0], 'borrow', [BigInt(inf[3]) / 2n]);

    await staking.send(guardian, 'pause', []);
    const depPaused = await staking.send(users[1], 'deposit', [E18(1_000), 90]);
    check(!depPaused.ok, 'MOCK: deposits blocked while paused', `got ok=${depPaused.ok}`);
    const repayPaused = await staking.send(users[0], 'repay', [E18(1)]);
    check(repayPaused.ok, 'MOCK: repay stays open while paused (a borrower can always de-risk)',
          `got ${repayPaused.revert}`);
    const liqPaused = await staking.send(users[2], 'liquidate', [users[0].hex]);
    check(!liqPaused.ok, 'MOCK: liquidation disabled while paused', `got ok=${liqPaused.ok}`);

    await staking.send(admin, 'unpause', []);
    const depOk = await staking.send(users[1], 'deposit', [E18(1_000), 90]);
    check(depOk.ok, 'MOCK: deposits resume after unpause', `got ${depOk.revert}`);

    await staking.send(guardian, 'declareEmergency', []);
    check(await staking.call('emergencyMode') === true, 'MOCK: emergency mode latches');
    const depEmg = await staking.send(users[1], 'deposit', [E18(1_000), 90]);
    // declareEmergency also pauses, and whenNotPaused is evaluated first, so either guard is a
    // correct rejection — what matters is that the entry point is shut.
    check(!depEmg.ok && (depEmg.revert === 'Staking__EmergencyActive' || depEmg.revert === 'EnforcedPause'),
          'MOCK: deposits blocked in emergency', `got ${depEmg.revert}`);
    const wdEmg = await staking.send(admin, 'withdrawReserve', [E18(1)]);
    check(!wdEmg.ok && wdEmg.revert === 'Staking__EmergencyActive',
          'MOCK: admin reserve withdrawal blocked in emergency', `got ${wdEmg.revert}`);

    const exit = await staking.send(users[1], 'emergencyWithdraw', []);
    check(exit.ok, 'MOCK: emergencyWithdraw remains open in emergency', `got ${exit.revert}`);
    const twice = await staking.send(users[1], 'emergencyWithdraw', []);
    check(!twice.ok && twice.revert === 'Staking__NoStake', 'MOCK: a drained position cannot exit twice',
          `got ${twice.revert}`);

    const cancel = await staking.send(admin, 'cancelEmergency', []);
    check(cancel.ok, 'MOCK: a solvent protocol can leave emergency', `got ${cancel.revert}`);
    check(await staking.call('emergencyMode') === false, 'MOCK: emergency flag clears');
  }

  console.log('\n── MOCK :: undistributed-emission sweep ────────────────────────────────────');
  {
    const w = await world();
    const { staking, chain, users, admin, treasury, token } = w;
    const early = await staking.send(admin, 'sweepUndistributedEmission', []);
    check(!early.ok && early.revert === 'Staking__EmissionNotEnded',
          'MOCK: the sweep is closed until the emission programme ends', `got ${early.revert}`);
    chain.warp(10n * DAY); chain.mine(5);
    await staking.send(users[0], 'deposit', [E18(5_000_000), 365]);
    chain.warp(8n * YEAR); chain.mine(20);
    const notAdmin = await staking.send(users[1], 'sweepUndistributedEmission', []);
    check(!notAdmin.ok, 'MOCK: the sweep is admin-only', `got ok=${notAdmin.ok}`);
    const before = BigInt(await token.call('balanceOf', [treasury.hex]));
    const r = await staking.send(admin, 'sweepUndistributedEmission', []);
    const gain = BigInt(await token.call('balanceOf', [treasury.hex])) - before;
    check(r.ok && gain > 0n, 'MOCK: the sweep pays the residue to the treasury',
          `ok=${r.ok} revert=${r.revert} gain=${fmt(gain)}`);
    check(BigInt(await staking.call('rewardReserve')) === 0n, 'MOCK: rewardReserve is emptied');
    const again = await staking.send(admin, 'sweepUndistributedEmission', []);
    check(!again.ok && again.revert === 'Staking__ZeroAmount',
          'MOCK: a second sweep has nothing left to take', `got ${again.revert}`);
    const p = await probe(w);
    check(p.solvencyResidual <= DUST, 'MOCK: solvency intact after the sweep', `residual ${p.solvencyResidual}`);
  }

  console.log('\n── MOCK :: emergency exit conserves (healthy branch regression) ────────────');
  {
    const w = await world();
    const { staking, chain, users, guardian, admin } = w;
    await staking.send(users[0], 'deposit', [E18(4_000_000), 365]);
    await staking.send(users[1], 'deposit', [E18(2_000_000), 90]);
    chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[1].hex]);
    await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
    chain.warp(200n * DAY); chain.mine(11);
    await staking.send(guardian, 'declareEmergency', []);

    const p0 = await probe(w);
    const exit = await staking.send(users[1], 'emergencyWithdraw', []);
    const p1 = await probe(w);
    const gap = (p1.owed - p0.owed) - (p1.backing - p0.backing);
    check(exit.ok && gap <= DUST && gap >= -DUST,
          'MOCK: a collateralised emergency exit moves owed and backing together',
          `Δowed−Δbacking = ${fmt(gap)}`);
    check(p1.badDebt === 0n, 'MOCK: no bad debt recorded on a healthy exit', `got ${fmt(p1.badDebt)}`);
    const cancel = await staking.send(admin, 'cancelEmergency', []);
    check(cancel.ok, 'MOCK: emergency remains cancellable after the exit', `got ${cancel.revert}`);
  }

  console.log('\n── ADVERSARIAL :: no double-counting of interest ───────────────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    await staking.send(users[0], 'deposit', [E18(15_000_000), 365]);
    for (let i = 1; i <= 3; i++) {
      await staking.send(users[i], 'deposit', [E18(10_000_000), 365]); chain.mine(11);
      const inf = await staking.call('getUserInfo', [users[i].hex]);
      await staking.send(users[i], 'borrow', [BigInt(inf[3])]);
    }
    const col0 = []; for (let i = 1; i <= 3; i++) col0.push(BigInt((await staking.call('getUserInfo', [users[i].hex]))[0]));
    const p0 = await probe(w);
    chain.warp(300n * DAY); chain.mine(11);
    // touch every borrower repeatedly: a position swept twice must not be charged twice
    for (let k = 0; k < 3; k++) for (let i = 1; i <= 3; i++) await staking.send(users[i], 'repay', [1n]);
    let charged = 0n;
    for (let i = 1; i <= 3; i++) charged += col0[i - 1] - BigInt((await staking.call('getUserInfo', [users[i].hex]))[0]);
    const p1 = await probe(w);
    const globalDrop = p0.totalStaked - p1.totalStaked;
    console.log(`     attributed to borrowers ${fmt(charged)} | global totalStaked drop ${fmt(globalDrop)}`);
    const diff = charged > globalDrop ? charged - globalDrop : globalDrop - charged;
    check(diff <= E18(2), 'ADVERSARIAL: per-borrower attribution matches the global reduction',
          `attributed ${fmt(charged)} vs global ${fmt(globalDrop)} (Δ ${fmt(diff)})`);
    check(p1.solvencyResidual <= DUST, 'ADVERSARIAL: repeated sweeps keep the identity',
          `residual ${p1.solvencyResidual}`);
  }

  console.log('\n── ADVERSARIAL :: no phantom collateral, exits always clear ────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    await staking.send(users[0], 'deposit', [E18(20_000_000), 90]);   // debt-free
    await staking.send(users[1], 'deposit', [E18(10_000_000), 365]); chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[1].hex]);
    await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
    chain.warp(400n * DAY); chain.mine(11);                           // lock lapsed, interest piled up
    const mine = BigInt((await staking.call('getUserInfo', [users[0].hex]))[0]);
    const ts = BigInt(await staking.call('totalStaked'));
    console.log(`     debt-free balance ${fmt(mine)} vs totalStaked ${fmt(ts)}`);
    check(ts >= mine, 'ADVERSARIAL: totalStaked never falls below a single honest balance',
          `totalStaked ${fmt(ts)} < balance ${fmt(mine)} would DoS the exit`);
    const r = await staking.send(users[0], 'withdraw', [mine]);
    check(r.ok, 'ADVERSARIAL: an untouched debt-free staker can always withdraw in full',
          `withdraw reverted with ${r.revert}`);
  }

  console.log('\n── ADVERSARIAL :: JIT entering ahead of someone ELSE\'s transaction ────────');
  {
    // Harder than the self-triggered case: the newcomer does not drive the realisation at all.
    const w = await world();
    const { staking, chain, users } = w;
    await staking.send(users[0], 'deposit', [E18(15_000_000), 365]);
    await staking.send(users[1], 'deposit', [E18(10_000_000), 365]); chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[1].hex]);
    await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
    chain.warp(60n * DAY); chain.mine(11);
    await staking.send(users[4], 'deposit', [E18(30_000_000), 90]);   // JIT enters, drives nothing
    const jitAtEntry = BigInt(await staking.call('pendingPureYield', [users[4].hex]));
    await staking.send(users[2], 'deposit', [E18(1_000), 90]);        // SOMEONE ELSE realises
    const jitAfter = BigInt(await staking.call('pendingPureYield', [users[4].hex]));
    console.log(`     JIT pending at entry ${fmt(jitAtEntry)} → after a third party's tx ${fmt(jitAfter)}`);
    check(jitAtEntry === 0n, 'ADVERSARIAL: a newcomer holds zero historical yield on entry',
          `held ${fmt(jitAtEntry)}`);
    check(jitAfter < E18(1), 'ADVERSARIAL: a third-party transaction cannot back-pay the newcomer',
          `newcomer gained ${fmt(jitAfter)} from a window it was absent for`);
  }

  console.log('\n── ADVERSARIAL :: direct token donation ────────────────────────────────────');
  {
    const w = await world();
    const { staking, token, users, admin } = w;
    await staking.send(users[0], 'deposit', [E18(5_000_000), 365]);
    const p0 = await probe(w);
    await token.send(admin, 'transfer', [staking.addr.toString(), E18(1_000_000)]);
    const p1 = await probe(w);
    console.log(`     donated 1,000,000 → backing ${fmt(p0.backing)}→${fmt(p1.backing)}, owed ${fmt(p0.owed)}→${fmt(p1.owed)}`);
    check(p1.owed === p0.owed, 'ADVERSARIAL: a donation does not inflate what the protocol owes',
          `owed moved by ${fmt(p1.owed - p0.owed)}`);
    check(p1.solvencyResidual < p0.solvencyResidual || p1.solvencyResidual <= 0n,
          'ADVERSARIAL: a donation can only improve the solvency margin');
    const stillOk = await staking.send(users[0], 'claimRewards', []);
    check(stillOk.ok, 'ADVERSARIAL: the protocol keeps working after an unsolicited transfer',
          `reverted with ${stillOk.revert}`);
  }

  console.log('\n── MOCK :: circuit breaker ─────────────────────────────────────────────────');
  {
    const w = await world();
    const { staking, users } = w;
    await staking.send(users[0], 'deposit', [E18(1_000_000), 90]);
    const trip = await staking.send(users[1], 'tripBreaker', []);
    check(!trip.ok && trip.revert === 'Staking__NoBreach',
          'MOCK: tripBreaker refuses to fire while the protocol is solvent', `got ${trip.revert}`);
    check(await staking.call('isSolvent') === true, 'MOCK: isSolvent() true on a healthy book');
    check(BigInt(await staking.call('auditInvariants')) === 0n, 'MOCK: audit bitmap clean');
  }

  console.log('\n── MOCK :: liquidation mechanics ───────────────────────────────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    await staking.send(users[0], 'deposit', [E18(20_000_000), 365]);
    await staking.send(users[1], 'deposit', [E18(1_000_000), 90]);
    chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[1].hex]);
    await staking.send(users[1], 'borrow', [BigInt(inf[3])]);

    const early = await staking.send(users[2], 'liquidate', [users[1].hex]);
    check(!early.ok && early.revert === 'Staking__NotLiquidatable',
          'MOCK: a healthy position cannot be liquidated', `got ${early.revert}`);
    const health = BigInt((await staking.call('getUserInfo', [users[1].hex]))[4]);
    check(health > 0n, 'MOCK: healthFactor is positive on a healthy position', `health=${health}`);
    const days = BigInt(await staking.call('daysToLiquidation', [users[1].hex]));
    console.log(`     daysToLiquidation on a 50% LTV position: ${days}`);
    check(days > 0n, 'MOCK: daysToLiquidation is finite and positive', `got ${days}`);
    const noPos = await staking.send(users[2], 'liquidate', [users[4].hex]);
    check(!noPos.ok, 'MOCK: liquidating an empty position reverts', `got ok=${noPos.ok}`);
  }

  console.log('\n── MOCK :: emission window countdown ───────────────────────────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    check(BigInt(await staking.call('maxLockDaysAvailable')) === 2555n,
          'MOCK: full lock length available at genesis');
    const tooLong = await staking.send(users[0], 'deposit', [E18(1_000), 2556]);
    check(!tooLong.ok && tooLong.revert === 'Staking__LockTooLong', 'MOCK: lock above MAX reverts',
          `got ${tooLong.revert}`);
    const tooShort = await staking.send(users[0], 'deposit', [E18(1_000), 89]);
    check(!tooShort.ok && tooShort.revert === 'Staking__LockTooShort', 'MOCK: lock below MIN reverts',
          `got ${tooShort.revert}`);

    chain.warp(1000n * DAY); chain.mine(11);
    const maxNow = BigInt(await staking.call('maxLockDaysAvailable'));
    check(maxNow === 1555n, 'MOCK: available lock length counts down with the emission clock',
          `got ${maxNow}`);
    const past = await staking.send(users[0], 'deposit', [E18(1_000), maxNow + 1n]);
    check(!past.ok && past.revert === 'Staking__LockExceedsEmissionEnd',
          'MOCK: a lock cannot extend past emissionEnd', `got ${past.revert}`);

    chain.warp(7n * YEAR); chain.mine(11);
    const ended = await staking.send(users[0], 'deposit', [E18(1_000), 90]);
    check(!ended.ok && ended.revert === 'Staking__EmissionEnded',
          'MOCK: deposits close once the emission programme ends', `got ${ended.revert}`);
  }

  console.log('\n── MOCK :: pro-rata fairness among identical positions ─────────────────────');
  {
    const w = await world();
    const { staking, chain, users } = w;
    for (let i = 0; i < 4; i++) await staking.send(users[i], 'deposit', [E18(5_000_000), 365]);
    chain.warp(120n * DAY); chain.mine(11);
    const pend = [];
    for (let i = 0; i < 4; i++) pend.push(BigInt(await staking.call('pendingRewards', [users[i].hex])));
    const lo = pend.reduce((a, b) => (a < b ? a : b)), hi = pend.reduce((a, b) => (a > b ? a : b));
    const spreadBps = lo === 0n ? 10_000n : ((hi - lo) * 10_000n) / lo;
    console.log(`     four identical stakers: min ${fmt(lo)} max ${fmt(hi)} (spread ${Number(spreadBps) / 100}%)`);
    check(spreadBps <= 1n, 'MOCK: identical simultaneous positions accrue identically',
          `spread ${Number(spreadBps) / 100}%`);

    // double weight ⇒ double share
    const w2 = await world();
    await w2.staking.send(w2.users[0], 'deposit', [E18(2_000_000), 365]);
    await w2.staking.send(w2.users[1], 'deposit', [E18(1_000_000), 365]);
    w2.chain.warp(120n * DAY); w2.chain.mine(11);
    const big = BigInt(await w2.staking.call('pendingRewards', [w2.users[0].hex]));
    const small = BigInt(await w2.staking.call('pendingRewards', [w2.users[1].hex]));
    const ratio = small === 0n ? 0n : (big * 1000n) / small;
    check(ratio >= 1995n && ratio <= 2005n, 'MOCK: reward share is linear in stake',
          `ratio ${Number(ratio) / 1000}x`);
  }

  console.log('\n── MOCK :: self-only maintenance entry points ──────────────────────────────');
  {
    const w = await world();
    const { staking, users } = w;
    await staking.send(users[0], 'deposit', [E18(1_000_000), 90]);
    const m = await staking.send(users[1], 'maintStep', [users[0].hex, users[1].hex]);
    check(!m.ok && m.revert === 'Staking__NotSelf', 'MOCK: maintStep is not externally callable',
          `got ${m.revert}`);
    const l = await staking.send(users[1], 'lockStep', [users[0].hex, users[1].hex]);
    check(!l.ok && l.revert === 'Staking__NotSelf', 'MOCK: lockStep is not externally callable',
          `got ${l.revert}`);
  }

  console.log('\n── MOCK :: zero-amount and empty-position guards ───────────────────────────');
  {
    const w = await world();
    const { staking, users } = w;
    const cases = [
      ['deposit', [0n, 90], 'Staking__ZeroAmount'],
      ['withdraw', [0n], 'Staking__ZeroAmount'],
      ['borrow', [0n], 'Staking__ZeroAmount'],
      ['repay', [0n], 'Staking__ZeroAmount'],
    ];
    let allOk = true;
    for (const [fn, args, want] of cases) {
      const r = await staking.send(users[0], fn, args);
      if (r.ok || r.revert !== want) { allOk = false; console.log(`     ${fn} → ${r.revert} (want ${want})`); }
    }
    check(allOk, 'MOCK: every zero-amount entry point reverts with ZeroAmount');
    const noStake = await staking.send(users[0], 'withdraw', [E18(1)]);
    check(!noStake.ok, 'MOCK: withdrawing from an empty position reverts', `got ok=${noStake.ok}`);
    const claimEmpty = await staking.send(users[0], 'claimRewards', []);
    check(claimEmpty.ok, 'MOCK: claiming on an empty position is a harmless no-op', `got ${claimEmpty.revert}`);
  }
}

// ════════════════════════════════════════════════════════════════════════════════════════
//  LAYER 3 — STATISTICAL SCALING
//  The discriminator between ROUNDING DUST and a REAL LEAK is the scaling exponent.
//    dust : residual = O(1) wei per operation, INDEPENDENT of capital and elapsed time  ⇒ β≈0
//    leak : residual ∝ capital × Δt                                                     ⇒ β≈1
//  We sweep capital and time over decades and fit  log(residual) = α + β·log(x)
//  by ordinary least squares. β is the verdict; no threshold guessing required.
// ════════════════════════════════════════════════════════════════════════════════════════
function ols(xs, ys) {
  const n = xs.length;
  const mx = xs.reduce((a, b) => a + b, 0) / n, my = ys.reduce((a, b) => a + b, 0) / n;
  let num = 0, den = 0;
  for (let i = 0; i < n; i++) { num += (xs[i] - mx) * (ys[i] - my); den += (xs[i] - mx) ** 2; }
  const beta = den === 0 ? 0 : num / den;
  const alpha = my - beta * mx;
  let ssTot = 0, ssRes = 0;
  for (let i = 0; i < n; i++) { const p = alpha + beta * xs[i]; ssRes += (ys[i] - p) ** 2; ssTot += (ys[i] - my) ** 2; }
  return { beta, alpha, r2: ssTot === 0 ? 1 : 1 - ssRes / ssTot };
}

async function scalingStudy() {
  console.log('\n── LAYER 3 :: scaling exponents (β≈0 ⇒ rounding dust, β≈1 ⇒ real leak) ─────');

  // (a) MR-DRIVER overcharge vs elapsed backlog time
  const timePts = [15n, 30n, 60n, 120n, 240n];
  const xsT = [], ysT = [];
  for (const d of timePts) {
    const base = await stagedWorld({ borrowers: 2, idleDays: d, lever: true });
    const b0 = [await collateralOf(base, 1), await collateralOf(base, 2)];
    await base.staking.send(base.users[0], 'claimRewards', []);
    const ordinary = (b0[0] - (await collateralOf(base, 1))) + (b0[1] - (await collateralOf(base, 2)));

    const atk = await stagedWorld({ borrowers: 2, idleDays: d, lever: true });
    const a0 = [await collateralOf(atk, 1), await collateralOf(atk, 2)];
    const inf = await atk.staking.call('getUserInfo', [atk.users[5].hex]);
    await atk.staking.send(atk.users[5], 'borrow', [(BigInt(inf[3]) * 99n) / 100n]);
    const attacked = (a0[0] - (await collateralOf(atk, 1))) + (a0[1] - (await collateralOf(atk, 2)));

    const excess = attacked > ordinary ? attacked - ordinary : 0n;
    console.log(`     backlog ${String(d).padStart(4)}d : ordinary ${fmt(ordinary)} | attacked ${fmt(attacked)} | excess ${fmt(excess)}`);
    // Guard the log: `excess > 0` does not imply `excess / 1e12 > 0`, and a floored zero would
    // feed -Infinity straight into the fit, turning the check below into a meaningless verdict.
    const scaled = excess / 10n ** 12n;
    if (scaled > 0n) { xsT.push(Math.log(Number(d))); ysT.push(Math.log(Number(scaled))); }
  }
  if (xsT.length === 0) {
    check(true, 'SCALING: driver-overcharge is unmeasurable at every backlog length (excess is zero)');
  } else if (xsT.length >= 3) {
    const f = ols(xsT, ysT);
    console.log(`     ⇒ excess ∝ Δt^${f.beta.toFixed(3)}   (R²=${f.r2.toFixed(4)})`);
    check(Math.abs(f.beta) < 0.15, 'SCALING: driver-overcharge does not grow with elapsed time',
          `β = ${f.beta.toFixed(3)} (R²=${f.r2.toFixed(4)}) — grows linearly with the backlog, so it is a leak, not rounding`);
  }

  // (b) emission stranding vs empty-window length
  const xsE = [], ysE = [];
  for (const d of [1n, 3n, 10n, 30n, 90n]) {
    const w = await world();
    w.chain.warp(d * DAY); w.chain.mine(5);
    await w.staking.send(w.users[0], 'deposit', [E18(1_000_000), 365]);
    const p = await probe(w);
    console.log(`     empty ${String(d).padStart(3)}d : stranded ${fmt(p.stranded)}`);
    const scaledE = p.stranded / 10n ** 12n;
    if (!check(scaledE > 0n, `SCALING: stranding is measurable at ${d}d`, `stranded=${p.stranded}`)) continue;
    xsE.push(Math.log(Number(d))); ysE.push(Math.log(Number(scaledE)));
  }
  const fe = ols(xsE, ysE);
  console.log(`     ⇒ stranded ∝ Δt^${fe.beta.toFixed(3)}   (R²=${fe.r2.toFixed(4)})  [linear BY DESIGN]`);
  check(fe.beta > 0.95 && fe.beta < 1.05 && fe.r2 > 0.999,
        'SCALING: empty-window emission is skipped deterministically at exactly REWARD_PER_SEC',
        `β = ${fe.beta.toFixed(3)} (R²=${fe.r2.toFixed(4)}) — expected exactly 1.000`);

  // (c) CONTROL — the solvency residual under a clean, continuously-populated timeline.
  //     If the harness itself leaked, this would scale too. It must stay flat at dust level.
  const xsC = [], ysC = [];
  for (const mult of [1n, 10n, 100n, 1000n]) {
    const w = await world();
    await w.staking.send(w.users[0], 'deposit', [E18(1000) * mult, 365]);
    w.chain.mine(11);
    for (let k = 0; k < 4; k++) { w.chain.warp(30n * DAY); w.chain.mine(11); await w.staking.send(w.users[0], 'claimRewards', []); }
    const p = await probe(w);
    const resid = p.solvencyResidual < 0n ? -p.solvencyResidual : p.solvencyResidual;
    console.log(`     capital ×${String(mult).padStart(4)} : |backing−owed| = ${resid} wei`);
    xsC.push(Math.log(Number(mult))); ysC.push(Math.log(Number(resid === 0n ? 1n : resid)));
  }
  const fc = ols(xsC, ysC);
  console.log(`     ⇒ |backing−owed| ∝ capital^${fc.beta.toFixed(3)}   (R²=${fc.r2.toFixed(4)})`);
  check(Math.abs(fc.beta) < 0.2, 'SCALING [CONTROL]: conservation residual is capital-independent dust',
        `β = ${fc.beta.toFixed(3)}`);
}

// ════════════════════════════════════════════════════════════════════════════════════════
//  MAIN
// ════════════════════════════════════════════════════════════════════════════════════════
console.log('════════════════════════════════════════════════════════════════════════════');
console.log('  BLAZEPHOENIX STAKING — META CAMPAIGN');
console.log('  invariants · metamorphic relations · statistical scaling');
console.log('════════════════════════════════════════════════════════════════════════════');

const mr = {};
mr.driver = await MR_driver();
mr.add = await MR_additivity();
mr.jit = await MR_jit();
mr.boost = await MR_boost();
mr.rateCurve = await rateCurveReach();
mr.stale = await MR_stale();
mr.closure = await exitClosure();
mr.emission = await MR_emission();

await mockScenarios();
await scalingStudy();

console.log('\n── LAYER 1 :: stateful randomised campaign ─────────────────────────────────');
const seeds = [0xB1A2E, 0x5EED01, 0xC0FFEE];
for (const s of seeds) {
  const st = await fuzzCampaign(s, 90);
  console.log(`  seed 0x${s.toString(16)} : ${st.txOk} ok / ${st.txRevert} reverted`);
  console.log(`     max solvency residual (owed−backing) : ${st.maxSolvencyResidual} wei`);
  console.log(`     max stranded emission                : ${fmt(st.maxStranded)}`);
  console.log(`     max stale boost weight (effective)   : ${fmt(st.maxStaleBE)}`);
  console.log(`     max stale boost weight (pure)        : ${fmt(st.maxStaleBP)}`);
  console.log(`     audit bitmap (OR over all states)    : ${st.auditViolations}`);
  check(st.maxSolvencyResidual <= DUST, `FUZZ[0x${s.toString(16)}]: solvency held in every reachable state`,
        `max residual ${st.maxSolvencyResidual} wei`);
  check(st.auditViolations === 0n, `FUZZ[0x${s.toString(16)}]: auditInvariants() clean in every state`,
        `bitmap ${st.auditViolations}`);
}

console.log('\n════════════════════════════════════════════════════════════════════════════');
console.log(`  ${PASS} properties held, ${FAIL} violated`);
if (FINDINGS.length) {
  console.log('\n  VIOLATED PROPERTIES:');
  for (const f of FINDINGS) console.log(`   ✗ ${f.label}\n       ${f.detail}`);
}
console.log('════════════════════════════════════════════════════════════════════════════');
if (FAIL > 0) process.exitCode = 1;   // a violated property must fail the process, not just print
