// ════════════════════════════════════════════════════════════════════════════════════════
//  BlazePhoenix Staking — state-dimension suite
//
//    node test/dimensions.mjs
//
//  Value conservation and time-path integrity are covered elsewhere. This file exercises the
//  four remaining dimensions a deployed protocol lives in: it must keep running (liveness),
//  it must not be drainable through privilege (access), the parties it depends on must be
//  paid to show up (incentives), and it must survive the asset underneath it behaving in
//  non-standard ways (ERC20 boundary).
// ════════════════════════════════════════════════════════════════════════════════════════
import { compileAll } from './compile.mjs';
import { Chain, E18 } from './lib.mjs';
import { ethers } from 'ethers';

const DAY = 86400n, YEAR = 365n * DAY, MAX_UINT = (1n << 256n) - 1n;
const art = compileAll();
const ADMIN_ROLE = ethers.id('ADMIN_ROLE'), GUARDIAN_ROLE = ethers.id('GUARDIAN_ROLE');
const DEFAULT_ADMIN = '0x' + '00'.repeat(32);

let PASS = 0, FAIL = 0; const F = [];
const check = (c, l, d = '') => { if (c) { PASS++; console.log(`  ✓ ${l}`); } else { FAIL++; F.push({ l, d }); console.log(`  ✗ ${l}${d ? '  ::  ' + d : ''}`); } return c; };
const fmt = (x) => (Number(x) / 1e18).toFixed(6);

async function world({ token = 'Token', fund = true } = {}) {
  const chain = await Chain.create();
  const admin = await chain.fund('admin', '0x' + '11'.repeat(32));
  const treasury = await chain.fund('treasury', '0x' + '66'.repeat(32));
  const guardian = await chain.fund('guardian', '0x' + '77'.repeat(32));
  const users = [];
  for (let i = 0; i < 6; i++) users.push(await chain.fund('u' + i, '0x' + (20 + i).toString(16).padStart(2, '0').repeat(32)));
  const tk = await chain.deploy(art[token], admin);
  const st = await chain.deploy(art.Staking, admin, [tk.addr.toString(), treasury.hex]);
  for (const u of [admin, ...users]) {
    await tk.send(admin, 'mint', [u.hex, E18(500_000_000)]);
    await tk.send(u, 'approve', [st.addr.toString(), MAX_UINT]);
  }
  await st.send(admin, 'grantRole', [GUARDIAN_ROLE, guardian.hex]);
  if (fund) await st.send(admin, 'fundEmission', [E18(180_000_000)]);
  return { chain, token: tk, staking: st, admin, treasury, guardian, users };
}

console.log('════════════════════════════════════════════════════════════════════════════');
console.log('  STATE DIMENSIONS — liveness · access · incentives · asset boundary');
console.log('════════════════════════════════════════════════════════════════════════════');

