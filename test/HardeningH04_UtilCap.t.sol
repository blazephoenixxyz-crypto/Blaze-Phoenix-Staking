// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// H-04 regression suite — aggregate protocol utilisation cap on `borrow`.
//
// THE HOLE. Pre-fix, `borrow` checked only the caller's own LTV. The aggregate book has a
// second failure mode the per-user check cannot see: interest is charged against collateral
// (`_updateInterestIndex` moves the slice OUT of totalStaked while totalDebt stays put), so
// utilisation climbs on its own. Once the book had eroded near the 80% kink, one borrower
// with private LTV headroom could push the WHOLE book across it and put every outstanding
// position on the steep RATE_S2 = 72_500 bps/WAD branch — a rate everyone else pays for.
//
// THE FIX. `borrow` now also enforces MAX_PROTOCOL_UTIL_WAD = 0.75e18 (strictly below the
// 0.80e18 kink): any borrow for which (totalDebt + amount) / totalStaked > 0.75 reverts
// Staking__UtilTooHigh. The boundary is inclusive — landing exactly on 0.75 succeeds.
//
// REACHING THE INTERESTING STATE, deterministically. A pristine book can never exceed 50%
// utilisation: `_ltvCap = (staked - debt) / 2` caps every borrower's debt at half their own
// stake, borrowers cannot withdraw (Staking__HasDebt), and a fresh depositor adds twice as
// much stake as they may borrow. Interest erosion is the one lever left — and it needs ~20
// years at the sub-kink rate, far past the 7-year emission close. `deposit()` reverts
// Staking__EmissionEnded there, so the borrower who will probe the cap CANNOT enter after
// the erosion; `borrow()` carries no emission gate, so she pre-positions collateral at
// genesis instead and sizes it so her private LTV headroom still crosses the aggregate
// ceiling once the book has decayed. The erosion is exact because the index applies the
// rate FROZEN at the last poke: with bob's 500_000e18 debt against 1_040_000e18 staked
// (util 48.08% → 340 bps), a single 21-year warp erodes 500_000e18 * 3.40% * 21 =
// 357_000e18 → totalStaked 683_000e18, util 73.21% — decayed far past the 50% pristine
// ceiling, with the 0.75 cap now inside alice's own LTV reach, and bob still clear of the
// 95% liquidation line (643_000 * 95 > 500_000 * 100). No loops of warp+view calls (this
// forge build's stale-call-cache bug), one warp, values re-read live afterwards.
//
// Same harness as BlazePhoenixStaking.t.sol; mock renamed to avoid artifact-name ambiguity.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract MockERC20H04 {
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

