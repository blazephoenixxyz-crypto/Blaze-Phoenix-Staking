// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  atq-1111 (staking front) — BlazePhoenixMathLib, every line watched
//
//  The catalogue had no mutant on the library. Each test below is paired with one
//  [ATQ-staking-n] entry of .github/scripts/mutants.py.
//
//  ORACLES (none of them is the code under test):
//    * mulDiv / mulDivSafe: the exact 512-bit product is built here by schoolbook
//      multiplication on 128-bit limbs, and the quotient is checked by multiplying
//      BACK (q*d <= a*b < (q+1)*d). No division algorithm is repeated.
//    * raw token calls: a token whose reply shape is chosen by the test (no data,
//      one word, short, long, revert with and without data).
//
//  Run: forge test --match-path test/atq/AtqMathLibEveryLine.t.sol
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixMathLib as ML} from "../../src/BlazePhoenixMathLib.sol";

contract AtqMathHarness {
    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) { return ML.mulDiv(a, b, d); }
    function mulDivSafe(uint256 a, uint256 b, uint256 d) external pure returns (uint256) { return ML.mulDivSafe(a, b, d); }
    function rawTransfer(address t, address to, uint256 a) external returns (bool) { return ML.rawTransfer(t, to, a); }
    function rawTransferFrom(address t, address f, address to, uint256 a) external returns (bool) {
        return ML.rawTransferFrom(t, f, to, a);
    }
    function rawBalanceOf(address t, address who) external view returns (uint256) { return ML.rawBalanceOf(t, who); }
}

/// Answers every call with the reply shape the test selected.
contract AtqShapeToken {
    uint256 public immutable len;      // bytes of reply
    uint256 public immutable word;     // value of each reply word
    bool    public immutable reverts;  // reply through REVERT instead of RETURN
    constructor(uint256 len_, uint256 word_, bool reverts_) { len = len_; word = word_; reverts = reverts_; }
    fallback() external {
        uint256 l = len; uint256 w = word; bool r = reverts;
        assembly {
            mstore(0, w) mstore(32, w)
            if r { revert(0, l) }
            return(0, l)
        }
    }
}

