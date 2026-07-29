// ════════════════════════════════════════════════════════════════════════════════════════
//  BlazePhoenix Staking — reporting-surface and deployment-environment suite
//
//    node test/reporting.mjs
//
//  Two dimensions the value and time suites cannot reach.
//
//  The protocol offers `owed()`, `backing()`, `collateralRatio()`, `solvency()` and
//  `auditInvariants()` as trustless verification. Every other guarantee is checked THROUGH
//  those numbers, so a defect that corrupts the instrument rather than the value is invisible
//  to all of them — the books can balance while the report of the books does not. Section R
//  rebuilds every published figure from primitive state and compares.
//
//  Section B covers what the contract assumes about the world it is deployed into: a funding
//  gap at genesis, a chain that goes quiet for years, and the exact boundary of the schedule.
// ════════════════════════════════════════════════════════════════════════════════════════
import { compileAll } from './compile.mjs';
import { Chain, E18 } from './lib.mjs';
import { ethers } from 'ethers';

const DAY = 86400n, YEAR = 365n * DAY, MAX_UINT = (1n << 256n) - 1n;
const WAD = 10n ** 18n, DUST = 10n ** 10n;
const art = compileAll();

let PASS = 0, FAIL = 0; const F = [];
const check = (c, l, d = '') => { if (c) { PASS++; console.log(`  ✓ ${l}`); } else { FAIL++; F.push({ l, d }); console.log(`  ✗ ${l}${d ? '  ::  ' + d : ''}`); } return c; };
const fmt = (x) => (Number(x) / 1e18).toFixed(6);

async function world({ fund = true } = {}) {
  const chain = await Chain.create();
  const admin = await chain.fund('admin', '0x' + '11'.repeat(32));
  const treasury = await chain.fund('treasury', '0x' + '66'.repeat(32));
  const guardian = await chain.fund('guardian', '0x' + '77'.repeat(32));
  const users = [];
  for (let i = 0; i < 6; i++) users.push(await chain.fund('u' + i, '0x' + (20 + i).toString(16).padStart(2, '0').repeat(32)));
  const tk = await chain.deploy(art.Token, admin);
  const st = await chain.deploy(art.Staking, admin, [tk.addr.toString(), treasury.hex]);
  for (const u of [admin, ...users]) {
    await tk.send(admin, 'mint', [u.hex, E18(500_000_000)]);
    await tk.send(u, 'approve', [st.addr.toString(), MAX_UINT]);
  }
  await st.send(admin, 'grantRole', [ethers.id('GUARDIAN_ROLE'), guardian.hex]);
  if (fund) await st.send(admin, 'fundEmission', [E18(180_000_000)]);
  return { chain, token: tk, staking: st, admin, treasury, guardian, users };
}

// Rebuild every published number from primitive state, independently of the view that reports it.
async function reconstruct(w) {
  const s = w.staking;
  const g = async (n) => BigInt(await s.call(n));
  const [ts, td, rr, pr, trd, trp, tbd] = await Promise.all(
    ['totalStaked', 'totalDebt', 'rewardReserve', 'protocolReserve',
     'totalRewardDistributed', 'totalRewardsPaid', 'totalBadDebt'].map(g));
  const ledgerSum = ts + rr + pr;
  const ledgerNet = ledgerSum > td ? ledgerSum - td : 0n;
  const acc = trd > trp ? trd - trp : 0n;
  let owed = ledgerNet + acc;
  owed = owed > tbd ? owed - tbd : 0n;
  const backing = BigInt(await w.token.call('balanceOf', [s.addr.toString()]));
  return { owed, backing, ts, td, rr, pr, trd, trp, tbd };
}

console.log('════════════════════════════════════════════════════════════════════════════');
console.log('  REPORTING SURFACE  ·  DEPLOYMENT ENVIRONMENT');
console.log('════════════════════════════════════════════════════════════════════════════');

