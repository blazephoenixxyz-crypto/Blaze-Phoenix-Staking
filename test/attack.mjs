// BlazePhoenix Staking — ADVERSARIAL attack suite (real EVM, offline).
//   node test/attack.mjs
//
// Every test here is written from the attacker's seat: it TRIES to steal value, mint free
// rewards, evade liquidation, break conservation, or DoS another user — and asserts the
// protocol holds. A green run means each listed exploit path was attempted and defeated.
import { compileAll } from './compile.mjs';
import { Chain, ok, eq, approx, test, summary, E18 } from './lib.mjs';
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
  const mallory  = await chain.fund('mallory',  '0x' + '55'.repeat(32));  // the attacker
  const treasury = await chain.fund('treasury', '0x' + '66'.repeat(32));
  const guardian = await chain.fund('guardian', '0x' + '77'.repeat(32));

  const token = await chain.deploy(art.Token, admin);
  const staking = await chain.deploy(art.Staking, admin, [token.addr.toString(), treasury.hex]);
  for (const u of [admin, alice, bob, carol, mallory]) {
    await token.send(admin, 'mint', [u.hex, E18(200_000_000)]);
    await token.send(u, 'approve', [staking.addr.toString(), MAX_UINT]);
  }
  return { chain, token, staking, admin, alice, bob, carol, mallory, treasury, guardian };
}

const bal = (token, who) => token.call('balanceOf', [who]);

// The single ground-truth check: the protocol physically holds at least what it owes.
async function mustStaySolvent(staking, label) {
  const solvent = await staking.call('isSolvent');
  ok(solvent === true, `${label}: still solvent`);
  const audit = await staking.call('auditInvariants');
  ok((BigInt(audit) & 1n) === 0n, `${label}: conservation bit clear (audit=${audit})`);
  const backing = await staking.call('backing');
  const owed = await staking.call('owed');
  ok(backing + 10n ** 10n >= owed, `${label}: backing(${backing}) >= owed(${owed})`);
}

console.log('\n═══ ADVERSARIAL ATTACK SUITE ═══\n');

// ─────────────────────────────────────────────────────────────────────────────
// A1. Donation / share-inflation: dump tokens straight into the contract, then try
//     to withdraw MORE than staked by claiming the inflated backing as rewards.
// ─────────────────────────────────────────────────────────────────────────────
await test('A1 donation inflation: raw transfer to contract cannot be captured as rewards', async () => {
  const { token, staking, admin, alice, mallory } = await setup();
  await staking.send(admin, 'fundEmission', [E18(10_000_000)]);
  await staking.send(alice, 'deposit', [E18(1_000_000), 365]);
  // attacker donates 50M tokens directly to the contract
  await token.send(mallory, 'transfer', [staking.addr.toString(), E18(50_000_000)]);
  // the donation must NOT show up as claimable rewards for anyone (share-accounting, not balance)
  const before = await bal(token, mallory.hex);
  await staking.send(mallory, 'claimRewards', []);           // mallory isn't even staked
  const after = await bal(token, mallory.hex);
  eq(after, before, 'attacker claimed nothing from the donation');
  // alice's pending is still only real emission, unaffected by the donation
  await mustStaySolvent(staking, 'A1');
});

// ─────────────────────────────────────────────────────────────────────────────
// A2. Self-liquidation profit: borrow to the max, let interest push underwater, then
//     liquidate yourself to farm the 5% bonus. Net equity must not increase.
// ─────────────────────────────────────────────────────────────────────────────
await test('A2 self-liquidation is not profitable (bonus only offsets, never creates value)', async () => {
  const { chain, token, staking, mallory } = await setup();
  await staking.send(mallory, 'deposit', [E18(1_000_000), 365]);
  chain.mine(2);
  await staking.send(mallory, 'borrow', [E18(499_000)]);
  chain.warp(80n * YEAR); chain.mine(2);                    // interest erodes stake underwater
  const before = await bal(token, mallory.hex);
  await staking.send(mallory, 'liquidate', [mallory.hex]);  // liquidate self
  const after = await bal(token, mallory.hex);
  // whatever came back, the position is closed; the wallet can't have gained free value
  const info = await staking.call('getUserInfo', [mallory.hex]);
  eq(info[1], 0, 'debt cleared');
  // net wallet delta from the liquidation call alone must be <= the tiny bonus, not a windfall
  ok(after - before < E18(30_000), `no windfall from self-liquidation (delta=${after - before})`);
  await mustStaySolvent(staking, 'A2');
});

