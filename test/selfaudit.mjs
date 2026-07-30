// ════════════════════════════════════════════════════════════════════════════════════════
//  BlazePhoenix Staking — regression against our own remediations
//
//    node test/selfaudit.mjs
//
//  Every fix is a state change, and a state change deserves the same scrutiny as the code it
//  replaced. One disclosed finding was a hole opened by the remediation of an earlier one, so
//  this suite treats each remediation as a suspect and attacks the surface it introduced.
// ════════════════════════════════════════════════════════════════════════════════════════
import { compileAll } from './compile.mjs';
import { Chain, E18 } from './lib.mjs';
import { ethers } from 'ethers';

const DAY = 86400n, YEAR = 365n * DAY, MAX_UINT = (1n << 256n) - 1n;
const DUST = 10n ** 10n;
const art = compileAll();

let PASS = 0, FAIL = 0; const F = [];
const check = (c, l, d = '') => { if (c) { PASS++; console.log(`  ✓ ${l}`); } else { FAIL++; F.push({ l, d }); console.log(`  ✗ ${l}${d ? '  ::  ' + d : ''}`); } return c; };
const fmt = (x) => (Number(x) / 1e18).toFixed(6);

async function world({ fund = true, actors = 6 } = {}) {
  const chain = await Chain.create();
  const admin = await chain.fund('admin', '0x' + '11'.repeat(32));
  const treasury = await chain.fund('treasury', '0x' + '66'.repeat(32));
  const guardian = await chain.fund('guardian', '0x' + '77'.repeat(32));
  const users = [];
  for (let i = 0; i < actors; i++) users.push(await chain.fund('u' + i, '0x' + (20 + i).toString(16).padStart(2, '0').repeat(32)));
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
const solvent = (st) => st.call('isSolvent');

console.log('════════════════════════════════════════════════════════════════════════════');
console.log('  REGRESSION AGAINST OUR OWN REMEDIATIONS');
console.log('════════════════════════════════════════════════════════════════════════════');

// ── S1 · FULL DRAIN ─────────────────────────────────────────────────────────────────────
//  Interest is now taken from the global total in one step and attributed to positions lazily,
//  so `totalStaked` and the sum of individual balances are not equal between touches. If the
//  global figure can fall below the sum of what positions still believe they hold, the last
//  exits would underflow and the protocol would strand everybody's principal.
console.log('\n── S1 :: can the protocol be fully drained? ────────────────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  for (const u of users) await staking.send(u, 'deposit', [E18(5_000_000), 90]);
  chain.mine(11);
  for (let i = 1; i < users.length; i++) {
    const inf = await staking.call('getUserInfo', [users[i].hex]);
    await staking.send(users[i], 'borrow', [BigInt(inf[3])]);
  }
  chain.warp(400n * DAY); chain.mine(11);                       // interest accrues, locks lapse

  // everyone repays, then everyone withdraws everything they still hold
  for (let i = 1; i < users.length; i++) { await staking.send(users[i], 'repay', [MAX_UINT]); chain.mine(11); }
  let allOut = true, lastErr = '';
  for (const u of users) {
    chain.mine(11);
    const bal = BigInt((await staking.call('getUserInfo', [u.hex]))[0]);
    if (bal === 0n) continue;
    const r = await staking.send(u, 'withdraw', [bal]);
    if (!r.ok) { allOut = false; lastErr = `${u.name}: ${r.revert}`; }
  }
  const ts = BigInt(await staking.call('totalStaked'));
  const sum = (await Promise.all(users.map(async (u) => BigInt((await staking.call('getUserInfo', [u.hex]))[0]))))
    .reduce((a, b) => a + b, 0n);
  console.log(`     after every position exits: totalStaked=${fmt(ts)}  sum of balances=${fmt(sum)}`);
  check(allOut, 'S1: every position can exit in full', lastErr);
  check(ts === sum, 'S1: the global total lands exactly on the sum of what remains',
        `totalStaked ${fmt(ts)} vs sum ${fmt(sum)} — the lazy attribution left a residue`);
  check(await solvent(staking) === true, 'S1: solvency intact after a full drain');
}

// ── S2 · THE EMISSION FLOOR AS A GRIEFING SURFACE ───────────────────────────────────────
//  The floor stops a dust pool absorbing the schedule. It also means a large holder leaving can
//  push total weight under it — which would stop emission for everyone still staked.
console.log('\n── S2 :: can a large exit starve the remaining stakers? ────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  const whale = users[0], small = users[1];
  await staking.send(whale, 'deposit', [E18(20_000_000), 90]);
  await staking.send(small, 'deposit', [E18(500), 90]);          // below the floor on its own
  chain.warp(91n * DAY); chain.mine(11);
  const before = BigInt(await staking.call('pendingRewards', [small.hex]));
  await staking.send(whale, 'withdraw', [E18(20_000_000)]);      // whale leaves entirely
  const weight = BigInt(await staking.call('totalBoostedEffective'));
  const floor = BigInt(await staking.call('MIN_EMISSION_WEIGHT'));
  chain.warp(60n * DAY); chain.mine(11);
  const after = BigInt(await staking.call('pendingRewards', [small.hex]));
  console.log(`     after the whale exits: total weight ${fmt(weight)} vs floor ${fmt(floor)}`);
  console.log(`     small staker pending: ${fmt(before)} → ${fmt(after)} over the next 60 days`);
  check(weight < floor, 'S2: precondition — the exit did push the pool under the floor');
  check(after > before, 'S2: a sub-floor pool still accrues for the stakers left in it',
        `emission stopped for everyone remaining — a large exit is a griefing lever`);
  console.log(`     accrued over those 60 days: ${fmt(after - before)}`);
  check(await solvent(staking) === true, 'S2: solvency intact');
}

// ── S3 · CLAIMS AFTER THE RESIDUE SWEEP ─────────────────────────────────────────────────
//  The sweep zeroes `rewardReserve`. Entitlements already credited live in the accumulator and
//  are backed by balance rather than by the reserve — but if that is wrong, the sweep would take
//  money that stakers are still owed.
console.log('\n── S3 :: can everyone still be paid after the residue is swept? ───────────');
{
  const w = await world();
  const { chain, token, staking, admin, users } = w;
  chain.warp(20n * DAY); chain.mine(5);                          // empty window -> residue forms
  for (const u of users) await staking.send(u, 'deposit', [E18(5_000_000), 365]);
  chain.warp(8n * YEAR); chain.mine(20);
  await staking.send(users[0], 'claimRewards', []);              // settle to the schedule end

  const quoted = await Promise.all(users.map(async (u) => BigInt(await staking.call('pendingRewards', [u.hex]))));
  const sweep = await staking.send(admin, 'sweepUndistributedEmission', []);
  console.log(`     sweep → ${sweep.ok ? 'ok' : sweep.revert}; rewardReserve now ${fmt(BigInt(await staking.call('rewardReserve')))}`);

  // A position can be settled by SOMEBODY ELSE's transaction via the maintenance sweep, so the
  // payment must be measured across the whole round rather than across each position's own call.
  const pre = await Promise.all(users.map(async (u) => BigInt(await token.call('balanceOf', [u.hex]))));
  let allPaid = true;
  for (const u of users) { const r = await staking.send(u, 'claimRewards', []); if (!r.ok) allPaid = false; }
  const post = await Promise.all(users.map(async (u) => BigInt(await token.call('balanceOf', [u.hex]))));
  const totalQuoted = quoted.reduce((a, b) => a + b, 0n);
  const totalPaid = post.reduce((a, b, i) => a + (b - pre[i]), 0n);
  const worst = totalQuoted > totalPaid ? totalQuoted - totalPaid : 0n;
  console.log(`     quoted in total ${fmt(totalQuoted)}, paid in total ${fmt(totalPaid)}`);
  check(allPaid, 'S3: every staker can still claim after the sweep');
  check(worst <= DUST, 'S3: the sweep took nothing that was still owed',
        `a staker was short by ${fmt(worst)} against what they were quoted before the sweep`);
  check(await solvent(staking) === true, 'S3: solvency intact after the sweep');
}

// ── S4 · LAZY ATTRIBUTION UNDER STRESS ──────────────────────────────────────────────────
//  The global figure moves on every accrual; positions catch up only when touched. Measure the
//  gap directly, and confirm it only ever runs in the safe direction.
console.log('\n── S4 :: how far can global and per-position accounting drift apart? ──────');
{
  const w = await world();
  const { chain, staking, users } = w;
  for (const u of users) await staking.send(u, 'deposit', [E18(8_000_000), 365]);
  chain.mine(11);
  for (let i = 1; i < users.length; i++) {
    const inf = await staking.call('getUserInfo', [users[i].hex]);
    await staking.send(users[i], 'borrow', [BigInt(inf[3])]);
  }
  let worstGap = 0n, wrongWay = false;
  for (let k = 0; k < 10; k++) {
    chain.warp(120n * DAY); chain.mine(11);
    await staking.send(users[0], 'claimRewards', []);            // drives the global side only
    const ts = BigInt(await staking.call('totalStaked'));
    const sum = (await Promise.all(users.map(async (u) => BigInt((await staking.call('getUserInfo', [u.hex]))[0]))))
      .reduce((a, b) => a + b, 0n);
    const gap = sum > ts ? sum - ts : 0n;
    if (ts > sum) wrongWay = true;                                // global ABOVE the sum = phantom collateral
    if (gap > worstGap) worstGap = gap;
  }
  console.log(`     worst un-attributed interest carried by positions: ${fmt(worstGap)}`);
  check(!wrongWay, 'S4: the global total never exceeds the sum of positions (no phantom collateral)',
        `totalStaked rose above the sum of balances — the ledger would be crediting stake nobody holds`);
  check(await solvent(staking) === true, 'S4: solvency intact throughout');
  // and the gap must close once every position is touched
  chain.mine(11);
  for (const u of users) await staking.send(u, 'repay', [1n]).catch(() => {});
  for (const u of users) await staking.send(u, 'claimRewards', []);
  const ts2 = BigInt(await staking.call('totalStaked'));
  const sum2 = (await Promise.all(users.map(async (u) => BigInt((await staking.call('getUserInfo', [u.hex]))[0]))))
    .reduce((a, b) => a + b, 0n);
  const residual = sum2 > ts2 ? sum2 - ts2 : ts2 - sum2;
  console.log(`     after touching every position: |totalStaked − Σ balances| = ${residual} wei`);
  check(residual <= DUST, 'S4: touching every position closes the gap completely',
        `${fmt(residual)} left over — the attribution does not converge`);
}

// ── S5 · A POSITION WHOSE INTEREST EXCEEDS ITS COLLATERAL ───────────────────────────────
//  The global side takes the full slice; the per-position side is capped at what the position
//  holds. That asymmetry is where an over-reduction of the global total would show up.
console.log('\n── S5 :: interest larger than the collateral backing it ───────────────────');
{
  const w = await world();
  const { chain, staking, users, guardian, admin } = w;
  for (const u of users) await staking.send(u, 'deposit', [E18(10_000_000), 365]);
  chain.mine(11);
  for (const u of users) { const i = await staking.call('getUserInfo', [u.hex]); await staking.send(u, 'borrow', [BigInt(i[3])]); }
  await staking.send(guardian, 'pause', []);
  for (let y = 0; y < 30; y++) { chain.warp(YEAR); chain.mine(11); await staking.send(users[0], 'repay', [1n]); }
  await staking.send(admin, 'unpause', []);
  const uncollected = BigInt(await staking.call('totalUncollectedInterest'));
  const ts = BigInt(await staking.call('totalStaked'));
  console.log(`     uncollected interest recorded: ${fmt(uncollected)}; totalStaked ${fmt(ts)}`);
  check(await solvent(staking) === true, 'S5: solvency intact when interest outruns collateral');
  check(BigInt(await staking.call('auditInvariants')) % 2n === 0n, 'S5: no conservation breach latched');
  const r = await staking.send(users[3], 'claimRewards', []);
  check(r.ok, 'S5: the protocol still functions in that state', `reverted ${r.revert}`);
}

// ── S6 · THE LOCK RE-KEY AS A LEVER ─────────────────────────────────────────────────────
//  Re-keying on a non-extending top-up lowers the stored duration. Confirm it can only ever
//  lower it toward the truth, never raise it, and that it cannot be used against anybody.
console.log('\n── S6 :: can the lock re-key be turned into a lever? ───────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(1_000_000), 2555]);
  const b0 = BigInt(await staking.call('effectiveBoostOf', [users[0].hex]));
  const u0 = BigInt((await staking.call('getUserInfo', [users[0].hex]))[10]);
  chain.warp(1000n * DAY); chain.mine(11);
  await staking.send(users[0], 'deposit', [1n, 90]);              // dust top-up, non-extending
  const b1 = BigInt(await staking.call('effectiveBoostOf', [users[0].hex]));
  const u1 = BigInt((await staking.call('getUserInfo', [users[0].hex]))[10]);
  console.log(`     boost ${b0} → ${b1} bps after a 1-wei non-extending top-up; unlock ${u0} → ${u1}`);
  check(u1 === u0, 'S6: a top-up never moves the unlock timestamp', `${u0} → ${u1}`);
  check(b1 <= b0, 'S6: the re-key can only lower the multiplier, never raise it', `${b0} → ${b1}`);
  // and it is self-only: nobody else can trigger it against a position
  const other = await staking.send(users[1], 'pokeExpiredLock', [users[0].hex]);
  check(!other.ok, 'S6: a third party cannot force a re-key on a live commitment', `got ok=${other.ok}`);
  check(await solvent(staking) === true, 'S6: solvency intact');
}

console.log('\n════════════════════════════════════════════════════════════════════════════');
console.log(`  ${PASS} checks passed, ${FAIL} failed`);
if (F.length) { console.log('\n  FAILED:'); F.forEach(x => console.log(`   ✗ ${x.l}\n       ${x.d}`)); }
console.log('════════════════════════════════════════════════════════════════════════════');
if (FAIL > 0) process.exitCode = 1;

// ── S7 · EXIT PATHS MUST LEAVE IDENTICAL RESIDUE ────────────────────────────────────────
//  Three different code paths end a position. Any one of them that forgets a registry entry or
//  a weight leaves a ghost drawing on the denominators — the same class as an earlier finding.
console.log('\n── S7 :: do all three exit paths clean up identically? ─────────────────────');
{
  const paths = {
    'withdraw       ': async (w, u) => { w.chain.warp(400n * DAY); w.chain.mine(11);
      await w.staking.send(u, 'withdraw', [BigInt((await w.staking.call('getUserInfo', [u.hex]))[0])]); },
    'emergencyExit  ': async (w, u) => { await w.staking.send(w.guardian, 'declareEmergency', []);
      await w.staking.send(u, 'emergencyWithdraw', []); },
    // Everyone leveraged, or utilisation stays too low for the book to ever decay far enough and
    // the arm silently tests nothing. The liquidation is asserted to land before anything is read.
    'liquidation    ': async (w, u) => {
      for (const x of w.users) if (x !== u) await w.staking.send(x, 'deposit', [E18(5_000_000), 365]);
      w.chain.mine(11);
      for (const x of w.users) { const i = await w.staking.call('getUserInfo', [x.hex]); await w.staking.send(x, 'borrow', [BigInt(i[3])]); }
      await w.staking.send(w.guardian, 'pause', []);
      for (let y = 0; y < 30; y++) { w.chain.warp(YEAR); w.chain.mine(11); await w.staking.send(u, 'repay', [1n]); }
      await w.staking.send(w.admin, 'unpause', []);
      const r = await w.staking.send(w.users[4], 'liquidate', [u.hex]);
      check(r.ok, 'S7[liquidation]: the liquidation actually landed (otherwise this arm tests nothing)',
            `reverted ${r.revert}`); },
  };
  for (const [name, run] of Object.entries(paths)) {
    const w = await world();
    const u = w.users[0];
    await w.staking.send(w.users[5], 'deposit', [E18(5_000_000), 365]);   // keeps the pool alive
    await w.staking.send(u, 'deposit', [E18(1_000_000), 365]);
    await run(w, u);
    const staked = BigInt((await w.staking.call('getUserInfo', [u.hex]))[0]);
    const locker = await w.staking.call('isTrackedLocker', [u.hex]);
    const borrower = await w.staking.call('isTrackedBorrower', [u.hex]);
    const stale = await w.staking.call('hasStaleBoost', [u.hex]);
    const debt = BigInt((await w.staking.call('getUserInfo', [u.hex]))[1]);
    console.log(`     ${name} staked=${fmt(staked)} debt=${fmt(debt)} locker=${locker} borrower=${borrower} stale=${stale}`);
    check(debt > 0n || borrower === false, `S7[${name.trim()}]: a debt-free position is not left in the borrower registry`,
          `debt is zero yet the position is still tracked — a ghost in the solvency sweep`);
    if (staked === 0n) {
      check(locker === false && borrower === false, `S7[${name.trim()}]: a fully closed position leaves no registry entry`,
            `locker=${locker} borrower=${borrower} — a ghost remains in a sweep set`);
    }
    check(stale === false, `S7[${name.trim()}]: no stale boost survives the exit`);
    check(await solvent(w.staking) === true, `S7[${name.trim()}]: solvency intact`);
  }
}

// ── S8 · CAN AUTHORITY BE RENOUNCED INTO A PERMANENT FREEZE? ────────────────────────────
//  AccessControl exposes renounceRole. Unpause, cancelEmergency, fundEmission and the residue
//  sweep are all admin-gated, so an admin that renounces while the protocol is paused would take
//  every recovery path with it.
console.log('\n── S8 :: renouncing authority while halted ────────────────────────────────');
{
  const w = await world();
  const { chain, staking, admin, guardian, users } = w;
  const DEFAULT_ADMIN = '0x' + '00'.repeat(32);
  const ADMIN_ROLE = ethers.id('ADMIN_ROLE');
  await staking.send(users[0], 'deposit', [E18(5_000_000), 90]);
  await staking.send(guardian, 'pause', []);
  await staking.send(admin, 'renounceRole', [ADMIN_ROLE, admin.hex]);
  await staking.send(admin, 'renounceRole', [DEFAULT_ADMIN, admin.hex]);
  const un = await staking.send(admin, 'unpause', []);
  console.log(`     admin renounced every role while paused; unpause → ${un.ok ? 'ok' : un.revert}`);

  chain.warp(91n * DAY); chain.mine(11);
  const wd = await staking.send(users[0], 'withdraw', [E18(1_000_000)]);
  const rp = await staking.send(users[0], 'claimRewards', []);
  console.log(`     with nobody able to unpause: withdraw → ${wd.ok ? 'ok' : wd.revert}, claim → ${rp.ok ? 'ok' : rp.revert}`);
  check(wd.ok, 'S8: stakers can still exit with their principal when authority is gone',
        `withdraw reverted ${wd.revert} — an abdicating admin strands every deposit behind a pause`);
  check(await solvent(w.staking) === true, 'S8: solvency intact');
}
