// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// PURE-01 — the anti-dust brake exists on one of the two distribution channels, not on both.
//
// THE ASYMMETRY. The contract distributes value through two twin channels, each dividing by an
// aggregate weight denominator:
//
//   emission (_updateGlobal):        accRewardPerShare    += reward · WAD / totalBoostedEffective
//   interest (_updateInterestIndex): accPureYieldPerShare += toPool · WAD / totalBoostedPure
//
// The emission channel has a damper for when the denominator is residual:
//
//   if (tbe < MIN_EMISSION_WEIGHT) reward = mulDiv(reward, tbe, MIN_EMISSION_WEIGHT);
//
// The contract's own comment explains it: a dust pool earns dust. Without it, a first depositor
// of 1 wei would take the entire emission of every window until someone diluted it.
//
// The interest channel divides by RAW `totalBoostedPure`. The same exposure, the opposite
// decision, silently. It is the house signature — a fix applied to ONE of two symmetric channels —
// the same one that produced the 512-bit mulDiv, the live Algebra fee and the raw-L units.
//
// WHY THIS IS A VALUE TRANSFER, NOT JUST MISALLOCATION. The interest has already been DEBITED from
// the borrowers' collateral (`totalStaked -= slice`). With no pure weight it would go to
// `protocolReserve` (the `else` branch). With a residual pure position, ALL of it goes there.
// This is not yield created out of nothing — it is existing protocol revenue diverted by a
// deposit of negligible cost.
//
// SCENARIO. bob is the borrower: he generates the interest and, holding debt, his pure weight is
// 0 by construction (`_computeBoost`: bp is non-zero only if `u.debt == 0`). mallory deposits 1
// token and is the ONLY pure position in the book, so `totalBoostedPure ≈ 1.02e18` against
// `MIN_EMISSION_WEIGHT = 1000e18` — a residual denominator, exactly the regime the sibling
// channel damps.
//
// Numbers with these parameters: 40% utilisation ⇒ 300 bps rate; one year ⇒ slice ≈ 12,000e18;
// 3% reserveCut ⇒ toPool ≈ 11,640e18. TODAY mallory receives the ~11,640e18 (97% of all protocol
// interest) for 1 token. With the sibling channel's damper she would receive
// toPool·tbp/MIN ≈ 11.9e18 and the rest would stay with the protocol.
//
// A SINGLE WARP, values re-read live afterwards — the call-cache bug in this forge build makes
// warp+view in a loop unreliable.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../../src/BlazePhoenixStaking.sol";

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

    /// The book in which the interest denominator is residual: one borrower (pure weight 0
    /// because it holds debt) and a single pure position of 1 token.
    function _residualPureBook() internal {
        vm.prank(bob); staking.deposit(1_000_000e18, 90);
        vm.prank(bob); staking.borrow(400_000e18);
        vm.prank(mallory); staking.deposit(1e18, 90);
    }

    function test_DustPurePositionCannotCaptureTheProtocolsInterest() public {
        _residualPureBook();

        uint256 tbp = staking.totalBoostedPure();
        assertGt(tbp, 0, "precondition: mallory is a pure position");
        assertLt(tbp, staking.MIN_EMISSION_WEIGHT(), "precondition: residual denominator");

        vm.warp(block.timestamp + 365 days);

        // A poke that does NOT add pure weight: bob holds debt, so his bp stays 0.
        vm.prank(bob); staking.repay(1);

        uint256 accrued = staking.totalInterestAccruedGlobal();
        assertGt(accrued, 0, "interest must have accrued");

        // MEASURE WHAT SHE KEEPS, not what is pending. The `_autoMaintain` in bob's poke runs the
        // rotating engine and may LIQUIDATE mallory midway, zeroing the pending amount while the
        // tokens have already reached her wallet — that is exactly what the first version of this
        // test mismeasured, and it passed green with the bug present.
        uint256 malloryShare = staking.pendingPureYield(mallory)
            + (token.balanceOf(mallory) - (INITIAL_BAL - 1e18));

        // The emission channel scales by tbp/MIN when the denominator is residual. If this channel
        // did the same, mallory's share would be ~0.1% of the interest (tbp/MIN ≈ 1.02/1000).
        // TODAY she takes ~97%: a 1-token position captures the protocol's interest revenue.
        assertLt(
            malloryShare * 100,
            accrued,
            "dust position captured more than 1% of protocol interest (MIN_EMISSION_WEIGHT brake missing)"
        );
    }

    /// The other side of the same coin: what the damper does NOT distribute must stay with the
    /// protocol, not evaporate. Without this the fix would break the conservation identity
    /// (`conserves`), since the slice leaves `totalStaked` and has to land somewhere.
    function test_UndistributedInterestStaysWithTheProtocol() public {
        _residualPureBook();

        uint256 reserveBefore = staking.protocolReserve();

        vm.warp(block.timestamp + 365 days);
        vm.prank(bob); staking.repay(1);

        uint256 accrued     = staking.totalInterestAccruedGlobal();
        uint256 reserveGain = staking.protocolReserve() - reserveBefore;

        // With a residual denominator, the reserve cut (3%) is the FLOOR of what the protocol
        // keeps. With the damper it keeps almost all the rest as well. Today it keeps only the 3%.
        uint256 reserveCutOnly = accrued * staking.RESERVE_FACTOR_BPS() / 10_000;
        assertGt(
            reserveGain,
            reserveCutOnly * 2,
            "undistributed interest evaporated instead of staying with the protocol"
        );
    }

    /// PURE-02 — quoting must equal executing. The NatSpec of `_pendingReward`/`_pendingPure`
    /// states it verbatim: "Both project the un-settled slice, so a quote read in a block equals
    /// what a claim in that same block pays". If the execution channel damps a residual
    /// denominator and the view does not, the guarantee falls — and the PURE-01 fix would itself
    /// be the sibling left uncorrected.
    function test_QuoteEqualsExecutionUnderResidualDenominator() public {
        _residualPureBook();

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 100);                          // anti-flash-loan guard

        uint256 quoted = staking.pendingPureYield(mallory);   // quote BEFORE settling

        uint256 balBefore = token.balanceOf(mallory);
        vm.prank(mallory); staking.claimPureYield();          // execution
        uint256 paid = token.balanceOf(mallory) - balBefore;

        assertApproxEqAbs(quoted, paid, 1e12, "the quote did not match what the execution paid");
    }

    /// PURE-03 — the emergency interest freeze (EMG-01/02) was applied only to the execution
    /// channel. `_updateInterestIndex` returns without charging while `emergencyMode`, but the
    /// view kept projecting the slice. Quoting interest that will never be paid is the same
    /// defect, from the other side.
    function test_QuoteFreezesWithExecutionDuringEmergency() public {
        _residualPureBook();

        vm.warp(block.timestamp + 30 days);
        vm.prank(bob); staking.repay(1);                       // settles the index before the halt

        vm.startPrank(admin);
        staking.grantRole(keccak256("GUARDIAN_ROLE"), admin);
        staking.declareEmergency();
        vm.stopPrank();

        uint256 quotedAtHalt = staking.pendingPureYield(mallory);
        vm.warp(block.timestamp + 365 days);                   // one year INSIDE the emergency
        uint256 quotedLater  = staking.pendingPureYield(mallory);

        assertEq(quotedLater, quotedAtHalt, "the view accrued interest that execution froze");
    }

    /// PURE-04 — the published APR was DEAD, and it was also the third projection without a damper.
    ///
    /// TWO DEFECTS IN ONE PLACE. (a) `share = totalDebt * boost / tbp` has ratio units (~1e4: the
    /// amounts cancel), and the next line divided by WAD — truncation to ZERO in every regime.
    /// Measured before the fix: a book with 400,000e18 of debt, 611,941e18 of pure weight and a
    /// 299 bps rate advertised 0.00%. (b) The interest channel has THREE places that divide by the
    /// same denominator; PURE-01 fixed execution, PURE-02 the pending view, and this one was left.
    ///
    /// A dead view is worse than a wrong view: it raises no alarm at all, and the integrator puts
    /// the zero on screen believing the protocol pays no interest.
    function test_PublishedAprIsAliveAndDamped() public {
        // (a) HEALTHY BOOK: the APR must be a real number, not zero.
        vm.prank(bob);     staking.deposit(1_000_000e18, 90);
        vm.prank(bob);     staking.borrow(400_000e18);
        vm.prank(carol);   staking.deposit(600_000e18, 90);

        uint256 tbpHealthy = staking.totalBoostedPure();
        assertGt(tbpHealthy, staking.MIN_EMISSION_WEIGHT(), "precondition: healthy denominator");

        uint256 aprHealthy = staking.pureStakerApr(90);
        assertGt(aprHealthy, 0, "the published APR returned ZERO in every regime (wrong scale)");

        // Order-of-magnitude sanity: ~400k of debt at 299 bps over ~612k of pure weight gives an
        // APR of the order of 1-3%. A wide band is enough to catch 1e18 scale errors.
        assertLt(aprHealthy, 10_000, "APR above 100% on a healthy book: scale wrong again");
        assertGt(aprHealthy, 10,     "APR below 0.1% on a healthy book: scale wrong again");
    }

    /// (b) The damper, in isolation: with a residual denominator the advertised APR must fall in
    /// the same proportion as the real distribution falls (tbp/MIN), or it promises what it does
    /// not pay.
    function test_PublishedAprCarriesTheDamper() public {
        _residualPureBook();

        uint256 tbp = staking.totalBoostedPure();
        assertLt(tbp, staking.MIN_EMISSION_WEIGHT(), "precondition: residual denominator");

        uint256 aprResidual = staking.pureStakerApr(90);
        assertGt(aprResidual, 0, "the APR must not be zero - that was the scale defect");

        // Undamped value computed independently from the inputs (BOOST_BASE = 10_000):
        //     totalDebt·rate/tbp · boost/10_000 · (1 − reserve)
        // The damper scales it by tbp/MIN (here ~1/980). Deriving `undamped` from the contract's
        // inputs, not from its output, is what lets a missing damper fail this assertion.
        uint256 undamped = staking.totalDebt() * staking.currentInterestRateBps() / tbp
            * staking.boostByDays(90) / 10_000 * (10_000 - staking.RESERVE_FACTOR_BPS()) / 10_000;
        assertGt(undamped, 0, "precondition: a live undamped rate");
        assertLt(aprResidual * 100, undamped,
            "the published APR does not carry the MIN_EMISSION_WEIGHT damper (third projection)");
        // Whole basis points, so the tolerance is one unit of flooring.
        assertApproxEqAbs(aprResidual, undamped * tbp / staking.MIN_EMISSION_WEIGHT(), 1,
            "the published APR is the undamped rate scaled by tbp/MIN");
    }
}
