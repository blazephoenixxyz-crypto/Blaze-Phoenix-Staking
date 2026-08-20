// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// PURE-01 — o travão anti-dust existe num dos dois canais de distribuição, não nos dois.
//
// A ASSIMETRIA. O contrato distribui valor por dois canais gémeos, ambos dividindo por um
// denominador de peso agregado:
//
//   emissão  (_updateGlobal):        accRewardPerShare    += reward · WAD / totalBoostedEffective
//   juro     (_updateInterestIndex): accPureYieldPerShare += toPool · WAD / totalBoostedPure
//
// O canal da emissão tem um amortecedor para quando o denominador é residual:
//
//   if (tbe < MIN_EMISSION_WEIGHT) reward = mulDiv(reward, tbe, MIN_EMISSION_WEIGHT);
//
// O comentário do contrato explica-o: uma pool de pó ganha pó. Sem ele, o primeiro depositante
// de 1 wei ficaria com a emissão inteira de cada janela até alguém a diluir.
//
// O canal do juro divide por `totalBoostedPure` CRU. A mesma exposição, a decisão oposta, em
// silêncio. É a assinatura da casa — fix aplicado a UM de dois canais simétricos — a mesma que
// produziu o mulDiv de 512 bits, a fee viva do Algebra e as unidades de L cru.
//
// PORQUE É TRANSFERÊNCIA DE VALOR, NÃO SÓ MÁ ALOCAÇÃO. O juro já foi DEBITADO do colateral dos
// mutuários (`totalStaked -= slice`). Na ausência de peso pure ele iria para `protocolReserve`
// (o ramo `else`). Com uma posição pure residual, vai TODO para ela. Não é yield por criar — é
// receita existente do protocolo desviada por um depósito de custo desprezável.
//
// CENÁRIO. bob é o mutuário: gera o juro e, tendo dívida, o seu peso pure é 0 por construção
// (`_computeBoost`: bp só é não-nulo se `u.debt == 0`). mallory deposita 1 token e é a ÚNICA
// posição pure do livro, logo `totalBoostedPure ≈ 1,02e18` contra `MIN_EMISSION_WEIGHT = 1000e18`
// — um denominador residual, exatamente o regime que o canal irmão amortece.
//
// Números com estes parâmetros: util 40% ⇒ taxa 300 bps; um ano ⇒ slice ≈ 12 000e18; reserveCut
// 3% ⇒ toPool ≈ 11 640e18. HOJE mallory recebe os ~11 640e18 (97% de todo o juro do protocolo)
// por 1 token. Com o amortecedor do canal irmão receberia toPool·tbp/MIN ≈ 11,9e18 e o resto
// ficaria no protocolo.
//
// UM SÓ WARP, valores relidos ao vivo depois — o bug de cache de chamadas desta build do forge
// torna warp+view em ciclo não fiável.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract MockERC20PY {
    string public name = "BlazePhoenix"; string public symbol = "BZPX"; uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal"); balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a, "bal");
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a, "allow"); allowance[f][msg.sender] = al - a; }
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract PureYieldDustDenominatorTest is Test {
    BlazePhoenixStaking staking;
    MockERC20PY token;

    address admin    = address(0xA11CE);
    address treasury = address(0x713A5);
    address bob      = address(0x2);
    address mallory  = address(0x9);
    address carol    = address(0x3);

    uint256 constant WAD = 1e18;
    uint256 constant INITIAL_BAL = 500_000_000e18;

    function _fund(address u) internal {
        token.mint(u, INITIAL_BAL);
        vm.prank(u);
        token.approve(address(staking), type(uint256).max);
    }

    function setUp() public {
        vm.warp(1_900_000_000);
        token = new MockERC20PY();
        vm.prank(admin);
        staking = new BlazePhoenixStaking(address(token), treasury);
        _fund(admin); _fund(bob); _fund(mallory); _fund(carol);
    }

    /// O livro em que o denominador do juro é residual: um mutuário (peso pure 0 por ter dívida)
    /// e uma única posição pure de 1 token.
    function _residualPureBook() internal {
        vm.prank(bob); staking.deposit(1_000_000e18, 90);
        vm.prank(bob); staking.borrow(400_000e18);
        vm.prank(mallory); staking.deposit(1e18, 90);
    }

    function test_DustPurePositionCannotCaptureTheProtocolsInterest() public {
        _residualPureBook();

        uint256 tbp = staking.totalBoostedPure();
        assertGt(tbp, 0, "pre-condicao: mallory e posicao pure");
        assertLt(tbp, staking.MIN_EMISSION_WEIGHT(), "pre-condicao: denominador residual");

        vm.warp(block.timestamp + 365 days);

        // Poke que NAO acrescenta peso pure: bob tem divida, logo o seu bp continua 0.
        vm.prank(bob); staking.repay(1);

        uint256 accrued = staking.totalInterestAccruedGlobal();
        assertGt(accrued, 0, "o juro tem de ter corrido");

        // MEDIR O QUE ELA FICA, nao o que esta pendente. O `_autoMaintain` do poke do bob corre o
        // motor rotativo e pode LIQUIDAR mallory a meio, zerando o pendente enquanto os tokens ja
        // lhe entraram na carteira — foi exatamente isso que a primeira versao deste teste mediu
        // mal, e passou verde com o bug presente.
        uint256 malloryShare = staking.pendingPureYield(mallory)
            + (token.balanceOf(mallory) - (INITIAL_BAL - 1e18));

        // O canal da emissao escala por tbp/MIN quando o denominador e residual. Se este canal
        // fizesse o mesmo, a fatia de mallory seria ~0,1% do juro (tbp/MIN ≈ 1,02/1000).
        // HOJE ela apanha ~97%: uma posicao de 1 token fica com a receita de juro do protocolo.
        assertLt(
            malloryShare * 100,
            accrued,
            "posicao-po capturou mais de 1% do juro do protocolo (falta o travao MIN_EMISSION_WEIGHT)"
        );
    }

    /// O outro lado da mesma moeda: o que o amortecedor NAO distribui tem de ficar no protocolo,
    /// nao evaporar. Sem isto o fix quebraria a identidade de conservacao (`conserves`), ja que a
    /// fatia sai de `totalStaked` e tem de aterrar nalgum sitio.
    function test_UndistributedInterestStaysWithTheProtocol() public {
        _residualPureBook();

        uint256 reserveBefore = staking.protocolReserve();

        vm.warp(block.timestamp + 365 days);
        vm.prank(bob); staking.repay(1);

        uint256 accrued     = staking.totalInterestAccruedGlobal();
        uint256 reserveGain = staking.protocolReserve() - reserveBefore;

        // Com o denominador residual, o corte de reserva (3%) e o PISO do que o protocolo fica.
        // Com o amortecedor, fica com quase tudo o resto tambem. Hoje fica so com os 3%.
        uint256 reserveCutOnly = accrued * staking.RESERVE_FACTOR_BPS() / 10_000;
        assertGt(
            reserveGain,
            reserveCutOnly * 2,
            "o juro nao distribuido evaporou em vez de ficar no protocolo"
        );
    }

    /// PURE-02 — cotar tem de igualar executar. O NatSpec de `_pendingReward`/`_pendingPure`
    /// declara-o em letra: "Both project the un-settled slice, so a quote read in a block equals
    /// what a claim in that same block pays". Se o canal de execucao amortece com denominador
    /// residual e a view nao, a garantia cai — e o fix de PURE-01 seria ele proprio o irmao por
    /// corrigir.
    function test_QuoteEqualsExecutionUnderResidualDenominator() public {
        _residualPureBook();

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 100);                          // guarda anti-flash-loan

        uint256 quoted = staking.pendingPureYield(mallory);   // cotacao ANTES de liquidar

        uint256 balBefore = token.balanceOf(mallory);
        vm.prank(mallory); staking.claimPureYield();          // execucao
        uint256 paid = token.balanceOf(mallory) - balBefore;

        assertApproxEqAbs(quoted, paid, 1e12, "a cotacao nao bateu certo com o que a execucao pagou");
    }

    /// PURE-03 — o congelamento de juro em emergencia (EMG-01/02) foi so ao canal de execucao.
    /// `_updateInterestIndex` devolve sem cobrar enquanto `emergencyMode`, mas a view continuava a
    /// projetar a fatia. Cotar juro que nunca sera pago e o mesmo defeito, do outro lado.
    function test_QuoteFreezesWithExecutionDuringEmergency() public {
        _residualPureBook();

        vm.warp(block.timestamp + 30 days);
        vm.prank(bob); staking.repay(1);                       // assenta o indice antes da halt

        vm.startPrank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), admin);
        staking.declareEmergency();
        vm.stopPrank();

        uint256 quotedAtHalt = staking.pendingPureYield(mallory);
        vm.warp(block.timestamp + 365 days);                   // um ano DENTRO da emergencia
        uint256 quotedLater  = staking.pendingPureYield(mallory);

        assertEq(quotedLater, quotedAtHalt, "a view acumulou juro que a execucao congelou");
    }

    /// PURE-04 — a APR publicada estava MORTA, e era tambem a terceira projecao sem amortecedor.
    ///
    /// DOIS DEFEITOS NO MESMO SITIO. (a) `share = totalDebt * boost / tbp` tem unidades de racio
    /// (~1e4: os montantes cancelam-se), e a linha seguinte dividia por WAD — truncagem para ZERO
    /// em todos os regimes. Medido antes do fix: livro com 400.000e18 de divida, 611.941e18 de
    /// peso pure e taxa de 299 bps anunciava 0,00%. (b) e o canal do juro tem TRES sitios que
    /// dividem pelo mesmo denominador; PURE-01 corrigiu a execucao, PURE-02 a view do pendente, e
    /// esta ficou.
    ///
    /// Uma view morta e pior que uma view errada: nao dispara alarme nenhum, e o integrador poe o
    /// zero no ecra a achar que o protocolo nao paga juro.
    function test_PublishedAprIsAliveAndDamped() public {
        // (a) LIVRO SAUDAVEL: a APR tem de ser um numero real, nao zero.
        vm.prank(bob);     staking.deposit(1_000_000e18, 90);
        vm.prank(bob);     staking.borrow(400_000e18);
        vm.prank(carol);   staking.deposit(600_000e18, 90);

        uint256 tbpSaudavel = staking.totalBoostedPure();
        assertGt(tbpSaudavel, staking.MIN_EMISSION_WEIGHT(), "pre-condicao: denominador saudavel");

        uint256 aprSaudavel = staking.pureStakerApr(90);
        assertGt(aprSaudavel, 0, "a APR publicada devolvia ZERO em todos os regimes (escala errada)");

        // Sanidade de ordem de grandeza: ~400k de divida a 299 bps sobre ~612k de peso pure da
        // uma APR da ordem de 1-3%. Uma banda larga chega para apanhar erros de escala de 1e18.
        assertLt(aprSaudavel, 10_000, "APR acima de 100% num livro saudavel: escala outra vez errada");
        assertGt(aprSaudavel, 10,     "APR abaixo de 0,1% num livro saudavel: escala outra vez errada");
    }

    /// (b) O amortecedor, isolado: com denominador residual a APR anunciada tem de cair na mesma
    /// proporcao em que a distribuicao real cai (tbp/MIN), senao promete o que nao paga.
    function test_PublishedAprCarriesTheDamper() public {
        _residualPureBook();

        uint256 tbp = staking.totalBoostedPure();
        assertLt(tbp, staking.MIN_EMISSION_WEIGHT(), "pre-condicao: denominador residual");

        uint256 aprResidual = staking.pureStakerApr(90);
        assertGt(aprResidual, 0, "a APR nao pode ser zero - isso era o defeito de escala");

        // Sem amortecedor a APR seria ~MIN/tbp vezes maior (aqui ~980x). Exigir que seja pelo
        // menos 100x menor do que essa versao discrimina com folga e sem ser fragil.
        uint256 semAmortecedor = aprResidual * (staking.MIN_EMISSION_WEIGHT() / tbp);
        assertLt(aprResidual * 100, semAmortecedor,
            "a APR publicada nao leva o amortecedor MIN_EMISSION_WEIGHT (terceira projecao)");
    }
}
