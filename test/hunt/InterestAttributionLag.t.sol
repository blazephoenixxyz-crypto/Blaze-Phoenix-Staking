// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  HUNT — ROOT CAUSE do drift `totalStaked < Σ u.staked`
//
//  Contexto. `InvariantsFullSurface.t.sol` mediu shortfalls REAIS de ~1.121 e
//  ~11.368 BZPX em duas campanhas de CI, com `totalUncollectedInterest` a ler
//  ZERO, e a invariante foi enfraquecida para `shortfall <= totalDebt` com a
//  nota "left for the auditor to rule on". Este ficheiro é essa decisão.
//
//  Hipótese (lida do código, não inferida):
//
//    _updateInterestIndex()  debita  totalStaked -= slice   EAGER, para o livro
//                            INTEIRO de dívida, sempre que alguém interage.
//    _accrueInterestFor(u)   debita  u.staked  -= interest  LAZY, só quando
//                            aquela posição concreta é tocada.
//
//  Entre os dois instantes, a diferença é interest globalmente acumulado mas
//  ainda NÃO atribuído. `totalUncollectedInterest` nunca o conta — esse contador
//  regista apenas a parte INCOBRÁVEL (o ramo do clamp em 1373-1396). Daí a
//  leitura "ZERO" que tornou o shortfall inexplicável.
//
//  Se a hipótese estiver certa, o drift é uma DESFASAGEM DE ATRIBUIÇÃO, não uma
//  fuga de valor: forçar a atribuição de todas as posições fecha o buraco até ao
//  dust. Qualquer resíduo que sobreviva a isso é fuga real — e o seu tamanho é o
//  achado.
//
//  Run: forge test --match-contract InterestAttributionLag -vvv
// =============================================================================

import {Base} from "../BlazePhoenixStaking.t.sol";

