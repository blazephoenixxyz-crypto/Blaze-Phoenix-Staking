// Offline compiler for the test harness: compiles the staking contract, its (inlined,
// internal) math library, and a minimal mock BZPX token — all with viaIR, the same way
// foundry.toml builds the project.
import solc from 'solc';
import fs from 'fs';
import path from 'path';

const MOCK_ERC20 = `// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
contract MockERC20 {
    string public name = "BlazePhoenix"; string public symbol = "BZPX"; uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    bool public failNextTransfer;
    function setFailNextTransfer(bool v) external { failNextTransfer = v; }
    function mint(address to, uint256 amt) external { balanceOf[to]+=amt; totalSupply+=amt; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s]=a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        if (failNextTransfer) { failNextTransfer=false; return false; }
        require(balanceOf[msg.sender]>=a, "bal"); balanceOf[msg.sender]-=a; balanceOf[to]+=a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (failNextTransfer) { failNextTransfer=false; return false; }
        require(balanceOf[f]>=a, "bal");
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al>=a,"allow"); allowance[f][msg.sender]=al-a; }
        balanceOf[f]-=a; balanceOf[to]+=a; return true;
    }
}`;

export function compileAll() {
  const read = (p) => fs.readFileSync(path.join('src', p), 'utf8');
  function findImports(p) {
    try {
      let full;
      if (p.startsWith('@openzeppelin/')) full = path.join('node_modules', p);
      else if (p.startsWith('./') || p.startsWith('../')) full = path.join('src', p);
      else full = p;
      return { contents: fs.readFileSync(full, 'utf8') };
    } catch (e) { return { error: 'File not found: ' + p }; }
  }
  const input = {
    language: 'Solidity',
    sources: {
      'src/BlazePhoenixStaking.sol': { content: read('BlazePhoenixStaking.sol') },
      'src/BlazePhoenixMathLib.sol': { content: read('BlazePhoenixMathLib.sol') },
      'MockERC20.sol': { content: MOCK_ERC20 },
    },
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
    },
  };
  const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
  if (out.errors) {
    const errs = out.errors.filter((e) => e.severity === 'error');
    if (errs.length) { errs.forEach((e) => console.log(e.formattedMessage)); throw new Error('compile failed'); }
  }
  const pick = (file, name) => ({
    abi: out.contracts[file][name].abi,
    bytecode: '0x' + out.contracts[file][name].evm.bytecode.object,
  });
  return {
    Staking: pick('src/BlazePhoenixStaking.sol', 'BlazePhoenixStaking'),
    Token: pick('MockERC20.sol', 'MockERC20'),
  };
}
