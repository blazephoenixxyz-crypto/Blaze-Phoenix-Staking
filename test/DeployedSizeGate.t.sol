// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  The EIP-170 limit, checked where nothing can stop it running.
//
//  The size gate in .github/workflows/ci.yml parses `forge build --sizes --json`
//  in a separate step. In bp-dex that kind of guard once let a contract over
//  the project gate reach `main`, because every CI job on the commit was
//  skipped before it started: the job list had no steps, and a
//  guard that cannot run is not a guard (bp-dex test/DeployedSizeGate.t.sol).
//
//  So the same property is asserted here, in the suite: deploy the contract and
//  measure `address(...).code.length`. No parsing, no separate job. The number
//  is the shipped size because foundry.toml has ONE code-generating profile
//  (`default`; `ci` changes only fuzz runs), which
//  .github/scripts/profile_parity.py keeps true.
//
//  forge test --match-contract DeployedSizeGate -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

contract DeployedSizeGateTest is Test {
    uint256 constant EIP_170_LIMIT = 24_576;

    function _deploy() internal returns (address) {
        // Any non-zero addresses: the constructor only stores them, and immutables do not
        // change the runtime length.
        return address(new BlazePhoenixStaking(address(0xB2), address(0x713A5)));
    }

    function test_TheStakingContractIsUnderEip170() public {
        uint256 size = _deploy().code.length;
        assertGt(size, 0, "nothing was deployed, so nothing was measured");
        assertLt(size, EIP_170_LIMIT, "BlazePhoenixStaking exceeds EIP-170 and cannot be deployed");
    }

    /// Signed, so a contract over the limit prints its overshoot instead of panicking.
    function test_TheRemainingMarginIsPublished() public {
        uint256 size = _deploy().code.length;
        int256 margin = int256(EIP_170_LIMIT) - int256(size);
        emit log_named_uint("BlazePhoenixStaking runtime bytes", size);
        emit log_named_int("BlazePhoenixStaking margin to EIP-170 (bytes)", margin);
        assertGe(margin, 0, "negative margin: over EIP-170");
    }
}