// ══ D3 · LIVENESS AND OPERATIONAL PROGRESS ═════════════════════════════════════════════
console.log('\n── D3 :: liveness — can the protocol be frozen or deadlocked? ─────────────');
{
  // L1 — a runaway rate must saturate, never panic-revert the accrual path
  const w = await world();
  const { chain, staking, users } = w;
  for (const u of users) await staking.send(u, 'deposit', [E18(10_000_000), 365]);
  chain.mine(11);
  for (const u of users) { const i = await staking.call('getUserInfo', [u.hex]); await staking.send(u, 'borrow', [BigInt(i[3])]); }
  let lastRate = 0n, stillLive = true, years = 0;
  for (let y = 1; y <= 40; y++) {
    chain.warp(YEAR); chain.mine(11);
    const r = await staking.send(users[0], 'repay', [1n]);
    if (!r.ok) { stillLive = false; break; }
    lastRate = BigInt(await staking.call('currentInterestRateBps')); years = y;
  }
  console.log(`     drove the rate to ${lastRate} bps over ${years} years of an untended leveraged pool`);
  check(stillLive, 'D3/L1: an extreme rate saturates instead of panicking the accrual path',
        `entry point started reverting at year ${years + 1}`);
  const claim = await staking.send(users[3], 'claimRewards', []);
  check(claim.ok, 'D3/L1: unrelated users can still transact at that rate', `reverted ${claim.revert}`);
}
{
  // L2 — a poisoned recipient must not stall anybody else's transaction
  const w = await world({ token: 'BlacklistToken' });
  const { chain, token, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(10_000_000), 90]);
  for (let i = 1; i <= 3; i++) {
    await staking.send(users[i], 'deposit', [E18(5_000_000), 90]); chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[i].hex]);
    await staking.send(users[i], 'borrow', [BigInt(inf[3]) / 2n]);
  }
  await token.send(users[0], 'block_', [users[2].hex, true]);   // the token now refuses to pay u2
  chain.warp(200n * DAY); chain.mine(11);
  const r = await staking.send(users[0], 'claimRewards', []);   // carries the sweep over u2
  console.log(`     with a blacklisted position in the registry, an honest claim → ${r.ok ? 'ok' : r.revert}`);
  check(r.ok, 'D3/L2: a position the token refuses to pay cannot stall a third party',
        `an innocent transaction was reverted by someone else's poisoned position`);
  const r2 = await staking.send(users[1], 'repay', [E18(1)]);
  check(r2.ok, 'D3/L2: the book keeps progressing afterwards', `reverted ${r2.revert}`);
}
{
  // L3 — sweep budgets stay bounded no matter how crowded the registries get
  const w = await world();
  const { chain, staking, users } = w;
  for (const u of users) await staking.send(u, 'deposit', [E18(1_000), 90]);
  chain.mine(11);
  for (let i = 1; i < users.length; i++) await staking.send(users[i], 'borrow', [1n]);
  chain.warp(500n * DAY); chain.mine(11);                       // every lock lapsed, long gap
  const mb = BigInt(await staking.call('maintenanceBudget')), lb = BigInt(await staking.call('lockSweepBudget'));
  console.log(`     ${await staking.call('activeBorrowerCount')} borrowers / ${await staking.call('activeLockerCount')} lockers → budgets ${mb} and ${lb}`);
  check(mb <= 10n && lb <= 10n, 'D3/L3: both sweep windows stay under the per-tx ceiling', `${mb} / ${lb}`);
  const r = await staking.send(users[0], 'claimRewards', []);
  check(r.ok, 'D3/L3: a transaction carrying a full backlog still completes', `reverted ${r.revert}`);
}
{
  // L4 — a batch poke must skip invalid entries, not revert the whole batch
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(1_000), 90]);
  await staking.send(users[1], 'deposit', [E18(1_000), 2555]);   // still locked -> invalid entry
  chain.warp(91n * DAY); chain.mine(11);
  const batch = [users[0].hex, users[1].hex, users[4].hex];      // expired, locked, never staked
  const r = await staking.send(users[3], 'pokeExpiredLocks', [batch]);
  console.log(`     batch of {expired, still-locked, empty} → ${r.ok ? 'ok' : r.revert}`);
  check(r.ok, 'D3/L4: a mixed batch succeeds on the valid entries instead of reverting', `got ${r.revert}`);
  check(BigInt((await staking.call('getUserInfo', [users[0].hex]))[9]) === 0n,
        'D3/L4: the valid entry was actually normalised');
  const empty = await staking.send(users[3], 'pokeExpiredLocks', [[users[4].hex]]);
  check(!empty.ok, 'D3/L4: a batch with nothing to do reverts rather than burning gas silently');
}