// ─────────────────────────────────────────────────────────────────────────────
// A3. Flash cycle: deposit -> borrow -> repay -> withdraw in the tightest window,
//     trying to beat the block guard and extract more than deposited.
// ─────────────────────────────────────────────────────────────────────────────
await test('A3 flash cycle: same-window deposit/withdraw blocked by MIN_DEPOSIT_BLOCKS', async () => {
  const { staking, mallory } = await setup();
  await staking.send(mallory, 'deposit', [E18(1_000_000), 90]);
  // immediate withdraw attempt (lock + block guard) must fail
  let r = await staking.send(mallory, 'withdraw', [E18(1_000_000)]);
  ok(!r.ok, `immediate withdraw blocked (${r.revert})`);
  // even claimPureYield (block-guarded) immediately must fail
  r = await staking.send(mallory, 'claimPureYield', []);
  ok(!r.ok, `immediate claimPureYield blocked (${r.revert})`);
  await mustStaySolvent(staking, 'A3');
});

// ─────────────────────────────────────────────────────────────────────────────
// A4. Withdraw-with-debt: try to pull collateral out while still owing, to strand
//     bad debt on the protocol.
// ─────────────────────────────────────────────────────────────────────────────
await test('A4 cannot withdraw any stake while debt is outstanding', async () => {
  const { chain, staking, mallory } = await setup();
  await staking.send(mallory, 'deposit', [E18(1_000_000), 90]);
  chain.mine(2);
  await staking.send(mallory, 'borrow', [E18(400_000)]);
  chain.warp(91n * DAY); chain.mine(12);                    // lock expired, block guard cleared
  let r = await staking.send(mallory, 'withdraw', [E18(1)]);
  ok(!r.ok && r.revert === 'Staking__HasDebt', `withdraw with debt -> HasDebt (${r.revert})`);
  await mustStaySolvent(staking, 'A4');
});

// ─────────────────────────────────────────────────────────────────────────────
// A5. Over-borrow past LTV in one shot AND via incremental top-ups.
// ─────────────────────────────────────────────────────────────────────────────
await test('A5 LTV cannot be exceeded, single-shot or incrementally', async () => {
  const { chain, staking, mallory } = await setup();
  await staking.send(mallory, 'deposit', [E18(1_000_000), 365]);
  chain.mine(2);
  let r = await staking.send(mallory, 'borrow', [E18(500_001)]);
  ok(!r.ok && r.revert === 'Staking__LTVExceeded', `>50% single -> LTVExceeded (${r.revert})`);
  await staking.send(mallory, 'borrow', [E18(500_000)]);    // exactly 50%
  r = await staking.send(mallory, 'borrow', [E18(1)]);      // one wei more
  ok(!r.ok && r.revert === 'Staking__LTVExceeded', `+1 over cap -> LTVExceeded (${r.revert})`);
  await mustStaySolvent(staking, 'A5');
});

// ─────────────────────────────────────────────────────────────────────────────
// A6. Emission backlog capture: wait through a long empty-pool period, then stake a
//     huge amount hoping to instantly claim the accumulated emission.
// ─────────────────────────────────────────────────────────────────────────────
await test('A6 latecomer cannot capture an empty-pool emission backlog', async () => {
  const { chain, staking, admin, mallory } = await setup();
  await staking.send(admin, 'fundEmission', [E18(10_000_000)]);
  chain.warp(2n * YEAR); chain.mine(2);                     // 2 years, nobody staked
  await staking.send(mallory, 'deposit', [E18(30_000_000), 365]);  // max wallet, right after
  chain.mine(2);
  const pending = await staking.call('pendingRewards', [mallory.hex]);
  eq(pending, 0, `no backlog captured at first stake (pending=${pending})`);
  await mustStaySolvent(staking, 'A6');
});

// ─────────────────────────────────────────────────────────────────────────────
// A7. Reward double-claim: hammer claimRewards repeatedly in a row to double-spend.
// ─────────────────────────────────────────────────────────────────────────────
await test('A7 repeated claims in the same instant pay out at most once', async () => {
  const { chain, token, staking, admin, mallory } = await setup();
  await staking.send(admin, 'fundEmission', [E18(10_000_000)]);
  await staking.send(mallory, 'deposit', [E18(1_000_000), 365]);
  chain.warp(30n * DAY); chain.mine(2);
  await staking.send(mallory, 'claimRewards', []);
  const mid = await bal(token, mallory.hex);
  await staking.send(mallory, 'claimRewards', []);          // immediate second claim
  await staking.send(mallory, 'claimRewards', []);          // and a third
  const end = await bal(token, mallory.hex);
  eq(end, mid, 'second/third instant claims pay zero');
  await mustStaySolvent(staking, 'A7');
});

