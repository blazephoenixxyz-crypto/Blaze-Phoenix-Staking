// SPDX-License-Identifier: BUSL-1.1
// BlazePhoenix Protocol (c) April 2026 - April 2030
//
//  Fingerprint: 0x74d22ada35c060e71f6759654169f11a856ceedf49ad6ef283d4d82f746ccdc6
//
//  Rights. Original work, copyright automatic under the Berne Convention (1886),
//  licensed under the Business Source License 1.1 stated above. Use outside that
//  grant, before the Change Date, is infringement. Authorship is provable from
//  the Fingerprint's keccak256 preimage without disclosing the authors' identity.
pragma solidity 0.8.28;

/// @title  BlazePhoenixMathLib
/// @notice Fixed-point + raw-call helpers. Full 512-bit mulDiv (Remco/Solady form).
/// @dev    v3: unchanged maths from v2 (mulDiv / mulDivSafe / rawTransfer / rawTransferFrom
///         / rawBalanceOf). rawBalanceOf powers the on-chain Master Conservation Identity:
///         the contract reads its OWN physical balance and compares it to what the ledger
///         says it owes, so solvency is provable on-chain by anyone.
library BlazePhoenixMathLib {

    string internal constant VERSION = "3.0.0-staking";

    error MathLib__DivisionByZero();

    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 r) {
        if (d == 0) revert MathLib__DivisionByZero();
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            let lo := mul(a, b)
            let hi := sub(sub(mm, lo), lt(mm, lo))
            switch iszero(hi)
            case 1 { r := div(lo, d) }
            default {
                if iszero(lt(hi, d)) { revert(0,0) }
                let rem := mulmod(a, b, d)
                hi := sub(hi, gt(rem, lo))
                lo := sub(lo, rem)
                let twos := and(sub(0, d), d)
                d := div(d, twos)
                lo := div(lo, twos)
                // Shift the bits that the twos-division moved OUT of the high
                // word back INTO the low one. Dividing `lo` alone drops them:
                // the canonical construction folds them in with 2^256/twos.
                // Without these two lines the high word never reaches the
                // result, and mulDiv silently returns a wrong number whenever
                // the denominator is EVEN and a*b overflows 256 bits — with
                // WAD (1e18, even) as the denominator that is the whole
                // 512-bit regime this branch exists to serve. The Dex Core's
                // mulDiv (BlazePhoenixCore.sol) has always carried them; this
                // library is the sibling copy that did not.
                twos := add(div(sub(0, twos), twos), 1)
                lo := or(lo, mul(hi, twos))
                // Newton-Raphson inverse seed — the xor IS the construction (Remco/Solady),
                // not a typo'd exponentiation. Same triage as the Dex Core's sibling line.
                // slither-disable-next-line incorrect-exp
                let inv := xor(mul(3, d), 2)
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                r := mul(lo, inv)
            }
        }
    }

    function mulDivSafe(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 r) {
        if (d == 0 || a == 0 || b == 0) return 0;
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            let lo := mul(a, b)
            let hi := sub(sub(mm, lo), lt(mm, lo))
            switch iszero(hi)
            case 1 { r := div(lo, d) }
            default {
                if iszero(lt(hi, d)) { r := 0 }
                if lt(hi, d) {
                    let rem := mulmod(a, b, d)
                    hi := sub(hi, gt(rem, lo))
                    lo := sub(lo, rem)
                    let twos := and(sub(0, d), d)
                    d := div(d, twos)
                    lo := div(lo, twos)
                    // Same two lines as mulDiv above, for the same reason.
                    twos := add(div(sub(0, twos), twos), 1)
                    lo := or(lo, mul(hi, twos))
                    // slither-disable-next-line incorrect-exp
                    let inv := xor(mul(3, d), 2)
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    r := mul(lo, inv)
                }
            }
        }
    }

    function rawTransfer(address token, address to, uint256 amount) internal returns (bool ok) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 36), amount)
            let s := call(gas(), token, 0, m, 68, m, 32)
            switch returndatasize()
            case 0  { ok := s }
            case 32 { ok := and(s, mload(m)) }
            default { ok := 0 }
        }
    }

    function rawTransferFrom(address token, address from, address to, uint256 amount) internal returns (bool ok) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4),  and(from, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 36), and(to,   0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 68), amount)
            let s := call(gas(), token, 0, m, 100, m, 32)
            switch returndatasize()
            case 0  { ok := s }
            case 32 { ok := and(s, mload(m)) }
            default { ok := 0 }
        }
    }

    /// @notice balanceOf(who) via staticcall. Returns 0 on a malformed/failed call,
    ///         which the caller's conservation guard treats as a (safe-fail) breach.
    function rawBalanceOf(address token, address who) internal view returns (uint256 bal) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4), and(who, 0xffffffffffffffffffffffffffffffffffffffff))
            let s := staticcall(gas(), token, m, 36, m, 32)
            if and(s, eq(returndatasize(), 32)) { bal := mload(m) }
        }
    }
}
