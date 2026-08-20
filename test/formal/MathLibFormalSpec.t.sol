// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  SYMBOLIC SPEC — BlazePhoenixMathLib
//
//  What Halmos can and cannot decide here is not a matter of effort, and the Dex
//  repo already measured it: properties that route through the 512-bit assembly
//  mulDiv reach `mulmod`, which the solver over-approximates, so they TIMEOUT
//  rather than discharge. A timeout is "could not determine", not a
//  counterexample, and a check with no expectation but real variance only adds
//  noise to a gate.
//
//  So this file states the properties that live OUTSIDE the 512-bit path — the
//  domain edges and the single-word regime, where the arithmetic is plain
//  division and the solver has everything it needs:
//
//    * mulDivSafe's total-function contract: zero in, zero out, never a revert.
//    * mulDiv's one revert condition: a zero denominator, and only that.
//    * In the single-word regime (operands that cannot overflow a word), the
//      512-bit construction must agree with plain integer division — which is
//      the property that would have caught the missing high-word fold if the
//      operands had been allowed to reach it.
//
//  This file is REPORT-ONLY on arrival. The repo's promotion rule, inherited
//  from the Dex: a check enters a hard gate only after a report-only run has
//  MEASURED it discharging cleanly. If these discharge, promote them and delete
//  the report-only job; if they time out, they stay where a timeout costs
//  nothing.
//
//  Run: halmos --contract MathLibFormalSpec -v
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixMathLib as ML} from "../../src/BlazePhoenixMathLib.sol";

contract MathLibFormalSpec is Test {
    // ── mulDivSafe is total: it answers for every input, including the ones
    //    that make mulDiv revert. Pure comparison logic, no mulmod reached.
    function check_SafeIsZeroWhenAnyOperandIsZero(uint256 a, uint256 b, uint256 d) public pure {
        if (a == 0 || b == 0 || d == 0) {
            assert(ML.mulDivSafe(a, b, d) == 0);
        }
    }

    // ── mulDiv's only revert condition is a zero denominator. Stated as: for a
    //    non-zero denominator in the single-word regime, the call returns.
    function check_MulDivReturnsForNonZeroDenominatorInWordRegime(uint128 a, uint128 b, uint128 d)
        public pure
    {
        if (d == 0) return;
        uint256 r = ML.mulDiv(a, b, d);
        assert(r <= (uint256(a) * uint256(b)) / uint256(d));
    }

    // ── THE property the missing high-word fold violated, stated where the
    //    solver can decide it: inside a single word, the 512-bit construction
    //    must equal plain integer division. uint128 operands cannot overflow a
    //    256-bit product, so `hi` is zero and the fast path answers — which is
    //    exactly why this discharges while the overflowing regime does not.
    function check_AgreesWithPlainDivisionInWordRegime(uint128 a, uint128 b, uint128 d)
        public pure
    {
        if (d == 0) return;
        uint256 expected = (uint256(a) * uint256(b)) / uint256(d);
        assert(ML.mulDiv(a, b, d) == expected);
        assert(ML.mulDivSafe(a, b, d) == expected);
    }

    // ── Safe and unsafe must not disagree anywhere both are defined.
    function check_SafeAgreesWithUnsafeInWordRegime(uint128 a, uint128 b, uint128 d) public pure {
        if (d == 0 || a == 0 || b == 0) return;
        assert(ML.mulDiv(a, b, d) == ML.mulDivSafe(a, b, d));
    }

    // ── Dividing by one of the factors returns the other, exactly. An identity
    //    that must survive whichever path the implementation takes.
    function check_DivideByOwnFactorIsIdentity(uint128 a, uint128 b) public pure {
        if (b == 0) return;
        assert(ML.mulDiv(a, b, b) == a);
    }
}