contract AtqMathLibEveryLineTest is Test {
    AtqMathHarness h;
    uint256 constant MAX = type(uint256).max;

    function setUp() public { h = new AtqMathHarness(); }

    // ── independent 512-bit arithmetic (schoolbook, 128-bit limbs) ───────────────────────────
    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        unchecked {
            uint256 a0 = uint128(a); uint256 a1 = a >> 128;
            uint256 b0 = uint128(b); uint256 b1 = b >> 128;
            uint256 p00 = a0 * b0; uint256 p01 = a0 * b1; uint256 p10 = a1 * b0; uint256 p11 = a1 * b1;
            uint256 mid = p01 + p10;
            uint256 c1 = mid < p01 ? 1 : 0;
            lo = p00 + (mid << 128);
            uint256 c2 = lo < p00 ? 1 : 0;
            hi = p11 + (mid >> 128) + (c1 << 128) + c2;
        }
    }

    /// q is floor(a*b/d)  <=>  q*d <= a*b  and  a*b - q*d < d   (all in 512 bits).
    function _assertIsFloor(uint256 a, uint256 b, uint256 d, uint256 q, string memory tag) internal pure {
        (uint256 hi, uint256 lo) = _mul512(a, b);
        (uint256 qh, uint256 ql) = _mul512(q, d);
        assertTrue(qh < hi || (qh == hi && ql <= lo), string.concat(tag, ": q*d exceeds a*b (rounded up)"));
        unchecked {
            uint256 rl = lo - ql;
            uint256 rh = hi - qh - (lo < ql ? 1 : 0);
            assertEq(rh, 0, string.concat(tag, ": remainder does not fit one word"));
            assertLt(rl, d, string.concat(tag, ": remainder >= d (rounded down twice)"));
        }
    }

    // ── mulDiv ───────────────────────────────────────────────────────────────────────────────
    /// Range: the whole 512-bit domain where the quotient fits (d drawn above the high word).
    function testFuzz_AtqMulDivFloorsTheExactQuotient_FullWidth(uint256 a, uint256 b, uint256 dSeed) public view {
        (uint256 hi,) = _mul512(a, b);
        vm.assume(hi != MAX);
        uint256 d = bound(dSeed, hi + 1, MAX);
        _assertIsFloor(a, b, d, h.mulDiv(a, b, d), "mulDiv");
    }

    /// The borrow of the 512-bit subtraction: remainder above the low word (lo = 0, rem = 1).
    function test_AtqMulDivBorrowsFromTheHighWordWhenTheRemainderExceedsTheLowWord() public view {
        uint256 a = 1 << 128;
        assertEq(h.mulDiv(a, a, 3), MAX / 3, "2^256 / 3");
        assertEq(h.mulDiv(a, a, 7), MAX / 7, "2^256 / 7 (2^256 mod 7 = 2)");
        // The borrowed high word only reaches the result through an EVEN denominator (for an odd one
        // the fold multiplies it by zero): 2^256 mod 6 = 4 > lo = 0.
        assertEq(h.mulDiv(a, a, 6), MAX / 6, "2^256 / 6");
        assertEq(h.mulDiv(a, a, 12), MAX / 12, "2^256 / 12");
        _assertIsFloor(a, a, 3, h.mulDiv(a, a, 3), "borrow");
    }

    /// A denominator with a large power of two keeps the high word (the `twos` fold).
    function test_AtqMulDivFoldsTheHighWordBackForEvenDenominators() public view {
        uint256 a = 1 << 255;
        assertEq(h.mulDiv(a, a, a), a, "2^510 / 2^255");
        assertEq(h.mulDiv(MAX, MAX, MAX), MAX, "max*max/max");
        assertEq(h.mulDiv(MAX, 1 << 200, 1 << 201), MAX >> 1, "even denominator, 512-bit product");
        _assertIsFloor(MAX, 6, 12, h.mulDiv(MAX, 6, 12), "small even denominator");
    }

    /// An inverse correct to only 128 bits is not enough: quotients that use the whole word.
    function test_AtqMulDivInverseIsExactToTheFullWord() public view {
        uint256 d = (1 << 255) + 12345;                     // odd, close to the top
        _assertIsFloor(MAX, MAX - 1, MAX, h.mulDiv(MAX, MAX - 1, MAX), "max*(max-1)/max");
        assertEq(h.mulDiv(MAX, MAX - 1, MAX), MAX - 1);
        _assertIsFloor(MAX - 2, d, d + 2, h.mulDiv(MAX - 2, d, d + 2), "odd top denominator");
        _assertIsFloor(MAX, 3, 5, h.mulDiv(MAX, 3, 5), "small odd denominator, wide quotient");
        assertEq(h.mulDiv(MAX, 3, 5), (MAX / 5) * 3, "max is a multiple of 5");
    }

    /// Word regime: the result is the floor, never the ceiling (rounding against the receiver).
    function testFuzz_AtqMulDivWordRegimeFloorsNeverCeils(uint128 a, uint128 b, uint256 d) public view {
        d = bound(d, 1, MAX);
        uint256 q = h.mulDiv(a, b, d);
        assertEq(q, (uint256(a) * b) / d, "word regime: plain floor");
        assertEq(h.mulDiv(7, 3, 2), 10, "21/2 floors to 10");
        assertEq(h.mulDiv(1, 1, 2), 0, "1/2 floors to 0");
    }

    function test_AtqMulDivRefusesAZeroDenominatorBySelector() public {
        vm.expectRevert(ML.MathLib__DivisionByZero.selector);
        h.mulDiv(5, 7, 0);
        vm.expectRevert(ML.MathLib__DivisionByZero.selector);
        h.mulDiv(MAX, MAX, 0);
        vm.expectRevert(ML.MathLib__DivisionByZero.selector);
        h.mulDiv(0, 0, 0);
    }

    /// The quotient 2^256 does not fit: refused AT the boundary high word == d, served one above.
    function test_AtqMulDivRefusesAQuotientThatDoesNotFit_AtTheExactBoundary() public {
        uint256 a = (1 << 128) + 1; uint256 b = 1 << 128;   // a*b = 2^256 + 2^128: hi = 1
        vm.expectRevert(bytes(""));
        h.mulDiv(a, b, 1);                                  // hi == d
        assertEq(h.mulDiv(a, b, 2), (1 << 255) + (1 << 127), "hi == d - 1 is served");
        // (max, max): hi = 2^256 - 2, lo = 1
        vm.expectRevert(bytes(""));
        h.mulDiv(MAX, MAX, MAX - 1);                        // hi == d
        assertEq(h.mulDiv(MAX, MAX, MAX), MAX, "hi == d - 1 is served");
    }

    // ── mulDivSafe ───────────────────────────────────────────────────────────────────────────
    function testFuzz_AtqMulDivSafeIsTheSameFloorInsideTheDomain_FullWidth(uint256 a, uint256 b, uint256 dSeed) public view {
        (uint256 hi,) = _mul512(a, b);
        vm.assume(hi != MAX);
        uint256 d = bound(dSeed, hi + 1, MAX);
        _assertIsFloor(a, b, d, h.mulDivSafe(a, b, d), "mulDivSafe");
    }

    function test_AtqMulDivSafeBorrowsAndFoldsLikeMulDiv() public view {
        uint256 a = 1 << 128;
        assertEq(h.mulDivSafe(a, a, 3), MAX / 3, "borrow");
        assertEq(h.mulDivSafe(a, a, 6), MAX / 6, "borrow, even denominator");
        assertEq(h.mulDivSafe(a, a, 12), MAX / 12, "borrow, even denominator");
        assertEq(h.mulDivSafe(MAX, 1 << 200, 1 << 201), MAX >> 1, "fold");
        assertEq(h.mulDivSafe(MAX, MAX - 1, MAX), MAX - 1, "full-word inverse");
        assertEq(h.mulDivSafe(7, 3, 2), 10, "word regime floors");
    }

    /// Where mulDiv refuses, mulDivSafe answers 0: at the boundary high word == d and above it.
    function testFuzz_AtqMulDivSafeReturnsZeroWhereTheQuotientDoesNotFit(uint256 a, uint256 b, uint256 dSeed) public view {
        assertEq(h.mulDivSafe((1 << 128) + 1, 1 << 128, 1), 0, "hi == d, low word above d");
        assertEq(h.mulDivSafe(MAX, MAX, MAX - 1), 0, "hi == d");
        assertEq(h.mulDivSafe(MAX, MAX, 1), 0, "hi far above d");
        (uint256 hi,) = _mul512(a, b);
        vm.assume(hi != 0);
        uint256 d = bound(dSeed, 1, hi);
        assertEq(h.mulDivSafe(a, b, d), 0, "overflow answers zero");
    }

    // ── rawTransfer / rawTransferFrom / rawBalanceOf: reply shapes ───────────────────────────
    function _tok(uint256 len, uint256 word, bool reverts) internal returns (address) {
        return address(new AtqShapeToken(len, word, reverts));
    }

    function test_AtqRawTransferReadsAFalseReturnAsFailure() public {
        assertFalse(h.rawTransfer(_tok(32, 0, false), address(1), 1), "returned false");
        assertTrue(h.rawTransfer(_tok(32, 1, false), address(1), 1), "control: returned true");
    }
    function test_AtqRawTransferRefusesAReplyThatIsNotOneWord() public {
        assertFalse(h.rawTransfer(_tok(31, MAX, false), address(1), 1), "31 bytes");
        assertFalse(h.rawTransfer(_tok(64, 1, false), address(1), 1), "64 bytes");
        assertFalse(h.rawTransfer(_tok(1, MAX, false), address(1), 1), "1 byte");
    }
    function test_AtqRawTransferAcceptsATokenThatReturnsNothing() public {
        assertTrue(h.rawTransfer(_tok(0, 0, false), address(1), 1), "no return data, call succeeded");
    }
    function test_AtqRawTransferReadsARevertWithNoDataAsFailure() public {
        assertFalse(h.rawTransfer(_tok(0, 0, true), address(1), 1), "reverted, no data");
    }
    function test_AtqRawTransferReadsARevertCarryingATrueWordAsFailure() public {
        assertFalse(h.rawTransfer(_tok(32, 1, true), address(1), 1), "reverted with the word 1");
    }

    function test_AtqRawTransferFromReadsAFalseReturnAsFailure() public {
        assertFalse(h.rawTransferFrom(_tok(32, 0, false), address(2), address(1), 1), "returned false");
        assertTrue(h.rawTransferFrom(_tok(32, 1, false), address(2), address(1), 1), "control: returned true");
    }
    function test_AtqRawTransferFromRefusesAReplyThatIsNotOneWord() public {
        assertFalse(h.rawTransferFrom(_tok(31, MAX, false), address(2), address(1), 1), "31 bytes");
        assertFalse(h.rawTransferFrom(_tok(64, 1, false), address(2), address(1), 1), "64 bytes");
    }
    function test_AtqRawTransferFromAcceptsATokenThatReturnsNothing() public {
        assertTrue(h.rawTransferFrom(_tok(0, 0, false), address(2), address(1), 1), "no return data");
    }
    function test_AtqRawTransferFromReadsARevertWithNoDataAsFailure() public {
        assertFalse(h.rawTransferFrom(_tok(0, 0, true), address(2), address(1), 1), "reverted, no data");
    }
    function test_AtqRawTransferFromReadsARevertCarryingATrueWordAsFailure() public {
        assertFalse(h.rawTransferFrom(_tok(32, 1, true), address(2), address(1), 1), "reverted with the word 1");
    }

    function test_AtqRawBalanceOfReadsZeroWhenTheReplyIsNotOneWord() public {
        assertEq(h.rawBalanceOf(_tok(0, 0, false), address(1)), 0, "empty reply");
        assertEq(h.rawBalanceOf(_tok(31, MAX, false), address(1)), 0, "31 bytes");
        assertEq(h.rawBalanceOf(_tok(64, 9, false), address(1)), 0, "64 bytes");
        assertEq(h.rawBalanceOf(_tok(32, 9, false), address(1)), 9, "control: one word");
    }
    function test_AtqRawBalanceOfReadsZeroWhenTheCallReverts() public {
        assertEq(h.rawBalanceOf(_tok(32, 7, true), address(1)), 0, "reverted with the word 7");
    }

    /// PIN (measured, not judged): the one-word reply is read by its LOW BIT (`and(s, word)`),
    /// so 2 reads as failure and 3 as success. Fail-closed for even words.
    function test_AtqPinAOneWordReplyIsReadByItsLowBit() public {
        assertFalse(h.rawTransfer(_tok(32, 2, false), address(1), 1), "the word 2 reads as failure");
        assertTrue(h.rawTransfer(_tok(32, 3, false), address(1), 1), "the word 3 reads as success");
        assertTrue(h.rawTransfer(address(0xC0DE1E55), address(1), 1), "an account without code reads as success");
    }
}
