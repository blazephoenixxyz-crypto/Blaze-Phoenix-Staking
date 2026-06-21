import { compileAll } from './compile.mjs';
import { Chain, E18 } from './lib.mjs';

const art = compileAll();
const chain = await Chain.create();
const admin = await chain.fund('admin', '0x' + '11'.repeat(32));
const alice = await chain.fund('alice', '0x' + '22'.repeat(32));
const treasury = await chain.fund('treasury', '0x' + '33'.repeat(32));

const token = await chain.deploy(art.Token, admin);
console.log('token at', token.addr.toString());
await token.send(admin, 'mint', [alice.hex, E18(1000)]);
const bal = await token.call('balanceOf', [alice.hex]);
console.log('alice bal =', bal.toString(), bal === E18(1000) ? 'OK' : 'FAIL');

const staking = await chain.deploy(art.Staking, admin, [token.addr.toString(), treasury.hex]);
console.log('staking at', staking.addr.toString());
console.log('VERSION =', await staking.call('VERSION'));
console.log('MIN_LOCK_DAYS =', (await staking.call('MIN_LOCK_DAYS')).toString());
console.log('MAX_LOCK_DAYS =', (await staking.call('MAX_LOCK_DAYS')).toString());
console.log('isSolvent =', await staking.call('isSolvent'));
console.log('boostByDays(365) =', (await staking.call('boostByDays', [365])).toString());
console.log('boostByDays(2555) =', (await staking.call('boostByDays', [2555])).toString());
console.log('SMOKE OK');
