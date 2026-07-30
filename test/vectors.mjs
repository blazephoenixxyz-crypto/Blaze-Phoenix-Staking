// ════════════════════════════════════════════════════════════════════════════════════════
//  BlazePhoenix Staking — canonical DeFi attack-vector suite
//
//    node test/vectors.mjs
//
//  The industry's standard exploit families, run against this protocol. Vectors that cannot
//  exist here by construction (oracle manipulation, cross-asset arbitrage, proxy storage
//  collision, signature replay) are recorded as inapplicable rather than silently skipped.
// ════════════════════════════════════════════════════════════════════════════════════════
import { compileAll } from './compile.mjs';
import { Chain, E18 } from './lib.mjs';
import { ethers } from 'ethers';

const DAY = 86400n, YEAR = 365n * DAY, MAX_UINT = (1n << 256n) - 1n;
const DUST = 10n ** 10n;
const art = compileAll();

let PASS = 0, FAIL = 0; const FAILURES = [];
function check(c, label, detail = '') {
  if (c) { PASS++; console.log(`  ✓ ${label}`); }
  else { FAIL++; FAILURES.push({ label, detail }); console.log(`  ✗ ${label}${detail ? '  ::  ' + detail : ''}`); }
  return c;
}
const fmt = (x) => (Number(x) / 1e18).toFixed(6);

async function world({ token = 'Token' } = {}) {
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
  await st.send(admin, 'grantRole', [ethers.id('GUARDIAN_ROLE'), guardian.hex]);
  await st.send(admin, 'fundEmission', [E18(180_000_000)]);
  return { chain, token: tk, staking: st, admin, treasury, guardian, users };
}
const solvent = async (st) => st.call('isSolvent');
const audit = async (st) => BigInt(await st.call('auditInvariants'));

console.log('════════════════════════════════════════════════════════════════════════════');
console.log('  CANONICAL DeFi ATTACK VECTORS');
console.log('════════════════════════════════════════════════════════════════════════════');

// ── V1 · REENTRANCY (callback token, 4 re-entry targets) ────────────────────────────────
console.log('\n── V1 :: reentrancy via a token that calls back on transfer ────────────────');
{
  for (const [mode, name] of [[1, 'claimRewards'], [2, 'withdraw'], [3, 'deposit'], [4, 'claimPureYield']]) {
    const w = await world({ token: 'ReentrantToken' });
    const { chain, token, staking, admin, users } = w;
    const atk = await chain.deploy(art.Reenterer, admin, [staking.addr.toString(), token.addr.toString()]);
    await token.send(admin, 'mint', [atk.addr.toString(), E18(10_000_000)]);
    await token.send(admin, 'setHook', [atk.addr.toString()]);
    await staking.send(users[0], 'deposit', [E18(5_000_000), 365]);
    await atk.send(admin, 'open', [E18(1_000_000), 90]);
    chain.warp(120n * DAY); chain.mine(20);
    await atk.send(admin, 'setMode', [mode]);
    await token.send(admin, 'arm', [true]);
    const r = await atk.send(admin, 'goClaim', []);
    const reentered = await atk.call('succeeded');
    const err = await atk.call('lastError');
    console.log(`     re-enter ${name.padEnd(15)} outer=${r.ok ? 'ok' : r.revert}  inner succeeded=${reentered}  inner error="${err}"`);
    check(r.ok, `V1[${name}]: the outer payout ran (otherwise the guard was never reached)`, `outer reverted ${r.revert}`);
    check(reentered === false, `V1: re-entering ${name} during a payout is rejected`,
          `the nested call SUCCEEDED — guard bypassed`);
    check(await solvent(staking) === true, `V1: solvency intact after the ${name} attempt`);
  }
}

// ── V2 · FIRST-DEPOSITOR / DUST SHARE INFLATION ─────────────────────────────────────────
console.log('\n── V2 :: first-depositor and dust-weight inflation ─────────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [1n, 2555]);              // 1 wei, maximum lock
  chain.warp(30n * DAY); chain.mine(11);
  const maxNow = BigInt(await staking.call('maxLockDaysAvailable'));   // window has shrunk by 30d
  const dep = await staking.send(users[1], 'deposit', [E18(10_000_000), maxNow]);
  check(dep.ok, 'V2: staging deposit landed (guards against a silently reverted arm)', `got ${dep.revert}`);
  chain.warp(60n * DAY); chain.mine(11);
  const dustRw = BigInt(await staking.call('pendingRewards', [users[0].hex]));
  const whaleRw = BigInt(await staking.call('pendingRewards', [users[1].hex]));
  console.log(`     1-wei first depositor pending: ${fmt(dustRw)}   whale pending: ${fmt(whaleRw)}`);
  check(dustRw === 0n, 'V2: a dust-only pool accrues nothing, so nothing can be captured',
        `dust position holds ${fmt(dustRw)} — it absorbed the schedule while alone`);
  check(await solvent(staking) === true, 'V2: solvency intact');
}