// ══ R · THE REPORTING SURFACE MUST NOT LIE ═════════════════════════════════════════════
console.log('\n── R1 :: published figures vs an independent reconstruction ───────────────');
{
  const w = await world();
  const { chain, staking, users, admin, guardian } = w;
  // drive the book through every state-changing path so the comparison is not made on a
  // freshly-deployed contract where everything is trivially zero
  await staking.send(users[0], 'deposit', [E18(20_000_000), 365]);
  await staking.send(users[1], 'deposit', [E18(10_000_000), 730]); chain.mine(11);
  const inf = await staking.call('getUserInfo', [users[1].hex]);
  await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
  await staking.send(users[2], 'deposit', [E18(5_000_000), 90]);

  let worstOwed = 0n, worstRatio = 0n, steps = 0;
  for (let k = 0; k < 12; k++) {
    chain.warp(BigInt(1 + (k * 6421) % 90) * DAY); chain.mine(1 + k);
    await staking.send(users[k % 3], 'claimRewards', []);
    if (k === 4) await staking.send(users[1], 'repay', [E18(100_000)]);
    if (k === 7) await staking.send(users[2], 'lock', [1825]);
    if (k === 9) await staking.send(admin, 'withdrawReserve', [MAX_UINT]);

    const r = await reconstruct(w);
    const owedView = BigInt(await staking.call('owed'));
    const backView = BigInt(await staking.call('backing'));
    const d1 = owedView > r.owed ? owedView - r.owed : r.owed - owedView;
    if (d1 > worstOwed) worstOwed = d1;
    check(backView === r.backing, `R1[${k}]: backing() equals the real token balance`, `${fmt(backView)} vs ${fmt(r.backing)}`);

    // collateralRatio must be reproducible from the same two numbers it publishes
    const ratioView = BigInt(await staking.call('collateralRatio'));
    const ratioCalc = r.owed === 0n ? ratioView : (r.backing * WAD) / r.owed;
    const d2 = ratioView > ratioCalc ? ratioView - ratioCalc : ratioCalc - ratioView;
    if (d2 > worstRatio) worstRatio = d2;
    steps++;
  }
  console.log(`     ${steps} irregular steps — worst |owed() − reconstructed| = ${worstOwed} wei`);
  console.log(`     worst |collateralRatio() − backing/owed| = ${worstRatio} wad-units`);
  check(worstOwed === 0n, 'R1: owed() is exactly reproducible from primitive state',
        `drifted by ${worstOwed} wei — the headline number cannot be independently verified`);
  check(worstRatio <= 1n, 'R1: collateralRatio() is consistent with what it publishes',
        `drifted by ${worstRatio}`);
}

console.log('\n── R2 :: solvency() agrees with every individual getter ───────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(15_000_000), 365]);
  await staking.send(users[1], 'deposit', [E18(8_000_000), 90]); chain.mine(11);
  const inf = await staking.call('getUserInfo', [users[1].hex]);
  await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
  chain.warp(400n * DAY); chain.mine(11);
  await staking.send(users[0], 'claimRewards', []);

  const rep = await staking.call('solvency');
  const r = await reconstruct(w);
  const pairs = [
    ['backing', BigInt(rep[0]), r.backing], ['owed', BigInt(rep[1]), r.owed],
    ['surplus', BigInt(rep[2]), r.backing > r.owed ? r.backing - r.owed : 0n],
    ['deficit', BigInt(rep[3]), r.owed > r.backing ? r.owed - r.backing : 0n],
    ['totalStaked', BigInt(rep[6]), r.ts], ['totalDebt', BigInt(rep[7]), r.td],
    ['rewardReserve', BigInt(rep[8]), r.rr], ['protocolReserve', BigInt(rep[9]), r.pr],
    ['pendingDistribution', BigInt(rep[10]), r.trd > r.trp ? r.trd - r.trp : 0n],
    ['totalBadDebt', BigInt(rep[11]), r.tbd],
  ];
  let allOk = true;
  for (const [n, got, want] of pairs) if (got !== want) { allOk = false; console.log(`     ${n}: report ${got} vs reconstructed ${want}`); }
  check(allOk, 'R2: every field of solvency() matches an independent reconstruction');
  check(rep[4] === (r.backing + DUST >= r.owed), 'R2: the solvent flag matches the definition it claims');
  check(BigInt(rep[2]) === 0n || BigInt(rep[3]) === 0n, 'R2: surplus and deficit are never both non-zero');
}

console.log('\n── R3 :: quoted entitlements are exactly what gets paid ───────────────────');
{
  const w = await world();
  const { chain, token, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(12_000_000), 365]);
  await staking.send(users[1], 'deposit', [E18(6_000_000), 730]); chain.mine(11);
  const inf = await staking.call('getUserInfo', [users[1].hex]);
  await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
  chain.warp(250n * DAY); chain.mine(11);

  let worst = 0n;
  for (const u of [users[0], users[1]]) {
    const quoted = BigInt(await staking.call('pendingRewards', [u.hex]));
    const quotedY = BigInt(await staking.call('pendingPureYield', [u.hex]));
    const b0 = BigInt(await token.call('balanceOf', [u.hex]));
    await staking.send(u, 'claimRewards', []);
    const paid = BigInt(await token.call('balanceOf', [u.hex])) - b0;
    const expect = quoted + quotedY;
    const d = paid > expect ? paid - expect : expect - paid;
    console.log(`     ${u.name}: quoted ${fmt(expect)}  paid ${fmt(paid)}  Δ ${d} wei`);
    if (d > worst) worst = d;
  }
  check(worst <= DUST, 'R3: the quote a user sees is the amount the contract pays',
        `worst divergence ${worst} wei — the UI number is not the settlement number`);
}

