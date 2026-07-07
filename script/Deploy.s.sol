// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// ─────────────────────────────────────────────────────────────────────────────────────────────
// BlazePhoenix Staking — one-shot deploy + full 180M emission funding.
//
// What it does, atomically, from the deployer account:
//   1. Deploys BlazePhoenixStaking(bzpx, treasury)
//   2. Approves the staking contract to pull exactly TOTAL_REWARDS (180,000,000 BZPX)
//   3. Calls fundEmission(TOTAL_REWARDS) to seed the reward reserve in full
//   4. Verifies the reserve, the funded counter, and solvency post-fund
//
// PRECONDITIONS (the script checks the balance one and reverts early if unmet):
//   • The BZPX token is already deployed at BZPX_ADDRESS.
//   • The deployer (the key behind PRIVATE_KEY) holds >= 180,000,000 BZPX.
//   • BZPX is a standard ERC-20 (no fee-on-transfer / no rebasing / no receiver blacklist) —
//     the protocol's conservation identity assumes amount sent == amount received.
//
// RUN (Termux / any Foundry host):
//   export BZPX_ADDRESS=0x...           # your deployed BZPX token
//   export TREASURY_ADDRESS=0x...       # immutable reserve destination (cannot change later)
//   export PRIVATE_KEY=0x...            # deployer; must hold 180M BZPX and gas
//   export RPC_URL=https://...          # target chain RPC
//   forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast -vvvv
//
//   (add --verify --etherscan-api-key $KEY to verify sources on a supported explorer)
// ─────────────────────────────────────────────────────────────────────────────────────────────

import {Script, console2} from "forge-std/Script.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract Deploy is Script {
    function run() external {
        // ── inputs ────────────────────────────────────────────────────────────────────────────
        address bzpx      = vm.envAddress("BZPX_ADDRESS");
        address treasury  = vm.envAddress("TREASURY_ADDRESS");
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer  = vm.addr(deployerPk);

        require(bzpx     != address(0), "BZPX_ADDRESS is zero");
        require(treasury != address(0), "TREASURY_ADDRESS is zero");

        uint256 total = 180_000_000e18; // == BlazePhoenixStaking.TOTAL_REWARDS

        // ── preflight: deployer must actually hold the full emission ────────────────────────────
        uint256 bal = IERC20Min(bzpx).balanceOf(deployer);
        console2.log("Deployer        :", deployer);
        console2.log("BZPX token      :", bzpx);
        console2.log("Treasury        :", treasury);
        console2.log("Deployer BZPX   :", bal);
        console2.log("Emission to fund:", total);
        require(bal >= total, "deployer holds < 180M BZPX; fund the deployer first");

        // ── broadcast ───────────────────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerPk);

        BlazePhoenixStaking staking = new BlazePhoenixStaking(bzpx, treasury);
        console2.log("Staking deployed:", address(staking));

        // approve exactly the emission, then fund it in one call
        require(IERC20Min(bzpx).approve(address(staking), total), "approve failed");
        staking.fundEmission(total);

        vm.stopBroadcast();

        // ── post-conditions (revert the run if anything is off) ─────────────────────────────────
        require(staking.rewardReserve()       == total, "rewardReserve != 180M after fund");
        require(staking.totalEmissionFunded() == total, "totalEmissionFunded != 180M");
        require(staking.isSolvent(),                     "not solvent after fund");
        require(staking.bzpx()     == bzpx,              "bzpx immutable mismatch");
        require(staking.treasury() == treasury,          "treasury immutable mismatch");

        console2.log("rewardReserve   :", staking.rewardReserve());
        console2.log("isSolvent       :", staking.isSolvent());
        console2.log("VERSION         :", staking.VERSION());
        console2.log("=== DEPLOY + 180M EMISSION FUNDING COMPLETE ===");
        console2.log("Grant GUARDIAN_ROLE before using pause()/declareEmergency():");
        console2.log("  cast send", address(staking));
        console2.log("  \"grantRole(bytes32,address)\" <keccak GUARDIAN_ROLE> <guardian>");
    }
}