// ── V3 · ROUNDING-TO-ZERO GRIEFING ──────────────────────────────────────────────────────
console.log('\n── V3 :: many tiny accruals vs one large one (rounding-to-zero) ────────────');
{
  const run = async (slices) => {
    const w = await world();
    const { chain, staking, users } = w;
    await staking.send(users[0], 'deposit', [E18(10_000_000), 365]);
    await staking.send(users[1], 'deposit', [E18(10_000_000), 365]); chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[1].hex]);
    await staking.send(users[1], 'borrow', [BigInt(inf[3])]);
    const c0 = BigInt((await staking.call('getUserInfo', [users[1].hex]))[0]);
    for (let k = 0; k < slices; k++) { chain.warp(180n * DAY / BigInt(slices)); chain.mine(2); await staking.send(users[0], 'claimRewards', []); }
    chain.mine(11); await staking.send(users[1], 'repay', [1n]);
    return c0 - BigInt((await staking.call('getUserInfo', [users[1].hex]))[0]);
  };
  const few = await run(2), many = await run(180);
  const lost = few > many ? few - many : 0n;
  const bps = few === 0n ? 0n : (lost * 10_000n) / few;
  console.log(`     2 slices: ${fmt(few)}   180 slices: ${fmt(many)}   erosion ${Number(bps) / 100}%`);
  check(bps <= 10n, 'V3: slicing time finely does not erode accrued interest',
        `${Number(bps) / 100}% lost to rounding — a griefer could shave interest by spamming touches`);
}

// ── V4 · MAINTENANCE-SWEEP STARVATION ───────────────────────────────────────────────────
console.log('\n── V4 :: hiding behind a crowded borrower registry ─────────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(20_000_000), 365]);
  for (let i = 1; i <= 4; i++) {
    await staking.send(users[i], 'deposit', [E18(10_000_000), 365]); chain.mine(11);
    const inf = await staking.call('getUserInfo', [users[i].hex]);
    await staking.send(users[i], 'borrow', [BigInt(inf[3])]);
  }
  const target = users[4];
  const c0 = BigInt((await staking.call('getUserInfo', [target.hex]))[0]);
  chain.warp(365n * DAY); chain.mine(11);
  // the target never transacts; ordinary traffic from others drives the book
  for (let k = 0; k < 6; k++) { chain.mine(3); await staking.send(users[0], 'claimRewards', []); }
  const attributed = c0 - BigInt((await staking.call('getUserInfo', [target.hex]))[0]);
  chain.mine(11); await staking.send(target, 'repay', [1n]);
  const settled = c0 - BigInt((await staking.call('getUserInfo', [target.hex]))[0]);
  console.log(`     never-touched borrower — attributed before own tx: ${fmt(attributed)}, after: ${fmt(settled)}`);
  check(settled > 0n, 'V4: a borrower cannot avoid interest by never being swept',
        `charged ${fmt(settled)} over a full year`);
  check(await solvent(staking) === true, 'V4: solvency intact');
}

// ── V5 · SYBIL SPLIT ACROSS THE PER-WALLET CAP ──────────────────────────────────────────
console.log('\n── V5 :: splitting one position across many wallets ────────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(9_000_000), 365]);          // one wallet
  for (let i = 1; i <= 3; i++) await staking.send(users[i], 'deposit', [E18(3_000_000), 365]); // same total, split
  chain.warp(90n * DAY); chain.mine(11);
  const single = BigInt(await staking.call('pendingRewards', [users[0].hex]));
  let split = 0n;
  for (let i = 1; i <= 3; i++) split += BigInt(await staking.call('pendingRewards', [users[i].hex]));
  const diff = single > split ? single - split : split - single;
  console.log(`     one wallet 9M: ${fmt(single)}   three wallets 3M each: ${fmt(split)}`);
  check(diff * 10_000n <= single, 'V5: splitting a position confers no reward advantage',
        `Δ ${fmt(diff)} — a Sybil could farm by fragmenting`);
}

