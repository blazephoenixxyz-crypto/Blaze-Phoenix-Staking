// Minimal EVM test harness over @ethereumjs/vm: deploy contracts, send state-changing txs
// (managed nonce), make view calls, and control block.timestamp / block.number for time- and
// flash-loan-dependent logic. ABI coding via ethers v6 (offline, no provider).
import { createVM, runTx } from '@ethereumjs/vm';
import { Common, Mainnet, Hardfork } from '@ethereumjs/common';
import { createBlock } from '@ethereumjs/block';
import { createLegacyTx } from '@ethereumjs/tx';
import { Address, Account, hexToBytes, bytesToHex } from '@ethereumjs/util';
import { ethers } from 'ethers';

const GAS = 30_000_000n;

export class Chain {
  constructor() {
    this.time = 1_900_000_000n;   // a fixed start far before the 7-year horizon overflows
    this.blockNum = 1n;
    this.nonces = new Map();      // address(lowercase) -> bigint
    this.wallets = {};
  }
  static async create() {
    const c = new Chain();
    c.common = new Common({ chain: Mainnet, hardfork: Hardfork.Cancun });
    c.vm = await createVM({ common: c.common });
    return c;
  }
  _block() {
    return createBlock(
      { header: { number: this.blockNum, timestamp: this.time, gasLimit: GAS, baseFeePerGas: 0n } },
      { common: this.common, skipConsensusFormatValidation: true }
    );
  }
  async fund(name, privHex) {
    const w = new ethers.Wallet(privHex);
    const addr = new Address(hexToBytes(w.address));
    await this.vm.stateManager.putAccount(addr, new Account(0n, 10n ** 30n));
    this.nonces.set(w.address.toLowerCase(), 0n);
    this.wallets[name] = { name, priv: hexToBytes(privHex), addr, hex: w.address };
    return this.wallets[name];
  }
  _nonce(hex) { return this.nonces.get(hex.toLowerCase()) ?? 0n; }
  _bump(hex) { this.nonces.set(hex.toLowerCase(), this._nonce(hex) + 1n); }

  warp(seconds) { this.time += BigInt(seconds); }
  mine(n = 1) { this.blockNum += BigInt(n); }

  async _raw(from, to, dataHex, value = 0n) {
    const acct = await this.vm.stateManager.getAccount(from.addr);
    const txData = {
      nonce: acct ? acct.nonce : 0n, gasPrice: 0n, gasLimit: GAS,
      value, data: hexToBytes(dataHex),
    };
    if (to) txData.to = to;
    const tx = createLegacyTx(txData, { common: this.common }).sign(from.priv);
    const res = await runTx(this.vm, { tx, block: this._block(), skipBalance: true, skipBlockGasLimitValidation: true });
    this.blockNum += 1n; // each tx advances a block
    return res;
  }

  async deploy(art, from, args = []) {
    const iface = new ethers.Interface(art.abi);
    const enc = args.length ? iface.encodeDeploy(args) : '0x';
    const dataHex = art.bytecode + enc.slice(2);
    const res = await this._raw(from, undefined, dataHex);
    if (res.execResult.exceptionError) throw new Error('deploy reverted: ' + JSON.stringify(res.execResult.exceptionError));
    const addr = res.createdAddress;
    return new Contract(this, addr, art.abi);
  }
}

export class Contract {
  constructor(chain, addr, abi) { this.chain = chain; this.addr = addr; this.iface = new ethers.Interface(abi); }

  // state-changing call; returns { ok, error, revert } and decoded logs
  async send(from, fn, args = [], value = 0n) {
    const data = this.iface.encodeFunctionData(fn, args);
    const res = await this.chain._raw(from, this.addr, data, value);
    const exErr = res.execResult.exceptionError;
    if (exErr) {
      return { ok: false, error: exErr.error || String(exErr), revert: decodeRevert(this.iface, res.execResult.returnValue) };
    }
    return { ok: true, logs: res.execResult.logs || [] };
  }

  // read-only call at current block context; returns decoded result (single or array)
  async call(fn, args = []) {
    const data = this.iface.encodeFunctionData(fn, args);
    const from = Object.values(this.chain.wallets)[0];
    // eth_call semantics: discard any state mutation the call performs.
    await this.chain.vm.stateManager.checkpoint();
    let res;
    try {
      res = await this.chain.vm.evm.runCall({
        caller: from.addr, to: this.addr, data: hexToBytes(data),
        gasLimit: GAS, block: this.chain._block(), gasPrice: 0n,
      });
    } finally {
      await this.chain.vm.stateManager.revert();
    }
    if (res.execResult.exceptionError) {
      throw new Error(`view ${fn} reverted: ` + (decodeRevert(this.iface, res.execResult.returnValue) || res.execResult.exceptionError.error));
    }
    const out = this.iface.decodeFunctionResult(fn, bytesToHex(res.execResult.returnValue));
    return out.length === 1 ? out[0] : out;
  }
}

function decodeRevert(iface, ret) {
  if (!ret || ret.length === 0) return null;
  const hex = bytesToHex(ret);
  try { const e = iface.parseError(hex); return e ? e.name : hex; } catch { /* maybe Error(string) */ }
  try {
    if (hex.startsWith('0x08c379a0')) {
      return ethers.AbiCoder.defaultAbiCoder().decode(['string'], '0x' + hex.slice(10))[0];
    }
  } catch {}
  return hex.slice(0, 10);
}

// tiny assertion + runner
export const E18 = (n) => BigInt(n) * 10n ** 18n;
let passed = 0, failed = 0; const failures = [];
export function ok(cond, msg) { if (cond) { passed++; } else { failed++; failures.push(msg); console.log('  ✗ ' + msg); } }
export function eq(a, b, msg) { ok(BigInt(a) === BigInt(b), `${msg} (got ${a}, want ${b})`); }
export function approx(a, b, tol, msg) { const d = a > b ? a - b : b - a; ok(d <= tol, `${msg} (got ${a}, want ~${b}, |Δ|=${d} > ${tol})`); }
export async function test(name, fn) {
  try { await fn(); console.log('✓ ' + name); }
  catch (e) { failed++; failures.push(name + ': ' + e.message); console.log('✗ ' + name + ' :: ' + e.message); }
}
export function summary() {
  console.log(`\n${'='.repeat(50)}\n  ${passed} checks passed, ${failed} failed`);
  if (failures.length) { console.log('  FAILURES:'); failures.forEach((f) => console.log('   - ' + f)); }
  console.log('='.repeat(50));
  return failed === 0;
}