console.log('\n── R4 :: getUserInfo agrees with the standalone views ─────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(9_000_000), 1825]);
  await staking.send(users[1], 'deposit', [E18(4_000_000), 90]); chain.mine(11);
  const inf0 = await staking.call('getUserInfo', [users[1].hex]);
  await staking.send(users[1], 'borrow', [BigInt(inf0[3])]);
  chain.warp(120n * DAY); chain.mine(11);

  let allOk = true;
  for (const u of [users[0], users[1], users[4]]) {
    const i = await staking.call('getUserInfo', [u.hex]);
    const li = await staking.call('lockInfoOf', [u.hex]);
    const checks = [
      ['effectiveStake', BigInt(i[2]), BigInt(await staking.call('effectiveStakeOf', [u.hex]))],
      ['health', BigInt(i[4]), BigInt(await staking.call('healthFactor', [u.hex]))],
      ['maxBorrow', BigInt(i[3]), BigInt(await staking.call('maxBorrowOf', [u.hex]))],
      ['stakingRewards', BigInt(i[6]), BigInt(await staking.call('pendingRewards', [u.hex]))],
      ['pureYield', BigInt(i[7]), BigInt(await staking.call('pendingPureYield', [u.hex]))],
      ['rate', BigInt(i[8]), BigInt(await staking.call('currentInterestRateBps'))],
      ['lockDays', BigInt(i[9]), BigInt(li[0])],
      ['unlockTime', BigInt(i[10]), BigInt(li[1])],
      ['boostBps', BigInt(i[11]), BigInt(await staking.call('effectiveBoostOf', [u.hex]))],
      ['remainingCap', BigInt(i[12]), BigInt(await staking.call('remainingStakeCapacity', [u.hex]))],
      ['maxDaysNow', BigInt(i[13]), BigInt(await staking.call('maxLockDaysAvailable'))],
    ];
    for (const [n, a, b] of checks) if (a !== b) { allOk = false; console.log(`     ${u.name}.${n}: ${a} vs ${b}`); }
  }
  check(allOk, 'R4: the aggregate view and the standalone views never disagree');
}

console.log('\n── R5 :: the audit bitmap actually fires ──────────────────────────────────');
{
  // A health mask that never reports anything is worse than none: monitors would trust it.
  // Bit 1 flags a book whose debt has passed the liquidation threshold.
  const w = await world();
  const { chain, staking, users } = w;
  for (const u of users) await staking.send(u, 'deposit', [E18(10_000_000), 365]);
  chain.mine(11);
  for (const u of users) { const i = await staking.call('getUserInfo', [u.hex]); await staking.send(u, 'borrow', [BigInt(i[3])]); }
  await staking.send(w.guardian, 'pause', []);          // liquidation off, let the book rot
  let bitmap = 0n, yr = 0;
  for (let y = 1; y <= 40 && bitmap === 0n; y++) {
    chain.warp(YEAR); chain.mine(11);
    await staking.send(users[0], 'repay', [1n]);
    bitmap = BigInt(await staking.call('auditInvariants')); yr = y;
  }
  console.log(`     bitmap first became non-zero at year ${yr}: 0b${bitmap.toString(2).padStart(5, '0')}`);
  check(bitmap !== 0n, 'R5: the audit mask reports a genuinely unhealthy book',
        'the mask stayed clean through 40 years of a rotting, unliquidatable book');
  check((bitmap & 2n) !== 0n, 'R5: the threshold bit is the one that fires',
        `got 0b${bitmap.toString(2)}`);
  check(await staking.call('isSolvent') === true, 'R5: an unhealthy book is still reported as solvent (they are different claims)');
}

