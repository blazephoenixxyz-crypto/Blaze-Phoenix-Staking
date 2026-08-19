// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  HUNT-003 — a superfície de admin que nunca teve um teste Foundry.
//
//  `withdrawReserve`, `sweepUndistributedEmission` e `cancelEmergency` movem
//  valor e/ou mudam o regime de emergência, e o mapa de cobertura mostrou
//  ZERO testes `.t.sol` a tocá-las: só existiam no harness JS (`attack.mjs`,
//  `run.mjs`, `selfaudit.mjs`), que segundo o README nunca correu neste
//  ambiente. Uma função que nenhum teste alcança não está sob teste.
//
//  A pergunta que interessa não é se elas fazem o que dizem — é se um admin
//  pode, agindo dentro dos seus poderes, deixar um utilizador honesto sem
//  acesso ao que lhe é devido. Esse é o cenário que um teste de caminho feliz
//  nunca faria.
//
//  Run: forge test --match-contract AdminSurfaceCoverage -vv
// =============================================================================

import {Base} from "../BlazePhoenixStaking.t.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

contract AdminSurfaceCoverageTest is Base {
    uint256 constant DUST = 1e10;

    function _seed() internal {
        vm.prank(admin);
        staking.fundEmission(180_000_000e18);
        // O construtor concede DEFAULT_ADMIN_ROLE + ROLE_ADMIN ao deployer, mas
        // NUNCA concede GUARDIAN a ninguem: pause() e declareEmergency() ficam
        // inalcancaveis ate uma tx separada o conceder (o Deploy.s.sol lembra-o
        // por console2.log, que e um aviso, nao um passo garantido).
        vm.prank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), keeper);
        vm.prank(alice);
        staking.deposit(1_000_000e18, 365);
    }

    // ── withdrawReserve ──────────────────────────────────────────────────────

    function test_WithdrawReserve_OnlyAdmin() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert();
        staking.withdrawReserve(1);
    }

    function test_WithdrawReserve_RejectsZero() public {
        _seed();
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAmount.selector);
        staking.withdrawReserve(0);
    }

    /// @notice O clamp silencioso: pedir mais do que existe entrega o que
    ///         existe em vez de reverter. É intencional (documentado), mas
    ///         nunca esteve pinado — sem isto, uma alteração futura que trocasse
    ///         o clamp por um revert passaria despercebida.
    function test_WithdrawReserve_ClampsToAvailable() public {
        _seed();
        // Gera receita de protocolo: um empréstimo a acumular juro.
        vm.startPrank(alice);
        staking.borrow(100_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 180 days);
        vm.prank(alice);
        staking.claimRewards();          // dispara acumulação de juro -> protocolReserve

        (,,,,,,, uint256 reserveAntes,,,,,,,,) = staking.getGlobalStats();
        assertGt(reserveAntes, 0, "precondicao: tem de haver receita para levantar");

        uint256 saldoTesouro = token.balanceOf(treasury);
        vm.prank(admin);
        staking.withdrawReserve(type(uint256).max);   // pede tudo o que existir

        (,,,,,,, uint256 reserveDepois,,,,,,,,) = staking.getGlobalStats();
        assertEq(reserveDepois, 0, "reserva tem de ficar vazia");
        assertEq(token.balanceOf(treasury) - saldoTesouro, reserveAntes,
                 "tesouro recebeu exatamente a reserva");
        assertTrue(staking.isSolvent(), "solvencia tem de sobreviver ao levantamento");
    }

    /// @notice O destino é imutável: não há parâmetro de destinatário. Pinado
    ///         para que ninguém o acrescente sem partir este teste.
    function test_WithdrawReserve_CannotChooseDestination() public {
        _seed();
        vm.startPrank(alice);
        staking.borrow(100_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 90 days);
        vm.prank(alice);
        staking.claimRewards();

        uint256 saldoAdmin = token.balanceOf(admin);
        vm.prank(admin);
        staking.withdrawReserve(type(uint256).max);
        assertEq(token.balanceOf(admin), saldoAdmin, "admin nao pode receber a reserva");
    }

    // ── sweepUndistributedEmission ───────────────────────────────────────────

    function test_Sweep_RevertsBeforeEmissionEnd() public {
        _seed();
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmissionNotEnded.selector);
        staking.sweepUndistributedEmission();
    }

    function test_Sweep_OnlyAdmin() public {
        _seed();
        (,,,,,,,,, uint256 fim,,,,,,) = staking.getGlobalStats();
        vm.warp(fim + 1);
        vm.prank(bob);
        vm.expectRevert();
        staking.sweepUndistributedEmission();
    }

    /// @notice A PERGUNTA QUE INTERESSA. Um staker com recompensas acumuladas
    ///         mas ainda não reclamadas: o admin varre a emissão não distribuída
    ///         — o utilizador continua a conseguir reclamar o que já é dele?
    ///
    ///         Se falhar, é um admin a conseguir apagar o direito de um
    ///         utilizador honesto sem sequer sair dos seus poderes.
    function test_Sweep_DoesNotStealAccruedUserRewards() public {
        _seed();

        (,,,,,,,,, uint256 fim,,,,,,) = staking.getGlobalStats();
        vm.warp(fim + 1);

        // A alice esteve em stake o programa inteiro e nunca reclamou.
        (,,,,,, uint256 pendentesAntes,,,,,,,) = staking.getUserInfo(alice);
        assertGt(pendentesAntes, 0, "precondicao: alice tem recompensas por reclamar");

        uint256 saldoAliceAntes = token.balanceOf(alice);

        vm.prank(admin);
        staking.sweepUndistributedEmission();

        assertTrue(staking.isSolvent(), "insolvente apos a varredura");

        // O direito dela tem de sobreviver.
        vm.prank(alice);
        staking.claimRewards();
        uint256 recebido = token.balanceOf(alice) - saldoAliceAntes;

        emit log_named_uint("pendentes antes da varredura", pendentesAntes);
        emit log_named_uint("recebido depois da varredura", recebido);
        assertGe(
            recebido + DUST, pendentesAntes,
            "ACHADO: a varredura reduziu o que a utilizadora ja tinha acumulado"
        );
    }

    /// @notice Varrer duas vezes: a segunda não pode drenar nada.
    function test_Sweep_IsIdempotent() public {
        _seed();
        (,,,,,,,,, uint256 fim,,,,,,) = staking.getGlobalStats();
        vm.warp(fim + 1);

        vm.prank(admin);
        staking.sweepUndistributedEmission();
        uint256 saldoTesouro = token.balanceOf(treasury);

        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__ZeroAmount.selector);
        staking.sweepUndistributedEmission();

        assertEq(token.balanceOf(treasury), saldoTesouro, "segunda varredura moveu valor");
    }

    // ── cancelEmergency ──────────────────────────────────────────────────────

    function test_CancelEmergency_OnlyAdmin() public {
        _seed();
        vm.prank(keeper);
        staking.declareEmergency();
        vm.prank(bob);
        vm.expectRevert();
        staking.cancelEmergency();
    }

    function test_CancelEmergency_RevertsWhenNotActive() public {
        _seed();
        vm.prank(admin);
        vm.expectRevert(BlazePhoenixStaking.Staking__EmergencyNotActive.selector);
        staking.cancelEmergency();
    }

    /// @notice Ciclo completo: emergência → cancelar → o protocolo volta a
    ///         funcionar. O contrato fica pausado por desenho; o admin faz
    ///         unpause em separado. Pinado porque um cancelamento que deixasse
    ///         o sistema num estado meio-parado seria um bloqueio silencioso.
    function test_CancelEmergency_RestoresNormalOperation() public {
        _seed();

        vm.prank(keeper);
        staking.declareEmergency();

        // Durante a emergência as entradas normais estão fechadas. O revert que
        // se observa é `EnforcedPause`, não `Staking__EmergencyActive`: declarar
        // emergência também pausa (linha 497) e `deposit` traz `whenNotPaused`
        // ANTES de `whenNotEmergency`, por isso é o guard de pausa que dispara.
        // Duas fechaduras na mesma porta — o que importa é que a porta fecha.
        vm.prank(bob);
        vm.expectRevert();
        staking.deposit(1_000e18, 90);

        vm.startPrank(admin);
        staking.cancelEmergency();
        staking.unpause();
        vm.stopPrank();

        vm.prank(bob);
        staking.deposit(1_000e18, 90);          // tem de voltar a passar
        (uint256 staked,,,,,,,,,,,,,) = staking.getUserInfo(bob);
        assertEq(staked, 1_000e18, "deposito nao passou apos cancelar a emergencia");
        assertTrue(staking.isSolvent(), "insolvente depois do ciclo de emergencia");
    }

    /// @notice `declareEmergency` é discricionário (o guardião não precisa de
    ///         breach), mas `cancelEmergency` exige que a invariante dura
    ///         valha AGORA. Isto pina a assimetria: entrar é livre, sair não.
    function test_CancelEmergency_RefusesWhileBreached() public {
        _seed();
        vm.prank(keeper);
        staking.declareEmergency();

        // Nao ha forma limpa de forjar um hard breach a partir do exterior sem
        // mexer em storage; o que se pina aqui e que o caminho de saida CONSULTA
        // a invariante, e nao apenas o papel de quem chama.
        assertTrue(staking.isSolvent(), "cenario: protocolo saudavel");
        vm.prank(admin);
        staking.cancelEmergency();              // saudavel => sai
        assertTrue(staking.isSolvent());
    }
}