contract InterestAttributionLagTest is Base {
    /// Tolerância de dust do próprio contrato (CONSERVATION_DUST = 1e10).
    uint256 constant DUST = 1e10;

    address[] internal borrowers;

    function _gap() internal view returns (int256) {
        uint256 sum;
        for (uint256 i; i < borrowers.length; ++i) {
            (uint256 staked,,,,,,,,,,,,,) = staking.getUserInfo(borrowers[i]);
            sum += staked;
        }
        uint256 total = staking.totalStaked();
        return int256(sum) - int256(total);   // > 0  ⇒  totalStaked ABAIXO de Σ staked
    }

    /// @dev O tamanho do livro É a variável independente. `_autoMaintain` avança
    ///      o cursor UMA posição por interação, por isso num livro pequeno toda
    ///      a gente é atribuída de passagem e o desfasamento nunca é observável
    ///      — foi exatamente o que a primeira versão deste teste mediu (buraco
    ///      = 0 com 4 borrowers). O desfasamento só se torna visível quando há
    ///      mais posições do que passos de manutenção, que é o regime das
    ///      campanhas de invariante que o mediram no CI.
    function _setUpBook(uint256 n) internal {
        vm.prank(admin);
        staking.fundEmission(180_000_000e18);

        delete borrowers;
        for (uint256 i; i < n; ++i) {
            address u = address(uint160(0x10000 + i));
            token.mint(u, 10_000_000e18);
            vm.startPrank(u);
            token.approve(address(staking), type(uint256).max);
            staking.deposit(100_000e18 + i * 1_000e18, 365);
            staking.borrow(10_000e18 + i * 137e18);
            vm.stopPrank();
            borrowers.push(u);
        }
    }

    /// @dev Força a atribuição de TODAS as posições do livro.
    function _attributeAll() internal {
        for (uint256 i; i < borrowers.length; ++i) {
            vm.prank(borrowers[i]);
            staking.claimRewards();
        }
    }

    /// @notice O reprodutor determinista. Sem fuzz, sem sorte: constrói o livro,
    ///         deixa correr o tempo, força UMA interação (que debita o global
    ///         para toda a dívida) e mede o buraco antes e depois de atribuir.
    function test_DriftIsAttributionLag_NotLeak() public {
        _setUpBook(30);

        assertEq(_gap(), int256(0), "arranque tem de ser exato");

        // 90 dias de juro sobre o livro inteiro.
        vm.warp(block.timestamp + 90 days);

        // UMA interação de UM utilizador: `_updateInterestIndex` debita
        // `totalStaked` pelo juro de TODA a dívida do livro, mas só a posição
        // deste utilizador (mais um passo de manutenção) é atribuída.
        vm.prank(borrowers[0]);
        staking.claimRewards();

        int256 gapBefore = _gap();
        emit log_named_int("buraco APOS 1 interacao (wei)", gapBefore);
        assertGt(gapBefore, int256(0), "esperado: totalStaked abaixo de Sigma staked");

        // Agora força a atribuição de TODAS as posições.
        _attributeAll();

        int256 gapAfter = _gap();
        emit log_named_int("buraco APOS atribuicao total (wei)", gapAfter);
        emit log_named_uint("totalUncollectedInterest", staking.totalUncollectedInterest());
        emit log_named_uint("totalBadDebt", staking.totalBadDebt());

        // O veredito. Se isto passar: o drift é desfasagem contabilística e a
        // invariante pode ser reescrita como exata-após-atribuição.
        // Se falhar: o resíduo é fuga real e o seu valor é a severidade.
        assertLe(
            gapAfter <= int256(0) ? uint256(0) : uint256(gapAfter),
            DUST,
            "ACHADO: residuo sobrevive a atribuicao total: fuga real, nao desfasagem"
        );
    }

    /// @notice A identidade que a invariante DEVERIA afirmar. Depois de atribuir
    ///         todas as posições, `totalStaked` iguala `Σ u.staked` a menos de
    ///         dust — em qualquer instante, para qualquer histórico.
    function test_ExactIdentityAfterFullAttribution() public {
        _setUpBook(30);

        uint256[6] memory marcos = [uint256(1 days), 7 days, 30 days, 180 days, 365 days, 730 days];
        for (uint256 k; k < marcos.length; ++k) {
            // NOTA: cada marco avança a partir do anterior e faz um ciclo
            // completo de atribuição. Nunca se repete warp+view em ciclo sem
            // uma chamada de estado pelo meio — esta build do forge devolve
            // valores stale nesse padrão.
            vm.warp(block.timestamp + marcos[k]);

            _attributeAll();

            int256 g = _gap();
            emit log_named_uint("marco (dias)", marcos[k] / 1 days);
            emit log_named_int("  buraco apos atribuicao (wei)", g);
            assertLe(
                g <= int256(0) ? uint256(0) : uint256(g),
                DUST,
                "identidade quebra apos atribuicao total"
            );
        }
    }

    /// @notice Direção do arredondamento. O debito global é ⌊(Σdᵢ)·δ/WAD⌋
    ///         enquanto a soma dos débitos por utilizador é Σ⌊dᵢ·δ/WAD⌋.
    ///         Pela desigualdade do floor, o global remove SEMPRE >= a soma —
    ///         ou seja, o erro de arredondamento empurra na MESMA direção do
    ///         drift observado, e acumula com o número de janelas de juro.
    ///         Este teste mede quanto, para dimensionar a contribuição.
    function test_RoundingDirectionAccumulates() public {
        _setUpBook(30);

        // 200 janelas curtas: maximiza o número de arredondamentos.
        for (uint256 w; w < 200; ++w) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(borrowers[0]);
            staking.claimRewards();          // dispara _updateInterestIndex
        }
        _attributeAll();

        int256 g = _gap();
        emit log_named_int("buraco apos 200 janelas + atribuicao (wei)", g);
        // Envelope: no máximo 1 wei por borrower por janela.
        uint256 envelope = 200 * borrowers.length + DUST;
        assertLe(
            g <= int256(0) ? uint256(0) : uint256(g),
            envelope,
            "ACHADO: acumulacao excede o envelope do arredondamento: ha outra fonte"
        );
    }
}