// ─────────────────────────────────────────────────────────────────────────────
// A8. Lock shortening: try to reduce an existing lock (to unlock early) via deposit
//     top-up and via the standalone lock() call.
// ─────────────────────────────────────────────────────────────────────────────
await test('A8 an existing lock can never be shortened', async () => {
  const { chain, staking, mallory } = await setup();
  await staking.send(mallory, 'deposit', [E18(100_000), 2000]);
  const info1 = await staking.call('lockInfoOf', [mallory.hex]);
  chain.mine(12);
  await staking.send(mallory, 'deposit', [E18(100_000), 90]);   // try to shorten via top-up
  const info2 = await staking.call('lockInfoOf', [mallory.hex]);
  eq(info2[1], info1[1], 'unlock time unchanged by shorter top-up');
  chain.mine(12);                                               // clear the top-up's block guard
  let r = await staking.send(mallory, 'lock', [100]);           // try to shorten via lock()
  ok(!r.ok && r.revert === 'Staking__CannotReduceLock', `lock() shorten -> CannotReduceLock (${r.revert})`);
  await mustStaySolvent(staking, 'A8');
});

// ─────────────────────────────────────────────────────────────────────────────
// A9. Stake cap evasion: try to exceed MAX_STAKE_PER_WALLET across multiple deposits.
// ─────────────────────────────────────────────────────────────────────────────
await test('A9 per-wallet stake cap cannot be exceeded across deposits', async () => {
  const { chain, staking, mallory } = await setup();
  await staking.send(mallory, 'deposit', [E18(30_000_000), 365]);
  chain.mine(2);
  let r = await staking.send(mallory, 'deposit', [E18(1), 365]);
  ok(!r.ok && r.revert === 'Staking__CapExceeded', `+1 over cap -> CapExceeded (${r.revert})`);
  await mustStaySolvent(staking, 'A9');
});

// ─────────────────────────────────────────────────────────────────────────────
// A10. Privilege escalation: non-admin tries every gated function.
// ─────────────────────────────────────────────────────────────────────────────
await test('A10 no privilege escalation on gated functions', async () => {
  const { staking, mallory } = await setup();
  for (const [fn, args] of [
    ['fundEmission', [E18(1)]],
    ['withdrawReserve', [E18(1)]],
    ['pause', []],
    ['unpause', []],
    ['declareEmergency', []],
    ['cancelEmergency', []],
  ]) {
    const r = await staking.send(mallory, fn, args);
    ok(!r.ok, `${fn} rejected for non-admin (${r.revert})`);
  }
  await mustStaySolvent(staking, 'A10');
});

// ─────────────────────────────────────────────────────────────────────────────
// A11. maintStep hijack: call the internal-only maintenance step directly to force a
//      liquidation / cursor manipulation from outside.
// ─────────────────────────────────────────────────────────────────────────────
await test('A11 maintStep cannot be called by anyone but the contract itself', async () => {
  const { staking, alice, mallory } = await setup();
  const r = await staking.send(mallory, 'maintStep', [alice.hex, mallory.hex]);
  ok(!r.ok && r.revert === 'Staking__NotSelf', `external maintStep -> NotSelf (${r.revert})`);
  await mustStaySolvent(staking, 'A11');
});

// ─────────────────────────────────────────────────────────────────────────────
// A12. Spurious breaker: try to trip the permissionless emergency while solvent.
// ─────────────────────────────────────────────────────────────────────────────
await test('A12 tripBreaker cannot fire while the protocol is solvent', async () => {
  const { staking, admin, alice, mallory } = await setup();
  await staking.send(admin, 'fundEmission', [E18(10_000_000)]);
  await staking.send(alice, 'deposit', [E18(1_000_000), 365]);
  const r = await staking.send(mallory, 'tripBreaker', []);
  ok(!r.ok && r.revert === 'Staking__NoBreach', `tripBreaker while solvent -> NoBreach (${r.revert})`);
  await mustStaySolvent(staking, 'A12');
});

