// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  MATHLIB 512-BIT mulDiv — the sibling copy that lost two lines.
//
//  mulDiv/mulDivSafe implement the canonical 512-bit construction: take the
//  full product [hi lo] = a*b, subtract the remainder so the pair is exactly
//  divisible, factor the powers of two out of the denominator, then multiply by
//  the modular inverse of what remains.
//
//  Factoring the twos out means right-shifting the 512-bit pair. Shifting `lo`
//  alone is not the shift: the bits leaving the BOTTOM of `hi` have to arrive at
//  the TOP of `lo`, which the canonical form does with
//
//      twos := 2^256 / twos          (as add(div(sub(0,twos),twos),1))
//      lo   := or(lo, mul(hi, twos))
//
//  Both lines were absent here, so the high word never reached the result. The
//  defect has an exact signature: the denominator must be EVEN (otherwise
//  twos == 1 and the fold is a no-op, which is why an odd-denominator control
//  passes either way) and a*b must overflow 256 bits (otherwise hi == 0 and the
//  branch is never taken). WAD is 1e18 — even — so every mulDiv(_, _, WAD) sits
//  in exactly the regime this branch exists to serve.
//
//  Measured before the fix: mulDiv(2^128, 2^128, 2) returned 0 instead of 2^255.
//  Not "imprecise" — the answer was zero.
//
//  The Dex Core's mulDiv (BlazePhoenixCore.sol) has always carried both lines.
//  This is the same defect class the codebase keeps producing: one of two
//  symmetric copies gets the fix. Here the two copies live in different repos,
//  which is why no per-repo review had ever put them side by side.
//
//  Reachability, stated honestly: with BZPX's 180M supply at 18 decimals, the
//  largest realistic operand is ~1.8e26, so a*b tops out near 3.2e52 — far below
//  2^256 (~1.16e77). No caller in this contract is believed to reach the broken
//  branch today. This is a latent defect in a primitive, fixed because a math
//  helper that silently returns 0 for a well-formed input is a landmine for
//  every future caller, not because an exploit is known.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixMathLib as ML} from "../src/BlazePhoenixMathLib.sol";

contract MathLibMulDiv512Test is Test {
    uint256 constant WAD = 1e18;

    // ── the exact defect ─────────────────────────────────────────────────────

    /// 2^128 * 2^128 = 2^256 exactly: lo == 0, hi == 1. Divided by 2 the true
    /// answer is 2^255, and it lives ENTIRELY in the high word — so a result
    /// built from `lo` alone is zero.
    function test_mulDiv_EvenDenominator_KeepsHighWord() public pure {
        uint256 r = ML.mulDiv(1 << 128, 1 << 128, 2);
        assertEq(r, uint256(1) << 255, "mulDiv dropped the high word");
    }

    function test_mulDivSafe_EvenDenominator_KeepsHighWord() public pure {
        uint256 r = ML.mulDivSafe(1 << 128, 1 << 128, 2);
        assertEq(r, uint256(1) << 255, "mulDivSafe dropped the high word");
    }

    /// The error is not specific to twos == 2: every power of two in the
    /// denominator shifts a different number of bits across the word boundary.
    function test_EveryPowerOfTwoDenominator() public pure {
        for (uint256 k = 1; k <= 64; k++) {
            uint256 d = uint256(1) << k;
            // 2^256 / 2^k = 2^(256-k)
            uint256 expected = uint256(1) << (256 - k);
            assertEq(ML.mulDiv(1 << 128, 1 << 128, d), expected, "mulDiv power-of-two");
            assertEq(ML.mulDivSafe(1 << 128, 1 << 128, d), expected, "mulDivSafe power-of-two");
        }
    }

    /// WAD is even (1e18 = 2^18 * 5^18), so the real denominator of this
    /// codebase carries eighteen factors of two through the same path.
    function test_WadDenominator_OverflowingProduct() public pure {
        uint256 a = uint256(1) << 200;
        uint256 b = uint256(1) << 100; // a*b = 2^300, overflows 256 bits
        uint256 r = ML.mulDiv(a, b, WAD);
        // floor(2^300 / 1e18), computed in arbitrary precision outside the EVM.
        // The intermediate 2^282 cannot be written as a uint256 literal shift
        // (it exceeds the word), which is precisely why the value is pinned as
        // a constant rather than recomputed in-test.
        uint256 expected =
            2037035976334486086268445688409378161051468393665936250636140449354381299;
        assertEq(r, expected, "WAD-denominator 512-bit path");
        assertGt(r, 0, "must not be zero");
    }

    // ── properties that must hold in the ordinary (non-overflowing) regime ───

    /// Where a*b fits in a word the answer is plain integer division, and the
    /// 512-bit path must agree with it.
    function testFuzz_AgreesWithPlainDivisionWhenNoOverflow(uint128 a, uint128 b, uint128 d)
        public pure
    {
        vm.assume(d != 0);
        // uint128 * uint128 always fits in uint256.
        uint256 expected = (uint256(a) * uint256(b)) / uint256(d);
        assertEq(ML.mulDiv(a, b, d), expected, "mulDiv vs plain division");
        assertEq(ML.mulDivSafe(a, b, d), expected, "mulDivSafe vs plain division");
    }

    /// mulDiv(a, b, b) == a whenever b != 0 — an identity that must survive the
    /// 512-bit branch, including for even b with a large enough to overflow.
    function testFuzz_DivideByOwnFactorIsIdentity(uint256 a, uint256 b) public pure {
        vm.assume(b != 0);
        // Keep a below the revert bound: the branch requires d > hi.
        vm.assume(a < type(uint128).max);
        assertEq(ML.mulDiv(a, b, b), a, "mulDiv(a,b,b) != a");
    }

    /// An odd denominator is the case that passed even while broken: twos == 1
    /// makes the fold a no-op. Kept as a regression control so a future edit
    /// cannot "fix" the even case by breaking the odd one.
    function test_OddDenominator_Control() public pure {
        // 2^256 / 3 floor
        uint256 r = ML.mulDiv(1 << 128, 1 << 128, 3);
        // 2^256 = 3q + 1, so floor(2^256/3) == (2^256 - 1)/3 exactly.
        uint256 expected = type(uint256).max / 3;
        assertEq(r, expected, "odd-denominator path regressed");
    }

    /// mulDivSafe's contract differs from mulDiv's only at the edges: it returns
    /// 0 instead of reverting. The 512-bit arithmetic must be identical.
    function test_SafeMatchesUnsafeInsideTheDomain() public pure {
        assertEq(ML.mulDiv(1 << 128, 1 << 128, 8), ML.mulDivSafe(1 << 128, 1 << 128, 8));
        assertEq(ML.mulDiv(7, 11, 3), ML.mulDivSafe(7, 11, 3));
    }

    function test_SafeReturnsZeroOnZeroInputs() public pure {
        assertEq(ML.mulDivSafe(0, 5, 3), 0);
        assertEq(ML.mulDivSafe(5, 0, 3), 0);
        assertEq(ML.mulDivSafe(5, 3, 0), 0);
    }
}