contract HardeningH04UtilCapTest is Test {
    BlazePhoenixStaking staking;
    MockERC20H04 token;
    address admin = address(0xA11CE);
    address treasury = address(0x713A5);
    address alice = address(0x1);
    address bob = address(0x2);
    address carol = address(0x3);
    address keeper = address(0x4);

    uint256 constant WAD = 1e18;
    /// Mirror of the contract's private MAX_PROTOCOL_UTIL_WAD — the value under test.
    uint256 constant UTIL_CAP_WAD = 0.75e18;

    function _fund(address u) internal {
        token.mint(u, 500_000_000e18);
        vm.prank(u);
        token.approve(address(staking), type(uint256).max);
    }

    function setUp() public {
        vm.warp(1_900_000_000);
        token = new MockERC20H04();
        vm.prank(admin);
        staking = new BlazePhoenixStaking(address(token), treasury);
        _fund(admin); _fund(alice); _fund(bob); _fund(carol); _fund(keeper);
    }

    function _util() internal view returns (uint256) {
        return staking.totalDebt() * WAD / staking.totalStaked();
    }

    /// Alice's genesis collateral — sized so that after the erosion her private LTV headroom
    /// (a/2 = 20_000e18) still reaches past the aggregate 0.75 ceiling (xExact ≈ 12_250e18).
    uint256 constant ALICE_STAKE = 40_000e18;

    /// Decay the aggregate book to within alice's reach of the 0.75 cap through interest
    /// erosion (see file header): bob at max LTV plus alice's pre-positioned 40k (util
    /// 48.08%, frozen 340 bps sub-kink rate), then ONE 21-year warp, then one poke so the
    /// global index settles. Ends at util ≈ 0.7321e18 — beyond anything a pristine book can
    /// reach — with bob healthy and alice debt-free (a debt-free position is never charged
    /// interest, so her 40k collateral survives the decay untouched).
    function _erodeBookNearCap() internal {
        vm.prank(bob);   staking.deposit(1_000_000e18, 90);
        vm.prank(alice); staking.deposit(ALICE_STAKE, 90);     // pre-positioned: deposits close at emissionEnd
        vm.roll(block.number + 2);
        vm.prank(bob); staking.borrow(500_000e18);            // single-shot max LTV
        vm.warp(block.timestamp + 21 * 365 days); vm.roll(block.number + 11);
        vm.prank(carol); staking.claimRewards();               // unrelated tx settles the index

        // Preconditions the whole regression rests on — assert them, don't assume them.
        assertGt(_util(), WAD / 2, "erosion must carry the book past the 50% pristine ceiling");
        assertLe(_util(), UTIL_CAP_WAD, "but not past the cap: the boundary must be probed by a borrow");
        // All erosion lands on bob (the only borrower), so his post-attribution stake is
        // exactly totalStaked - ALICE_STAKE.
        assertGt((staking.totalStaked() - ALICE_STAKE) * 95, staking.totalDebt() * 100,
            "bob must stay clear of the 95% liquidation line or maintenance rewrites the book");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // (a) Borrows that keep aggregate utilisation at or under 0.75 succeed. A pristine book
    // at max per-user LTV tops out at exactly 50% — comfortably inside the cap — so every
    // legitimate borrow the old code allowed is still allowed.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_H04_FreshBook_MaxLtvBorrowsSucceedUnderCap() public {
        vm.prank(alice); staking.deposit(1_000_000e18, 90);
        vm.prank(bob);   staking.deposit(1_000_000e18, 90);
        vm.prank(carol); staking.deposit(1_000_000e18, 90);
        vm.roll(block.number + 2);
        vm.prank(alice); staking.borrow(500_000e18);
        vm.prank(bob);   staking.borrow(500_000e18);
        vm.prank(carol); staking.borrow(500_000e18);

        assertEq(staking.totalDebt(),   1_500_000e18, "all three max-LTV borrows succeeded");
        assertEq(staking.totalStaked(), 3_000_000e18);
        assertLe(_util(), UTIL_CAP_WAD, "the deepest a pristine book can go is 50% -- inside the cap");
        assertTrue(staking.isSolvent());
        assertEq(staking.auditInvariants() & 1, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // (a)+(b) The boundary itself, one token to each side. With the book decayed to 73.21%
    // (`_erodeBookNearCap`), alice's genesis 40k gives her an LTV headroom of a/2 = 20_000e18
    // while the ceiling sits only xExact = 0.75·S − D = 12_250e18 of debt away — so her OWN
    // check passes on both probes and only the aggregate cap can answer. Borrowing past the
    // ceiling reverts Staking__UtilTooHigh; landing exactly on it succeeds (inclusive
    // boundary); every further borrow is refused until someone ELSE repays — proving the cap
    // is aggregate, not per-user.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_H04_BorrowAtExactCapSucceeds_PastCapRevertsUtilTooHigh() public {
        _erodeBookNearCap();

        uint256 s1 = staking.totalStaked();                    // 683_000e18 (settled, no clamp)
        uint256 d1 = staking.totalDebt();                      // 500_000e18
        uint256 maxDebt = (s1 * 75) / 100;                     // the ceiling in absolute debt
        uint256 xExact  = maxDebt - d1;                        // 12_250e18
        assertLe(xExact + 1e18, ALICE_STAKE / 2, "both attempts sit inside alice's own LTV headroom");

        // Ordering: a caller with no LTV headroom is refused on LTV, never reaching the cap.
        vm.prank(bob);
        vm.expectRevert(BlazePhoenixStaking.Staking__LTVExceeded.selector);
        staking.borrow(1e18);

        // (b) One token past the ceiling: LTV passes, the aggregate cap must catch it.
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__UtilTooHigh.selector);
        staking.borrow(xExact + 1e18);

        // (a) Exactly on the ceiling: the boundary is inclusive and must succeed.
        vm.prank(alice); staking.borrow(xExact);
        assertEq(staking.totalDebt(), maxDebt, "landed exactly on the 0.75 ceiling");
        assertLe(_util(), UTIL_CAP_WAD, "at the cap, not beyond it");
        assertTrue(staking.isTrackedBorrower(alice));

        // From here even one more token is refused, whoever asks with LTV headroom.
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__UtilTooHigh.selector);
        staking.borrow(1e18);

        // AGGREGATE, not per-user: bob's repay reopens headroom and the same borrow passes.
        vm.prank(bob);  staking.repay(50_000e18);
        vm.prank(alice); staking.borrow(1e18);
        assertLe(_util(), UTIL_CAP_WAD);
        assertTrue(staking.isSolvent());
        assertEq(staking.auditInvariants() & 1, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────
    // (c) The per-user MAX_LTV check survives the fix, and still binds FIRST where it
    // applies: at 50.1% utilisation the aggregate cap is silent, so both refusals below can
    // only come from Staking__LTVExceeded.
    // ─────────────────────────────────────────────────────────────────────────────────────
    function test_H04_PerUserLtvStillBinds() public {
        vm.prank(alice); staking.deposit(1000e18, 365);
        vm.roll(block.number + 2);

        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__LTVExceeded.selector);
        staking.borrow(501e18);

        vm.prank(alice); staking.borrow(500e18);               // single-shot max LTV still fine
        assertEq(staking.totalDebt(), 500e18);
        assertTrue(staking.isTrackedBorrower(alice));

        // Second bite: effective stake is now 500, cap 250, debt already 500 — LTV refuses.
        // Util would be 50.1%, far under 0.75, so this cannot be the aggregate cap talking.
        vm.prank(alice);
        vm.expectRevert(BlazePhoenixStaking.Staking__LTVExceeded.selector);
        staking.borrow(1e18);
    }
}