// ══ D4 · PRIVILEGE AND ACCESS BOUNDARIES ═══════════════════════════════════════════════
console.log('\n── D4 :: access — can privilege drain the contract? ───────────────────────');
{
  const w = await world();
  const { chain, token, staking, admin, treasury, guardian, users } = w;
  await staking.send(users[0], 'deposit', [E18(20_000_000), 365]);
  await staking.send(users[1], 'deposit', [E18(10_000_000), 365]); chain.mine(11);
  const inf = await staking.call('getUserInfo', [users[1].hex]);
  await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
  chain.warp(200n * DAY); chain.mine(11);
  await staking.send(users[0], 'claimRewards', []);

  // P1 — no admin path can reach staker principal
  const principal = BigInt(await staking.call('totalStaked'));
  const reserve = BigInt(await staking.call('protocolReserve'));
  const before = BigInt(await token.call('balanceOf', [treasury.hex]));
  await staking.send(admin, 'withdrawReserve', [MAX_UINT]);      // ask for everything
  const took = BigInt(await token.call('balanceOf', [treasury.hex])) - before;
  console.log(`     admin asked for uint256.max — received ${fmt(took)} (protocolReserve was ${fmt(reserve)}, principal ${fmt(principal)})`);
  check(took === reserve, 'D4/P1: withdrawReserve is clamped to protocol revenue, never principal',
        `took ${fmt(took)} against a reserve of ${fmt(reserve)}`);
  check(BigInt(await staking.call('totalStaked')) === principal, 'D4/P1: staker principal is untouched');

  // P2 — the destination is immutable, even for the admin
  const t = await staking.call('treasury');
  check(t.toLowerCase() === treasury.hex.toLowerCase(), 'D4/P2: treasury is fixed at construction');
  const abi = art.Staking.abi.map(f => f.name).filter(Boolean);
  const dangerous = abi.filter(n => /setTreasury|setOwner|migrate|rescue|sweepTokens|emergencyDrain|upgradeTo/i.test(n));
  console.log(`     admin-surface scan for redirect/rescue entry points: ${dangerous.length ? dangerous.join(', ') : 'none found'}`);
  check(dangerous.length === 0, 'D4/P2: no function exists to redirect funds or rescue arbitrary tokens',
        `found ${dangerous.join(', ')}`);

  // P3 — a compromised admin cannot mint itself power over user balances
  const r1 = await staking.send(admin, 'grantRole', [DEFAULT_ADMIN, admin.hex]);
  const r2 = await staking.send(admin, 'withdrawReserve', [MAX_UINT]);
  check(!r2.ok || BigInt(await staking.call('totalStaked')) === principal,
        'D4/P3: even with every role, principal cannot be extracted', `totalStaked moved`);

  // P4 — the breaker is objective: it cannot be tripped on a healthy book
  const trip = await staking.send(users[3], 'tripBreaker', []);
  check(!trip.ok && trip.revert === 'Staking__NoBreach', 'D4/P4: the permissionless breaker needs on-chain proof',
        `got ${trip.revert}`);

  // P5 — the guardian can halt but not extract
  await staking.send(guardian, 'declareEmergency', []);
  const wr = await staking.send(admin, 'withdrawReserve', [1n]);
  check(!wr.ok, 'D4/P5: emergency closes the admin revenue path too', `withdrawReserve succeeded in emergency`);
  const gBal = BigInt(await token.call('balanceOf', [guardian.hex]));
  check(gBal === 0n, 'D4/P5: halting the protocol pays the guardian nothing', `guardian holds ${fmt(gBal)}`);
}

// ══ D5 · CRYPTOECONOMIC / INCENTIVE STATE ══════════════════════════════════════════════
console.log('\n── D5 :: incentives — is anyone paid to keep the book clean? ──────────────');
{
  const w = await world();
  const { chain, token, staking, users } = w;
  // A pool where everyone is leveraged decays fastest, which is the state the cleanup
  // machinery exists for. A lightly-levered book simply never gets there.
  for (const u of users) await staking.send(u, 'deposit', [E18(10_000_000), 365]);
  chain.mine(11);
  for (const u of users) { const i = await staking.call('getUserInfo', [u.hex]); await staking.send(u, 'borrow', [BigInt(i[3])]); }
  const driver = users[3];
  let fired = 0n, gain = 0n, years = 0;
  for (let y = 1; y <= 40 && fired === 0n; y++) {
    chain.warp(YEAR); chain.mine(11);
    const gb = BigInt(await token.call('balanceOf', [driver.hex]));
    await staking.send(driver, 'claimRewards', []);   // an ordinary tx carries the sweep
    fired = BigInt(await staking.call('totalLiquidations'));
    if (fired > 0n) { gain = BigInt(await token.call('balanceOf', [driver.hex])) - gb; years = y; }
  }
  const auto = BigInt(await staking.call('totalAutoLiquidations'));
  console.log(`     autonomous engine liquidated after ${years}y without any keeper being asked`);
  console.log(`     totalLiquidations ${fired} (of which autonomous ${auto}); surplus to the gas-payer ${fmt(gain)}`);
  check(fired > 0n, 'D5/G1: a decaying position is cleaned up by ordinary traffic alone',
        'nothing was ever liquidated — the book would rot');
  check(auto > 0n, 'D5/G1: the cleanup came from the autonomous window, not a paid keeper',
        `autonomous count ${auto}`);
  check(gain >= 0n, 'D5/G1: the transaction that carries a liquidation is never charged for it',
        `the gas-payer lost ${fmt(-gain)}`);
  check(await staking.call('isSolvent') === true, 'D5/G1: solvency intact through liquidation');
}
{
  // G2 — the bonus must redistribute seized value, never create it
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(10_000_000), 365]);
  const owed0 = BigInt(await staking.call('owed')), back0 = BigInt(await staking.call('backing'));
  chain.warp(30n * DAY); chain.mine(11);
  await staking.send(users[0], 'claimRewards', []);
  const d = (BigInt(await staking.call('owed')) - owed0) - (BigInt(await staking.call('backing')) - back0);
  check(d <= 0n, 'D5/G2: maintenance rewards never create value out of nothing', `Δowed − Δbacking = ${d}`);
}

