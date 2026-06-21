const solc = require('solc');
const fs = require('fs');
const path = require('path');

function findImports(p) {
  try {
    let full;
    if (p.startsWith('@openzeppelin/')) {
      full = path.join('node_modules', p);
    } else if (p.startsWith('./') || p.startsWith('../')) {
      full = path.join('src', p);
    } else {
      full = p;
    }
    return { contents: fs.readFileSync(full, 'utf8') };
  } catch (e) {
    return { error: 'File not found: ' + p };
  }
}

const input = {
  language: 'Solidity',
  sources: {
    'src/BlazePhoenixStaking.sol': { content: fs.readFileSync('src/BlazePhoenixStaking.sol','utf8') },
    'src/BlazePhoenixMathLib.sol': { content: fs.readFileSync('src/BlazePhoenixMathLib.sol','utf8') },
  },
  settings: {
    optimizer: { enabled: true, runs: 200 }, viaIR: true,
    outputSelection: { '*': { '*': ['abi','evm.bytecode.object'] } },
  },
};

const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
let hasError = false;
if (out.errors) {
  for (const e of out.errors) {
    console.log(e.formattedMessage);
    if (e.severity === 'error') hasError = true;
  }
}
if (hasError) { console.log('=== COMPILATION FAILED ==='); process.exit(1); }
const c = out.contracts['src/BlazePhoenixStaking.sol']['BlazePhoenixStaking'];
const sz = c.evm.bytecode.object.length / 2;
console.log('=== COMPILATION OK ===');
console.log('Deployed bytecode size (creation):', sz, 'bytes');