// ── V6 · LIQUIDATION PROFIT EXTRACTION ──────────────────────────────────────────────────
console.log('\n── V6 :: liquidation as a value-extraction primitive ───────────────────────');
{
  const w = await world();
  const { chain, staking, token, users } = w;
  // A fully leveraged book is what actually decays into a liquidatable state. Under a pause the
  // autonomous engine cannot get there first, so the manual path is the one under test.
  for (const u of users) await staking.send(u, 'deposit', [E18(10_000_000), 365]);
  chain.mine(11);
  for (const u of users) { const i = await staking.call('getUserInfo', [u.hex]); await staking.send(u, 'borrow', [BigInt(i[3])]); }
  await staking.send(w.guardian, 'pause', []);
  for (let y = 0; y < 25; y++) { chain.warp(YEAR); chain.mine(11); await staking.send(users[0], 'repay', [1n]); }
  await staking.send(w.admin, 'unpause', []);
  const keeper = users[3];
  const target = users[5];
  const kb0 = BigInt(await token.call('balanceOf', [keeper.hex]));
  const r1 = await staking.send(keeper, 'liquidate', [target.hex]);
  const gain1 = BigInt(await token.call('balanceOf', [keeper.hex])) - kb0;
  const r2 = await staking.send(keeper, 'liquidate', [target.hex]);
  console.log(`     liquidate #1 → ${r1.ok ? 'ok' : r1.revert}, keeper gain ${fmt(gain1)}; repeat → ${r2.ok ? 'ok' : r2.revert}`);
  check(r1.ok, 'V6: the position actually reached a liquidatable state (otherwise the rest is vacuous)',
        `first liquidation reverted with ${r1.revert} — nothing below was exercised`);
  check(!r2.ok, 'V6: the same position cannot be liquidated twice', `second call succeeded`);
  check(await solvent(staking) === true, 'V6: solvency intact after liquidation');
  // Only the conservation bit is asserted: the remaining positions in this deliberately rotten
  // book are still above the liquidation threshold, and the mask reporting that is correct.
  check(((await audit(staking)) & 1n) === 0n, 'V6: no conservation breach after liquidation',
        `bitmap 0b${(await audit(staking)).toString(2)}`);
}

// ── V7 · BLOCK-TIMESTAMP MANIPULATION ───────────────────────────────────────────────────
console.log('\n── V7 :: validator timestamp jitter ────────────────────────────────────────');
{
  const run = async (jitter) => {
    const w = await world();
    const { chain, staking, users } = w;
    await staking.send(users[0], 'deposit', [E18(10_000_000), 365]);
    chain.warp(90n * DAY + jitter); chain.mine(11);
    return BigInt(await staking.call('pendingRewards', [users[0].hex]));
  };
  const base = await run(0n), skew = await run(12n);
  const d = skew > base ? skew - base : base - skew;
  const bps = base === 0n ? 0n : (d * 10_000n) / base;
  console.log(`     +0s: ${fmt(base)}   +12s: ${fmt(skew)}   Δ ${Number(bps) / 100}%`);
  check(bps <= 1n, 'V7: a 12-second validator skew is economically negligible',
        `${Number(bps) / 100}% swing on a 90-day position`);
}

// ── V8 · ROUNDING DIRECTION (the protocol must never round in a user's favour) ──────────
console.log('\n── V8 :: rounding always favours the protocol ──────────────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  const odd = [1n, 3n, 7n, 999_999_999_999_999_999n];
  for (let i = 0; i < 4; i++) await staking.send(users[i], 'deposit', [E18(1_000) + odd[i], 90 + i]);
  chain.mine(11);
  const inf = await staking.call('getUserInfo', [users[1].hex]);
  await staking.send(users[1], 'borrow', [BigInt(inf[3]) - 7n]);
  let worst = 0n;
  for (let k = 0; k < 25; k++) {
    chain.warp(BigInt(1 + (k * 7919) % 100_003)); chain.mine(1 + (k % 5));
    await staking.send(users[k % 4], 'claimRewards', []);
    const owed = BigInt(await staking.call('owed')), backing = BigInt(await staking.call('backing'));
    const resid = owed - backing;
    if (resid > worst) worst = resid;
  }
  console.log(`     worst (owed − backing) across 25 irregular steps: ${worst} wei`);
  check(worst <= 0n, 'V8: the ledger never claims more than the contract holds, not even by 1 wei',
        `worst shortfall ${worst} wei`);
}