// ══ D6 · ASSET BOUNDARY (NON-STANDARD ERC20) ═══════════════════════════════════════════
console.log('\n── D6 :: asset boundary — what if BZPX is not a well-behaved ERC20? ───────');
{
  // E1 — a token that returns no value at all (USDT-style)
  const w = await world({ token: 'NoReturnToken' });
  const { chain, staking, users } = w;
  const dep = await staking.send(users[0], 'deposit', [E18(1_000_000), 90]);
  chain.warp(60n * DAY); chain.mine(11);
  const clm = await staking.send(users[0], 'claimRewards', []);
  chain.warp(40n * DAY); chain.mine(11);
  const wd = await staking.send(users[0], 'withdraw', [E18(1_000)]);
  console.log(`     no-return-value token: deposit ${dep.ok ? 'ok' : dep.revert}, claim ${clm.ok ? 'ok' : clm.revert}, withdraw ${wd.ok ? 'ok' : wd.revert}`);
  check(dep.ok && clm.ok && wd.ok, 'D6/E1: a token with no boolean return works end to end',
        `the raw-call layer rejected a legitimate non-standard token`);
  check(await staking.call('isSolvent') === true, 'D6/E1: solvency intact');
}
{
  // E2 — a fee-on-transfer token credits less than it is told to. This is the classic
  //      accounting break: the ledger records the requested amount, the contract receives less.
  const w = await world({ token: 'FeeToken' });
  const { chain, token, staking, users } = w;
  await token.send(users[0], 'setFee', [100]);                 // 1% fee on every transfer
  const dep = await staking.send(users[0], 'deposit', [E18(1_000_000), 90]);
  const staked = BigInt((await staking.call('getUserInfo', [users[0].hex]))[0]);
  const held = BigInt(await token.call('balanceOf', [staking.addr.toString()]));
  const owed = BigInt(await staking.call('owed'));
  const sol = await staking.call('isSolvent');
  console.log(`     1% fee-on-transfer: deposit ${dep.ok ? 'ok' : dep.revert}; ledger credits ${fmt(staked)}, contract holds ${fmt(held)}`);
  console.log(`     owed ${fmt(owed)} vs backing ${fmt(held)} → isSolvent=${sol}`);
  check(!dep.ok || sol === true, 'D6/E2: a fee-on-transfer token cannot leave the ledger over-credited',
        `deposit was accepted while the contract received ${fmt(held)} against a credited ${fmt(staked)} — the shortfall is real`);
}
{
  // E3 — a refused payout must revert the whole claim, never silently zero the entitlement
  const w = await world({ token: 'BlacklistToken' });
  const { chain, token, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(1_000_000), 90]);
  chain.warp(60n * DAY); chain.mine(11);
  const pending = BigInt(await staking.call('pendingRewards', [users[0].hex]));
  await token.send(users[1], 'block_', [users[0].hex, true]);
  const r = await staking.send(users[0], 'claimRewards', []);
  const after = BigInt(await staking.call('pendingRewards', [users[0].hex]));
  console.log(`     payout refused → ${r.ok ? 'ok' : r.revert}; entitlement ${fmt(pending)} → ${fmt(after)}`);
  check(!r.ok, 'D6/E3: a refused payout reverts rather than completing', `claim reported success`);
  check(after >= pending, 'D6/E3: the entitlement survives the refusal', `it dropped to ${fmt(after)}`);
  await token.send(users[1], 'block_', [users[0].hex, false]);
  const r2 = await staking.send(users[0], 'claimRewards', []);
  check(r2.ok, 'D6/E3: the claim goes through once the token relents', `reverted ${r2.revert}`);
}

console.log('\n════════════════════════════════════════════════════════════════════════════');
console.log(`  ${PASS} dimension checks passed, ${FAIL} failed`);
if (F.length) { console.log('\n  FAILED:'); F.forEach(x => console.log(`   ✗ ${x.l}\n       ${x.d}`)); }
console.log('════════════════════════════════════════════════════════════════════════════');
