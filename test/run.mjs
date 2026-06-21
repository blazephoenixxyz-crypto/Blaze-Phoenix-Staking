// BlazePhoenix Staking — integrity & edge-case suite (real EVM, offline).
//   node test/run.mjs
import { compileAll } from './compile.mjs';
import { Chain, Contract, ok, eq, approx, test, summary, E18 } from './lib.mjs';
import { ethers } from 'ethers';

const DAY = 86400n, YEAR = 365n * DAY;
const MAX_UINT = (1n << 256n) - 1n;
const GUARDIAN_ROLE = ethers.id('GUARDIAN_ROLE');
const art = compileAll();

async function setup() {
  const chain = await Chain.create();
  const admin    = await chain.fund('admin',    '0x' + '11'.repeat(32));
  const alice    = await chain.fund('alice',    '0x' + '22'.repeat(32));
  const bob      = await chain.fund('bob',      '0x' + '33'.repeat(32));
  const carol    = await chain.fund('carol',    '0x' + '44'.repeat(32));
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
async function assertSolvent(staking, label) {
  const solvent = await staking.call('isSolvent');
  ok(solvent === true, `${label}: isSolvent()`);
  const audit = await staking.call('auditInvariants');
  ok((BigInt(audit) & 1n) === 0n, `${label}: conservation bit clear (audit=${audit})`);
}

// ───────────────────────────────────────────────────────────────────────────
await test('boost curve (boostByDays) exact values + clamp', async () => {
  const { staking } = await setup();
  eq(await staking.call('boostByDays', [0]), 10000, 'd=0');
  eq(await staking.call('boostByDays', [90]), 10199, 'd=90');
  eq(await staking.call('boostByDays', [365]), 11000, 'd=365');
  eq(await staking.call('boostByDays', [730]), 12500, 'd=730');
  eq(await staking.call('boostByDays', [1825]), 20000, 'd=1825');
  eq(await staking.call('boostByDays', [2555]), 27500, 'd=2555');
  eq(await staking.call('boostByDays', [9999]), 27500, 'clamps above MAX');
});

await test('deposit requires a valid lock (90..2555)', async () => {
  const { staking, alice } = await setup();
  let r = await staking.send(alice, 'deposit', [E18(100), 0]);
  ok(!r.ok && r.revert === 'Staking__LockTooShort', `0 days -> LockTooShort (${r.revert})`);
  r = await staking.send(alice, 'deposit', [E18(100), 89]);
  ok(!r.ok && r.revert === 'Staking__LockTooShort', `89 days -> LockTooShort (${r.revert})`);
  r = await staking.send(alice, 'deposit', [E18(100), 2556]);
  ok(!r.ok && r.revert === 'Staking__LockTooLong', `2556 days -> LockTooLong (${r.revert})`);
  r = await staking.send(alice, 'deposit', [0, 90]);
  ok(!r.ok && r.revert === 'Staking__ZeroAmount', `0 amount -> ZeroAmount (${r.revert})`);
  r = await staking.send(alice, 'deposit', [E18(100), 90]);
  ok(r.ok, '90 days, 100 tokens -> ok');
  eq(await staking.call('totalStaked'), E18(100), 'totalStaked');
});

await test('deposit locks; withdraw blocked while locked, allowed after expiry', async () => {
  const { chain, staking, token, alice } = await setup();
  await staking.send(alice, 'deposit', [E18(1000), 90]);
  chain.mine(11);
  let r = await staking.send(alice, 'withdraw', [E18(100)]);
  ok(!r.ok && r.revert === 'Staking__StillLocked', `locked -> StillLocked (${r.revert})`);
  chain.warp(91n * DAY); chain.mine(11);
  const before = await bal(token, alice.hex);
  r = await staking.send(alice, 'withdraw', [E18(1000)]);
  ok(r.ok, 'after expiry -> withdraw ok');
  eq(await bal(token, alice.hex) - before, E18(1000), 'received full principal');
  eq(await staking.call('totalStaked'), 0, 'totalStaked back to 0');
});

await test('top-up can only EXTEND the lock, never shorten', async () => {
  const { chain, staking, alice } = await setup();
  await staking.send(alice, 'deposit', [E18(100), 400]);     // unlock ~ now+400d
  const u1 = await staking.call('lockInfoOf', [alice.hex]);
  chain.mine(11);
  await staking.send(alice, 'deposit', [E18(100), 90]);      // shorter -> keep existing unlock
  const u2 = await staking.call('lockInfoOf', [alice.hex]);
  eq(u2[1], u1[1], 'unlockTime unchanged by shorter top-up');
  eq(u2[0], 400, 'lockDays unchanged by shorter top-up');
  await staking.send(alice, 'deposit', [E18(100), 800]);     // longer -> extends
  const u3 = await staking.call('lockInfoOf', [alice.hex]);
  ok(u3[1] > u1[1], 'unlockTime extended by longer top-up');
  eq(u3[0], 800, 'lockDays updated to 800');
});

await test('per-wallet stake cap enforced', async () => {
  const { staking, alice } = await setup();
  await staking.send(alice, 'deposit', [E18(30_000_000), 90]);
  const r = await staking.send(alice, 'deposit', [E18(1), 90]);
  ok(!r.ok && r.revert === 'Staking__CapExceeded', `over cap -> CapExceeded (${r.revert})`);
});

await test('borrow respects 50% LTV on effective stake', async () => {
  const { chain, staking, token, alice } = await setup();
  await staking.send(alice, 'deposit', [E18(1000), 365]);
  chain.mine(2);
  let r = await staking.send(alice, 'borrow', [E18(501)]);
  ok(!r.ok && r.revert === 'Staking__LTVExceeded', `501 > 50% -> LTVExceeded (${r.revert})`);
  const before = await bal(token, alice.hex);
  r = await staking.send(alice, 'borrow', [E18(500)]);
  ok(r.ok, 'borrow 500 ok');
  eq(await bal(token, alice.hex) - before, E18(500), 'received borrowed tokens');
  eq(await staking.call('totalDebt'), E18(500), 'totalDebt = 500');
  ok(await staking.call('isTrackedBorrower', [alice.hex]) === true, 'tracked as borrower');
});

await test('withdraw requires full repayment (lending + repay-all)', async () => {
  const { chain, staking, token, alice } = await setup();
  await staking.send(alice, 'deposit', [E18(1000), 90]);
  chain.mine(2);
  await staking.send(alice, 'borrow', [E18(400)]);
  chain.warp(91n * DAY); chain.mine(11);
  let r = await staking.send(alice, 'withdraw', [E18(100)]);
  ok(!r.ok && r.revert === 'Staking__HasDebt', `debt outstanding -> HasDebt (${r.revert})`);
  await staking.send(alice, 'repay', [E18(1000)]);          // repays only the 400 owed
  eq(await staking.call('totalDebt'), 0, 'debt cleared');
  ok(await staking.call('isTrackedBorrower', [alice.hex]) === false, 'no longer a borrower');
  // full repayment resets depositBlock (flash guard on the now-pure staker): must wait MIN_DEPOSIT_BLOCKS
  r = await staking.send(alice, 'withdraw', [E18(100)]);
  ok(!r.ok && r.revert === 'Staking__FlashLoanProtection', `withdraw right after repay -> FlashLoanProtection (${r.revert})`);
  chain.mine(11);
  // interest over the 91 days shrank the stake below the original 1000, so withdraw the actual stake
  const staked = (await staking.call('getUserInfo', [alice.hex]))[0];
  ok(staked < E18(1000) && staked > E18(990), `stake reduced by interest to ${staked}`);
  r = await staking.send(alice, 'withdraw', [staked]);
  ok(r.ok, `withdraw full remaining stake after repay + 10 blocks -> ok (${r.revert ?? ''})`);
  eq(await staking.call('totalStaked'), 0, 'pool emptied');
});

await test('interest accrues, shrinks stake, funds reserve', async () => {
  const { chain, staking, alice, bob } = await setup();
  await staking.send(alice, 'deposit', [E18(1_000_000), 365]);
  await staking.send(bob,   'deposit', [E18(1_000_000), 365]);
  chain.mine(2);
  await staking.send(bob, 'borrow', [E18(400_000)]);
  const stakeBefore = (await staking.call('getUserInfo', [bob.hex]))[0];
  chain.warp(2n * YEAR); chain.mine(2);
  await staking.send(bob, 'repay', [E18(1)]);               // touch -> accrue
  const stakeAfter = (await staking.call('getUserInfo', [bob.hex]))[0];
  ok(stakeAfter < stakeBefore, `stake shrank by interest (${stakeBefore} -> ${stakeAfter})`);
  ok((await staking.call('protocolReserve')) > 0n, 'protocolReserve funded by reserve factor');
  await assertSolvent(staking, 'after interest');
});

await test('liquidation: underwater position is cleared, invariant holds', async () => {
  const { chain, staking, bob, keeper } = await setup();
  // bob is the dominant borrower so utilisation (and the interest rate) is meaningful; a long
  // horizon lets interest erode the collateral until the position is underwater.
  await staking.send(bob, 'deposit', [E18(1000), 365]);
  chain.mine(2);
  await staking.send(bob, 'borrow', [E18(500)]);
  ok((await staking.call('getUserInfo', [bob.hex]))[1] === E18(500), 'bob debt 500');
  chain.warp(80n * YEAR); chain.mine(2);
  const r = await staking.send(keeper, 'liquidate', [bob.hex]);
  ok(r.ok, `liquidate ok (${r.revert ?? ''})`);
  eq((await staking.call('getUserInfo', [bob.hex]))[1], 0, 'bob debt wiped');
  ok(await staking.call('isTrackedBorrower', [bob.hex]) === false, 'bob removed from borrowers');
  ok((await staking.call('totalLiquidations')) === 1n, 'totalLiquidations incremented');
  await assertSolvent(staking, 'after liquidation');
});

await test('liquidate reverts on a healthy position', async () => {
  const { chain, staking, alice, keeper } = await setup();
  await staking.send(alice, 'deposit', [E18(1000), 365]);
  chain.mine(2);
  await staking.send(alice, 'borrow', [E18(100)]);
  const r = await staking.send(keeper, 'liquidate', [alice.hex]);
  ok(!r.ok && r.revert === 'Staking__NotLiquidatable', `healthy -> NotLiquidatable (${r.revert})`);
});

await test('AUTONOMOUS maintenance: another user tx liquidates the underwater borrower', async () => {
  const { chain, staking, bob, carol } = await setup();
  await staking.send(bob, 'deposit', [E18(1000), 365]);
  chain.mine(2);
  await staking.send(bob, 'borrow', [E18(500)]);
  chain.warp(80n * YEAR); chain.mine(2);
  ok(await staking.call('isTrackedBorrower', [bob.hex]) === true, 'bob borrowing pre-sweep');
  // carol does an unrelated action (claimRewards works post-emission) — her tx must carry the
  // maintenance sweep and clear bob, with NO keeper bot involved.
  await staking.send(carol, 'claimRewards', []);
  ok(await staking.call('isTrackedBorrower', [bob.hex]) === false, 'bob auto-liquidated by carol tx');
  ok((await staking.call('totalAutoLiquidations')) >= 1n, 'totalAutoLiquidations incremented');
  await assertSolvent(staking, 'after autonomous sweep');
});

await test('emission: fund once, accrue, claim pays out', async () => {
  const { chain, staking, token, admin, alice } = await setup();
  await staking.send(admin, 'fundEmission', [E18(10_000_000)]);
  let r = await staking.send(admin, 'fundEmission', [E18(1)]);
  ok(!r.ok && r.revert === 'Staking__AlreadyFunded', `double fund -> AlreadyFunded (${r.revert})`);
  await staking.send(alice, 'deposit', [E18(1_000_000), 365]);
  chain.warp(30n * DAY); chain.mine(2);
  const pending = await staking.call('pendingRewards', [alice.hex]);
  ok(pending > 0n, `pendingRewards > 0 (${pending})`);
  const before = await bal(token, alice.hex);
  await staking.send(alice, 'claimRewards', []);
  ok((await bal(token, alice.hex)) > before, 'claim paid emission rewards');
  await assertSolvent(staking, 'after emission claim');
});

await test('deterministic emission: empty-pool interval is NOT captured by a latecomer', async () => {
  const { chain, staking, admin, alice } = await setup();
  await staking.send(admin, 'fundEmission', [E18(10_000_000)]);
  chain.warp(365n * DAY); chain.mine(2);                     // a full year with NO stakers
  await staking.send(alice, 'deposit', [E18(1_000_000), 365]);
  chain.mine(2);
  const pending = await staking.call('pendingRewards', [alice.hex]);
  eq(pending, 0, `no backlog at the instant of first stake (got ${pending})`);
});

await test('emergency: guardian halt blocks entry, emergencyWithdraw returns net equity', async () => {
  const { chain, staking, token, admin, alice, guardian } = await setup();
  await staking.send(admin, 'grantRole', [GUARDIAN_ROLE, guardian.hex]);
  await staking.send(alice, 'deposit', [E18(1000), 365]);
  chain.mine(2);
  await staking.send(alice, 'borrow', [E18(300)]);
  await staking.send(guardian, 'declareEmergency', []);
  ok(await staking.call('emergencyMode') === true, 'emergencyMode on');
  let r = await staking.send(alice, 'deposit', [E18(1), 90]);
  // emergency also pauses, and whenNotPaused is checked first -> EnforcedPause; either way deposit is blocked
  ok(!r.ok && (r.revert === 'Staking__EmergencyActive' || r.revert === 'EnforcedPause'), `deposit blocked (${r.revert})`);
  const before = await bal(token, alice.hex);
  r = await staking.send(alice, 'emergencyWithdraw', []);
  ok(r.ok, 'emergencyWithdraw ok');
  // net equity = staked(1000) - debt(300) = 700
  eq(await bal(token, alice.hex) - before, E18(700), 'received net equity (staked - debt)');
});

await test('tripBreaker reverts when solvent; cancelEmergency works when no breach', async () => {
  const { chain, staking, admin, alice, guardian, keeper } = await setup();
  let r = await staking.send(keeper, 'tripBreaker', []);
  ok(!r.ok && r.revert === 'Staking__NoBreach', `solvent -> NoBreach (${r.revert})`);
  await staking.send(admin, 'grantRole', [GUARDIAN_ROLE, guardian.hex]);
  await staking.send(guardian, 'declareEmergency', []);
  r = await staking.send(admin, 'cancelEmergency', []);
  ok(r.ok, 'cancelEmergency ok (no breach)');
  ok(await staking.call('emergencyMode') === false, 'emergency cleared');
});

await test('access control: fundEmission admin-only; withdrawReserve goes to treasury', async () => {
  const { chain, staking, token, admin, alice, bob, treasury } = await setup();
  let r = await staking.send(alice, 'fundEmission', [E18(1)]);
  ok(!r.ok, `non-admin fundEmission reverts (${r.revert})`);
  // build some protocolReserve via interest
  await staking.send(admin, 'deposit', [E18(1_000_000), 365]);
  await staking.send(bob,   'deposit', [E18(1_000_000), 365]);
  chain.mine(2);
  await staking.send(bob, 'borrow', [E18(400_000)]);
  chain.warp(2n * YEAR); chain.mine(2);
  await staking.send(bob, 'repay', [E18(1)]);
  const reserve = await staking.call('protocolReserve');
  ok(reserve > 0n, 'reserve present');
  const tBefore = await bal(token, treasury.hex);
  r = await staking.send(admin, 'withdrawReserve', [reserve]);
  ok(r.ok, 'withdrawReserve ok');
  ok((await bal(token, treasury.hex)) > tBefore, 'treasury received the reserve');
});

await test('standalone lock: extends; cannot reduce; expiry resets boost', async () => {
  const { chain, staking, alice } = await setup();
  await staking.send(alice, 'deposit', [E18(1000), 90]);
  chain.mine(11);
  let r = await staking.send(alice, 'lock', [80]);
  ok(!r.ok && r.revert === 'Staking__LockTooShort', `lock 80 -> LockTooShort (${r.revert})`);
  r = await staking.send(alice, 'lock', [365]);
  ok(r.ok, 'extend to 365 ok');
  eq((await staking.call('lockInfoOf', [alice.hex]))[0], 365, 'lockDays now 365');
  r = await staking.send(alice, 'lock', [100]);             // would land before current unlock
  ok(!r.ok && r.revert === 'Staking__CannotReduceLock', `shorter lock -> CannotReduceLock (${r.revert})`);
  chain.warp(366n * DAY); chain.mine(2);
  await staking.send(alice, 'claimRewards', []);            // touch -> processLockExpiry
  const info = await staking.call('lockInfoOf', [alice.hex]);
  eq(info[0], 0, 'lockDays reset after expiry');
  eq(info[2], 10000, 'boost back to base after expiry');
});

await test('solvency holds across a long mixed sequence', async () => {
  const { chain, staking, token, admin, alice, bob, carol, keeper } = await setup();
  await staking.send(admin, 'fundEmission', [E18(50_000_000)]);
  await staking.send(alice, 'deposit', [E18(5_000_000), 365]);
  await staking.send(bob,   'deposit', [E18(2_000_000), 730]);
  chain.mine(2);
  await staking.send(alice, 'borrow', [E18(1_000_000)]);
  await staking.send(bob,   'borrow', [E18(500_000)]);
  chain.warp(120n * DAY); chain.mine(3);
  await staking.send(carol, 'deposit', [E18(3_000_000), 1095]);
  await staking.send(alice, 'claimRewards', []);
  await staking.send(bob,   'repay', [E18(200_000)]);
  chain.warp(200n * DAY); chain.mine(3);
  await staking.send(carol, 'borrow', [E18(800_000)]);
  await staking.send(alice, 'repay', [E18(1_000_000)]);
  chain.warp(60n * DAY); chain.mine(11);
  await staking.send(bob, 'claimRewards', []);
  await assertSolvent(staking, 'mixed sequence');
  // backing must cover owed
  const backing = await staking.call('backing');
  const owed = await staking.call('owed');
  ok(backing + 10n ** 10n >= owed, `backing(${backing}) + dust >= owed(${owed})`);
});

console.log('');
const allGreen = summary();
process.exit(allGreen ? 0 : 1);
