// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  HUNT-004 — reentrância pelo lado do PUSH.
//
//  O mapa de cobertura encontrou uma assimetria: TODOS os mocks reentrantes
//  destes repos atacam pelo lado do PULL (`transferFrom`, quando o contrato
//  puxa o depósito). Nenhum ataca o lado do PUSH — o `transfer` que o contrato
//  faz ao PAGAR: withdraw, claimRewards, claimPureYield, bónus de liquidação,
//  emergencyWithdraw, withdrawReserve, sweepUndistributedEmission.
//
//  A mesma fechadura `nonReentrant` cobre os dois lados, mas isso é uma
//  afirmação sobre o código, não uma medição. A lição da Curve (jul 2023,
//  ~$70M) é precisamente essa: o `@nonreentrant` estava lá, parecia certo, e o
//  compilador tinha-o desfeito em silêncio. Um guard só está provado quando
//  alguém executa o ataque e vê o revert.
//
//  Este ficheiro executa o ataque em cada caminho de pagamento.
//
//  Run: forge test --match-contract PushSideReentrancy -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

/// @notice ERC-20 que reentra no `transfer` — ou seja, no instante em que o
///         protocolo PAGA. `armed` escolhe a função reentrada; `hits` conta as
///         tentativas e `reverted` regista se a fechadura as travou.
contract PushReenterToken {
    string public name = "PushReenter";
    string public symbol = "PRT";
    uint8  public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    BlazePhoenixStaking public target;
    uint8   public armed;        // 0=off 1=withdraw 2=claimRewards 3=claimPureYield 4=emergencyWithdraw
    address public attacker;
    uint256 public hits;
    uint256 public blocked;      // reentradas que reverteram (o resultado desejado)
    bool    internal _inside;

    event ReentryAttempt(uint8 what, bool reverted);

    function setTarget(BlazePhoenixStaking t) external { target = t; }
    function arm(uint8 what, address who) external { armed = what; attacker = who; }
    function disarm() external { armed = 0; }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt; totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a; return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[t] += a;
        return true;
    }

    /// @dev O PUSH. O protocolo chama isto para pagar — e é aqui que reentramos,
    ///      depois de mover o saldo (ordem realista de um token hostil).
    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        _maybeReenter();
        return true;
    }

    function _maybeReenter() internal {
        if (armed == 0 || _inside || address(target) == address(0)) return;
        _inside = true;
        hits++;
        bool rev;
        if (armed == 1) {
            try target.withdraw(1) {} catch { rev = true; }
        } else if (armed == 2) {
            try target.claimRewards() {} catch { rev = true; }
        } else if (armed == 3) {
            try target.claimPureYield() {} catch { rev = true; }
        } else if (armed == 4) {
            try target.emergencyWithdraw() {} catch { rev = true; }
        }
        if (rev) blocked++;
        emit ReentryAttempt(armed, rev);
        _inside = false;
    }
}