// ══ B · DEPLOYMENT AND ENVIRONMENT ASSUMPTIONS ═════════════════════════════════════════
console.log('\n── B1 :: the gap between deployment and funding ───────────────────────────');
{
  const w = await world({ fund: false });
  const { chain, staking, admin, users } = w;
  const r0 = await reconstruct(w);
  check(r0.owed === 0n && r0.backing === 0n, 'B1: a deployed but unfunded contract owes nothing and holds nothing');
  const dep = await staking.send(users[0], 'deposit', [E18(5_000_000), 365]);
  check(dep.ok, 'B1: staking is possible before emission is funded', `reverted ${dep.revert}`);
  chain.warp(120n * DAY); chain.mine(11);
  const pend = BigInt(await staking.call('pendingRewards', [users[0].hex]));
  console.log(`     120 days staked into an unfunded contract → pending ${fmt(pend)}`);
  check(pend === 0n, 'B1: an unfunded contract cannot accrue a reward liability it cannot pay',
        `it promised ${fmt(pend)} with nothing behind it`);
  await staking.send(admin, 'fundEmission', [E18(180_000_000)]);
  const after = BigInt(await staking.call('pendingRewards', [users[0].hex]));
  check(after === 0n, 'B1: funding later does not retroactively pay the unfunded window',
        `funding created ${fmt(after)} of backdated entitlement`);
  check(await staking.call('isSolvent') === true, 'B1: solvency intact across the funding boundary');
}

console.log('\n── B2 :: a chain that goes quiet for years ────────────────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(10_000_000), 2555]);
  await staking.send(users[1], 'deposit', [E18(10_000_000), 2555]); chain.mine(11);
  const inf = await staking.call('getUserInfo', [users[1].hex]);
  await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
  chain.warp(5n * YEAR); chain.mine(2);                  // no transactions at all for five years
  const r = await staking.send(users[0], 'claimRewards', []);
  console.log(`     first transaction after a five-year silence → ${r.ok ? 'ok' : r.revert}`);
  check(r.ok, 'B2: the first transaction after a long silence still succeeds', `reverted ${r.revert}`);
  check(await staking.call('isSolvent') === true, 'B2: solvency intact after a five-year gap');
  check(BigInt(await staking.call('auditInvariants')) === 0n, 'B2: audit mask clean after a five-year gap');
}

console.log('\n── B3 :: the exact edge of the emission schedule ──────────────────────────');
{
  const w = await world();
  const { chain, staking, admin, users } = w;
  await staking.send(users[0], 'deposit', [E18(10_000_000), 2555]);
  const end = BigInt(await staking.call('emissionEnd'));
  chain.warp(end - chain.time - 1n); chain.mine(11);     // one second before the end
  const justBefore = await staking.send(users[1], 'deposit', [E18(1_000), 90]);
  console.log(`     deposit one second before emissionEnd → ${justBefore.ok ? 'ok' : justBefore.revert}`);
  chain.warp(2n); chain.mine(2);                          // one second after
  const justAfter = await staking.send(users[2], 'deposit', [E18(1_000), 90]);
  check(!justAfter.ok && justAfter.revert === 'Staking__EmissionEnded',
        'B3: the schedule closes exactly at emissionEnd', `got ${justAfter.revert}`);
  const claim = await staking.send(users[0], 'claimRewards', []);
  check(claim.ok, 'B3: existing positions can still be settled after the end', `reverted ${claim.revert}`);
  const sweep = await staking.send(admin, 'sweepUndistributedEmission', []);
  const left = BigInt(await staking.call('rewardReserve'));
  console.log(`     post-schedule sweep → ${sweep.ok ? 'ok' : sweep.revert}; rewardReserve left ${fmt(left)}`);
  check(await staking.call('isSolvent') === true, 'B3: solvency intact across the boundary');
}

console.log('\n── B4 :: a legitimate small launch is not blocked ─────────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  const small = await staking.send(users[0], 'deposit', [E18(2_000), 365]);   // modest but real
  chain.warp(60n * DAY); chain.mine(11);
  const pend = BigInt(await staking.call('pendingRewards', [users[0].hex]));
  console.log(`     a 2,000 BZPX launch accrues ${fmt(pend)} over 60 days`);
  check(small.ok && pend > 0n, 'B4: a genuine small pool still earns — the floor only excludes dust',
        `a legitimate launch would be frozen out`);
}

console.log('\n════════════════════════════════════════════════════════════════════════════');
console.log(`  ${PASS} checks passed, ${FAIL} failed`);
if (F.length) { console.log('\n  FAILED:'); F.forEach(x => console.log(`   ✗ ${x.l}\n       ${x.d}`)); }
console.log('════════════════════════════════════════════════════════════════════════════');