// ── V9 · FLASH-LOAN STYLE ATOMIC CYCLE ──────────────────────────────────────────────────
console.log('\n── V9 :: atomic deposit → borrow → withdraw inside one block ───────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(20_000_000), 365]);
  await staking.send(users[1], 'deposit', [E18(10_000_000), 90]);
  const b = await staking.send(users[1], 'borrow', [E18(1_000_000)]);
  const wd = await staking.send(users[1], 'withdraw', [E18(1)]);
  console.log(`     same-block borrow → ${b.ok ? 'ok' : b.revert};  same-block withdraw → ${wd.ok ? 'ok' : wd.revert}`);
  check(b.ok, 'V9: the borrow landed (otherwise the withdraw is blocked for the wrong reason)', `borrow reverted ${b.revert}`);
  check(!wd.ok, 'V9: capital cannot enter and leave inside the guard window', `withdraw succeeded`);
  chain.warp(91n * DAY); chain.mine(11);
  await staking.send(users[1], 'repay', [MAX_UINT]);
  chain.mine(11);        // a full repay re-arms the block delay by design
  const wd2 = await staking.send(users[1], 'withdraw', [E18(1)]);
  check(wd2.ok, 'V9: an honest exit still works once the lock and block delay have passed',
        `reverted with ${wd2.revert}`);
}

// ── V10 · DEPOSIT / WITHDRAW CYCLING TO FARM WEIGHT ─────────────────────────────────────
console.log('\n── V10 :: cycling in and out to farm reward weight ─────────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(5_000_000), 90]);   // cycler
  await staking.send(users[1], 'deposit', [E18(5_000_000), 90]);   // holder, never touches again
  for (let k = 0; k < 5; k++) {
    chain.warp(20n * DAY); chain.mine(12);
    await staking.send(users[0], 'claimRewards', []);
  }
  chain.warp(20n * DAY); chain.mine(12);
  const total = async (u) => (BigInt(await w.token.call('balanceOf', [u.hex])) - E18(500_000_000) + E18(5_000_000))
                            + BigInt(await staking.call('pendingRewards', [u.hex]));
  const cycTotal = await total(users[0]);      // claimed + still pending
  const holdTotal = await total(users[1]);     // swept payouts + still pending
  console.log(`     cycler total ${fmt(cycTotal)}   |   holder total ${fmt(holdTotal)}`);
  const gap = cycTotal > holdTotal ? cycTotal - holdTotal : holdTotal - cycTotal;
  check(gap * 1000n <= holdTotal, 'V10: claiming often confers no advantage over holding',
        `cycler ${fmt(cycTotal)} vs holder ${fmt(holdTotal)} (Δ ${fmt(gap)})`);
}

// ── V11 · DUST-DEBT REGISTRY BLOAT ──────────────────────────────────────────────────────
console.log('\n── V11 :: dust debt to bloat the maintenance registry ──────────────────────');
{
  const w = await world();
  const { chain, staking, users } = w;
  await staking.send(users[0], 'deposit', [E18(10_000_000), 365]);
  for (let i = 1; i <= 4; i++) {
    await staking.send(users[i], 'deposit', [E18(1_000), 90]); chain.mine(11);
    await staking.send(users[i], 'borrow', [1n]);                 // 1 wei of debt each
  }
  const n = BigInt(await staking.call('activeBorrowerCount'));
  const budget = BigInt(await staking.call('maintenanceBudget'));
  console.log(`     ${n} dust borrowers registered; per-tx sweep budget ${budget} (hard cap 10)`);
  check(budget <= 10n, 'V11: the sweep budget stays hard-capped regardless of registry size',
        `budget ${budget} exceeds MAINT_MAX_SCAN`);
  const r = await staking.send(users[0], 'claimRewards', []);
  check(r.ok, 'V11: an honest transaction still completes with a bloated registry', `reverted ${r.revert}`);
  check(await solvent(staking) === true, 'V11: solvency intact');
}

// ── INAPPLICABLE BY CONSTRUCTION ────────────────────────────────────────────────────────
console.log('\n── Vectors that cannot exist in this design ────────────────────────────────');
for (const [v, why] of [
  ['Oracle manipulation / price feed attack', 'no oracle exists — collateral, debt and reward are the same token'],
  ['Cross-asset arbitrage / sandwich on swaps', 'single-asset protocol, no AMM or swap path'],
  ['Proxy storage collision / malicious upgrade', 'not upgradeable — no proxy, no delegatecall'],
  ['Signature replay / permit forgery', 'no signature-authenticated entry point'],
  ['Governance takeover / malicious proposal', 'no governance and no parameter knobs'],
  ['Admin rug via arbitrary withdrawal', 'reserve withdrawals are bounded by protocolReserve and hard-wired to an immutable treasury'],
]) console.log(`     n/a  ${v.padEnd(44)} — ${why}`);

console.log('\n════════════════════════════════════════════════════════════════════════════');
console.log(`  ${PASS} vector checks passed, ${FAIL} failed`);
if (FAILURES.length) { console.log('\n  FAILED:'); FAILURES.forEach(f => console.log(`   ✗ ${f.label}\n       ${f.detail}`)); }
console.log('════════════════════════════════════════════════════════════════════════════');
if (FAIL > 0) process.exitCode = 1;   // a violated property must fail the process, not just print
