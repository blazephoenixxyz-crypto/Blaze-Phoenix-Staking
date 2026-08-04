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

// A token that hands control to an attacker contract on every transfer — the callback surface
// ERC-777 style tokens introduce, used to exercise the reentrancy guards for real.
const REENTRANT_ERC20 = `// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
interface IHook { function onTokenTransfer(address to, uint256 amt) external; }
contract ReentrantERC20 {
    string public name = "BlazePhoenix"; string public symbol = "BZPX"; uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    address public hook; bool public armed;
    function setHook(address h) external { hook = h; }
    function arm(bool v) external { armed = v; }
    function mint(address to, uint256 amt) external { balanceOf[to]+=amt; totalSupply+=amt; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s]=a; return true; }
    function _fire(address to, uint256 a) internal {
        if (armed && hook != address(0) && to == hook) { armed = false; IHook(hook).onTokenTransfer(to, a); }
    }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender]>=a, "bal"); balanceOf[msg.sender]-=a; balanceOf[to]+=a; _fire(to, a); return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(balanceOf[f]>=a, "bal");
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al>=a,"allow"); allowance[f][msg.sender]=al-a; }
        balanceOf[f]-=a; balanceOf[to]+=a; _fire(to, a); return true;
    }
}`;

const REENTRANT_ATTACKER = `// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
interface IStaking {
    function deposit(uint256 amount_, uint256 lockDays_) external;
    function withdraw(uint256 amount_) external;
    function claimRewards() external;
    function claimPureYield() external;
    function borrow(uint256 amount_) external;
}
interface IERC20x { function approve(address s, uint256 a) external returns (bool); }
contract Reenterer {
    IStaking public s; address public token;
    uint8 public mode; uint256 public depth; bool public succeeded; string public lastError;
    constructor(address s_, address t_) { s = IStaking(s_); token = t_; IERC20x(t_).approve(s_, type(uint256).max); }
    function setMode(uint8 m) external { mode = m; depth = 0; succeeded = false; lastError = ""; }
    function open(uint256 amt, uint256 d) external { s.deposit(amt, d); }
    function goClaim() external { s.claimRewards(); }
    function goWithdraw(uint256 a) external { s.withdraw(a); }
    function onTokenTransfer(address, uint256) external {
        if (depth > 0) return;
        depth = 1;
        if (mode == 1) { try s.claimRewards() { succeeded = true; } catch Error(string memory e) { lastError = e; } catch { lastError = "custom"; } }
        else if (mode == 2) { try s.withdraw(1) { succeeded = true; } catch Error(string memory e) { lastError = e; } catch { lastError = "custom"; } }
        else if (mode == 3) { try s.deposit(1000, 90) { succeeded = true; } catch Error(string memory e) { lastError = e; } catch { lastError = "custom"; } }
        else if (mode == 4) { try s.claimPureYield() { succeeded = true; } catch Error(string memory e) { lastError = e; } catch { lastError = "custom"; } }
    }
}`;

// Non-standard ERC20 boundary cases: no return value (USDT-style), a transfer fee, and a
// recipient-specific refusal (blacklist-style).
const ODD_TOKENS = `// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
contract NoReturnERC20 {
    string public name="BlazePhoenix"; string public symbol="BZPX"; uint8 public decimals=18;
    uint256 public totalSupply;
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    function mint(address to,uint256 a) external { balanceOf[to]+=a; totalSupply+=a; }
    function approve(address s,uint256 a) external { allowance[msg.sender][s]=a; }
    function transfer(address to,uint256 a) external { require(balanceOf[msg.sender]>=a,"bal"); balanceOf[msg.sender]-=a; balanceOf[to]+=a; }
    function transferFrom(address f,address to,uint256 a) external {
        require(balanceOf[f]>=a,"bal");
        uint256 al=allowance[f][msg.sender];
        if(al!=type(uint256).max){require(al>=a,"allow");allowance[f][msg.sender]=al-a;}
        balanceOf[f]-=a; balanceOf[to]+=a;
    }
}
contract FeeOnTransferERC20 {
    string public name="BlazePhoenix"; string public symbol="BZPX"; uint8 public decimals=18;
    uint256 public totalSupply; uint256 public feeBps;
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    function setFee(uint256 f) external { feeBps=f; }
    function mint(address to,uint256 a) external { balanceOf[to]+=a; totalSupply+=a; }
    function approve(address s,uint256 a) external returns(bool){ allowance[msg.sender][s]=a; return true; }
    function _mv(address f,address to,uint256 a) internal {
        require(balanceOf[f]>=a,"bal"); uint256 fee=a*feeBps/10000;
        balanceOf[f]-=a; balanceOf[to]+=a-fee; balanceOf[address(1)]+=fee;
    }
    function transfer(address to,uint256 a) external returns(bool){ _mv(msg.sender,to,a); return true; }
    function transferFrom(address f,address to,uint256 a) external returns(bool){
        uint256 al=allowance[f][msg.sender];
        if(al!=type(uint256).max){require(al>=a,"allow");allowance[f][msg.sender]=al-a;}
        _mv(f,to,a); return true;
    }
}
contract BlacklistERC20 {
    string public name="BlazePhoenix"; string public symbol="BZPX"; uint8 public decimals=18;
    uint256 public totalSupply;
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    mapping(address=>bool) public blocked;
    function block_(address a,bool v) external { blocked[a]=v; }
    function mint(address to,uint256 a) external { balanceOf[to]+=a; totalSupply+=a; }
    function approve(address s,uint256 a) external returns(bool){ allowance[msg.sender][s]=a; return true; }
    function transfer(address to,uint256 a) external returns(bool){
        require(!blocked[to],"blocked"); require(balanceOf[msg.sender]>=a,"bal");
        balanceOf[msg.sender]-=a; balanceOf[to]+=a; return true;
    }
    function transferFrom(address f,address to,uint256 a) external returns(bool){
        require(!blocked[to],"blocked"); require(balanceOf[f]>=a,"bal");
        uint256 al=allowance[f][msg.sender];
        if(al!=type(uint256).max){require(al>=a,"allow");allowance[f][msg.sender]=al-a;}
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
      'ReentrantERC20.sol': { content: REENTRANT_ERC20 },
      'OddTokens.sol': { content: ODD_TOKENS },
      'Reenterer.sol': { content: REENTRANT_ATTACKER },
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
    ReentrantToken: pick('ReentrantERC20.sol', 'ReentrantERC20'),
    NoReturnToken: pick('OddTokens.sol', 'NoReturnERC20'),
    FeeToken: pick('OddTokens.sol', 'FeeOnTransferERC20'),
    BlacklistToken: pick('OddTokens.sol', 'BlacklistERC20'),
    Reenterer: pick('Reenterer.sol', 'Reenterer'),
  };
}