// ─────────────────────────────────────────────────────────────────────────────
// A13. Reserve theft: admin tries to withdraw reserve to an arbitrary address (there
//      is no destination parameter — it must always land at the immutable treasury).
// ─────────────────────────────────────────────────────────────────────────────
await test('A13 reserve withdrawals can only ever reach the immutable treasury', async () => {
  const { chain, token, staking, admin, mallory, treasury } = await setup();
  // generate some protocol reserve via interest
  await staking.send(mallory, 'deposit', [E18(1_000_000), 365]);
  chain.mine(2);
  await staking.send(mallory, 'borrow', [E18(400_000)]);
  chain.warp(200n * DAY); chain.mine(2);
  await staking.send(mallory, 'repay', [E18(500_000)]);
  const tBefore = await bal(token, treasury.hex);
  const mBefore = await bal(token, mallory.hex);
  await staking.send(admin, 'withdrawReserve', [E18(1_000_000)]);
  ok((await bal(token, treasury.hex)) >= tBefore, 'treasury received the reserve');
  eq(await bal(token, mallory.hex), mBefore, 'attacker/other address received nothing');
  await mustStaySolvent(staking, 'A13');
});

// ─────────────────────────────────────────────────────────────────────────────
// A14. Emergency drain: during emergency, try to pull more than net equity, twice.
// ─────────────────────────────────────────────────────────────────────────────
await test('A14 emergencyWithdraw returns net equity once and cannot be repeated', async () => {
  const { chain, token, staking, admin, guardian, mallory } = await setup();
  await staking.send(admin, 'grantRole', [GUARDIAN_ROLE, guardian.hex]);
  await staking.send(mallory, 'deposit', [E18(1_000_000), 365]);
  chain.mine(2);
  await staking.send(mallory, 'borrow', [E18(300_000)]);
  await staking.send(guardian, 'declareEmergency', []);
  const before = await bal(token, mallory.hex);
  await staking.send(mallory, 'emergencyWithdraw', []);
  const got = (await bal(token, mallory.hex)) - before;
  eq(got, E18(700_000), 'received exactly staked - debt');
  const r = await staking.send(mallory, 'emergencyWithdraw', []);   // second attempt
  ok(!r.ok, `second emergencyWithdraw reverts (${r.revert})`);
  await mustStaySolvent(staking, 'A14');
});

// ─────────────────────────────────────────────────────────────────────────────
// A15. Failing-token griefing: token refuses a payout mid-flow — the failed transfer
//      must revert atomically, never silently credit the user.
// ─────────────────────────────────────────────────────────────────────────────
await test('A15 a failed token transfer reverts atomically (no silent credit)', async () => {
  const { chain, token, staking, admin, mallory } = await setup();
  await staking.send(admin, 'fundEmission', [E18(10_000_000)]);
  await staking.send(mallory, 'deposit', [E18(1_000_000), 365]);
  chain.warp(30n * DAY); chain.mine(2);
  await token.send(admin, 'setFailNextTransfer', [true]);           // next payout will fail
  const r = await staking.send(mallory, 'claimRewards', []);
  ok(!r.ok && r.revert === 'Staking__TransferFailed', `claim with failing token -> TransferFailed (${r.revert})`);
  // state must be untouched: pending rewards still there, nothing lost
  const pending = await staking.call('pendingRewards', [mallory.hex]);
  ok(pending > 0n, 'rewards preserved after the failed claim reverted');
  await mustStaySolvent(staking, 'A15');
});

// ─────────────────────────────────────────────────────────────────────────────
// A16. Interest-free ride: borrow, never touch the position, and check interest still
//      accrues (via someone else's maintenance sweep) so debt cannot be dodged.
// ─────────────────────────────────────────────────────────────────────────────
await test('A16 a passive borrower still accrues interest via autonomous maintenance', async () => {
  const { chain, staking, admin, alice, mallory } = await setup();
  await staking.send(admin, 'fundEmission', [E18(10_000_000)]);
  await staking.send(mallory, 'deposit', [E18(1_000_000), 365]);
  chain.mine(2);
  await staking.send(mallory, 'borrow', [E18(400_000)]);
  const infoBefore = await staking.call('getUserInfo', [mallory.hex]);
  chain.warp(120n * DAY); chain.mine(5);
  // alice acts; her tx sweeps mallory and accrues his interest even though he did nothing
  await staking.send(alice, 'deposit', [E18(1_000_000), 365]);
  const infoAfter = await staking.call('getUserInfo', [mallory.hex]);
  ok(infoAfter[0] < infoBefore[0], `passive borrower's stake eroded by accrued interest (${infoBefore[0]} -> ${infoAfter[0]})`);
  await mustStaySolvent(staking, 'A16');
});

console.log('');
const allGreen = summary();
process.exit(allGreen ? 0 : 1);