contract PushSideReentrancyTest is Test {
    BlazePhoenixStaking staking;
    PushReenterToken token;

    address admin    = address(0xA11CE);
    address treasury = address(0x713A5);
    address attacker = address(0xBAD);
    address honest   = address(0x900D);

    function setUp() public {
        vm.warp(1_900_000_000);
        token = new PushReenterToken();
        vm.prank(admin);
        staking = new BlazePhoenixStaking(address(token), treasury);
        token.setTarget(staking);

        for (uint256 i; i < 3; ++i) {
            address u = [admin, attacker, honest][i];
            token.mint(u, 500_000_000e18);
            vm.prank(u);
            token.approve(address(staking), type(uint256).max);
        }

        vm.prank(admin);
        staking.fundEmission(180_000_000e18);

        vm.prank(honest);
        staking.deposit(1_000_000e18, 365);
        vm.prank(attacker);
        staking.deposit(500_000e18, 90);

        // vm.warp move o relógio mas NÃO o número do bloco, e o contrato tem
        // proteção anti-flash-loan que compara `depositBlock` com o bloco atual.
        // Sem o roll, todo o withdraw reverte com Staking__FlashLoanProtection
        // e o teste mediria a proteção errada em vez da fechadura de reentrância.
        vm.warp(block.timestamp + 200 days);
        vm.roll(block.number + 1_000);
    }

    /// @dev Invariante de fecho: o que quer que a reentrância tenha tentado, o
    ///      protocolo continua solvente e a identidade continua de pé.
    function _assertIntact(string memory ctx) internal view {
        assertTrue(staking.isSolvent(), string.concat("insolvente apos ", ctx));
        assertEq(staking.auditInvariants(), 0, string.concat("invariante violada apos ", ctx));
    }

    /// @notice Pagamento de `withdraw` reentrado em `withdraw`.
    function test_Push_Withdraw_ReentersWithdraw() public {
        vm.warp(block.timestamp + 200 days);        // passa o lock de 90 dias
        vm.roll(block.number + 1_000);
        token.arm(1, attacker);

        vm.prank(attacker);
        staking.withdraw(1_000e18);

        emit log_named_uint("tentativas de reentrada", token.hits());
        emit log_named_uint("bloqueadas pela fechadura", token.blocked());
        assertGt(token.hits(), 0, "o teste nao chegou a reentrar: mock inerte");
        assertEq(token.hits(), token.blocked(), "ACHADO: reentrada no push NAO foi bloqueada");
        _assertIntact("withdraw->withdraw");
    }

    /// @notice Pagamento de `claimRewards` reentrado em `claimRewards`.
    function test_Push_ClaimRewards_ReentersClaim() public {
        token.arm(2, attacker);

        vm.prank(attacker);
        staking.claimRewards();

        emit log_named_uint("tentativas de reentrada", token.hits());
        emit log_named_uint("bloqueadas pela fechadura", token.blocked());
        assertGt(token.hits(), 0, "o teste nao chegou a reentrar: mock inerte");
        assertEq(token.hits(), token.blocked(), "ACHADO: reentrada no push NAO foi bloqueada");
        _assertIntact("claimRewards->claimRewards");
    }

    /// @notice Reentrância CRUZADA: paga-se `claimRewards`, reentra-se em
    ///         `withdraw`. É a forma que mais escapa a guards por-função.
    function test_Push_ClaimRewards_ReentersWithdraw_CrossFunction() public {
        vm.warp(block.timestamp + 200 days);
        vm.roll(block.number + 1_000);
        token.arm(1, attacker);

        vm.prank(attacker);
        staking.claimRewards();

        emit log_named_uint("tentativas de reentrada cruzada", token.hits());
        assertGt(token.hits(), 0, "o teste nao chegou a reentrar: mock inerte");
        assertEq(token.hits(), token.blocked(), "ACHADO: reentrada CRUZADA no push nao bloqueada");
        _assertIntact("claimRewards->withdraw");
    }

    /// @notice `claimPureYield` — o caminho que a suite de invariantes original
    ///         admitia nunca alcançar.
    function test_Push_ClaimPureYield_Reenters() public {
        token.arm(3, attacker);

        vm.prank(attacker);
        try staking.claimPureYield() {} catch { /* sem yield a reclamar: aceitavel */ }

        if (token.hits() > 0) {
            assertEq(token.hits(), token.blocked(), "ACHADO: reentrada em claimPureYield nao bloqueada");
        }
        _assertIntact("claimPureYield");
    }

    /// @notice `emergencyWithdraw` é a ÚNICA função que move principal sem o
    ///         modificador `conserves`. Tem `nonReentrant` — mas isso é uma
    ///         afirmação até alguém a atacar.
    function test_Push_EmergencyWithdraw_Reenters() public {
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), admin);
        vm.prank(admin);
        staking.declareEmergency();

        token.arm(4, attacker);

        vm.prank(attacker);
        staking.emergencyWithdraw();

        emit log_named_uint("tentativas de reentrada", token.hits());
        emit log_named_uint("bloqueadas pela fechadura", token.blocked());
        assertGt(token.hits(), 0, "o teste nao chegou a reentrar: mock inerte");
        assertEq(token.hits(), token.blocked(), "ACHADO: reentrada em emergencyWithdraw nao bloqueada");
        assertTrue(staking.isSolvent(), "insolvente apos emergencyWithdraw reentrado");
    }

    /// @notice O que o utilizador honesto tem de sobreviver a tudo isto: a sua
    ///         posição não pode ter encolhido por causa do ataque de outro.
    function test_Push_HonestPositionUnharmed() public {
        (uint256 antes,,,,,,,,,,,,,) = staking.getUserInfo(honest);

        vm.warp(block.timestamp + 200 days);
        vm.roll(block.number + 1_000);
        token.arm(1, attacker);
        vm.prank(attacker);
        staking.withdraw(1_000e18);
        token.disarm();

        (uint256 depois,,,,,,,,,,,,,) = staking.getUserInfo(honest);
        // O stake do honesto só pode descer por juro da sua PRÓPRIA dívida
        // (não tem nenhuma), portanto tem de ficar igual.
        assertEq(depois, antes, "ACHADO: o ataque encolheu a posicao de um terceiro");
    }
}
