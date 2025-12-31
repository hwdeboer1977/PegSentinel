// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {PegSentinelVault} from "../src/PegSentinelVault.sol";


// Run on Sepolia Arbitrum:
// 1. set -a; source .env; set +a
// 2. forge script script/03_DeployVault.s.sol:DeployVault --rpc-url $ARB_RPC --broadcast -vv --via-ir

// Run on Anvil
// 1. set -a; source .env.anvil; set +a
// 2. forge script script/03_DeployVault.s.sol:DeployVault --rpc-url $RPC_URL --broadcast -vv --via-ir
//
// Env vars:
// - PRIVATE_KEY
// - TOKEN0_ADDRESS
// - TOKEN1_ADDRESS
// - OWNER

contract DeployVault is Script {
    function run() external returns (PegSentinelVault vault) {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));

        address token0 = vm.envAddress("TOKEN0_ADDRESS");
        address token1 = vm.envAddress("TOKEN1_ADDRESS");
        address owner  = vm.envAddress("OWNER");

        vm.startBroadcast(pk);

        vault = new PegSentinelVault(token0, token1, owner);

        // ------------------------------------------------------------
        // Initialize regime RANGES (where liquidity goes)
        // Normal:  [-240, +240]
        // Mild:    [-540, 0]
        // Severe:  [-1620, -300]
        // ------------------------------------------------------------
        vault.setRange(PegSentinelVault.Regime.Normal, int24(-240), int24(240), true);
        vault.setRange(PegSentinelVault.Regime.Mild,   int24(-540), int24(0),   true);
        vault.setRange(PegSentinelVault.Regime.Severe, int24(-1620), int24(-300), true);

        // ------------------------------------------------------------
        // Initialize regime THRESHOLDS (when to switch regimes)
        // tick > -240       → Normal
        // tick <= -240      → Mild
        // tick <= -540      → Severe
        // ------------------------------------------------------------
        vault.setThresholds(int24(-240), int24(-540));

        // Set initial regime explicitly
        vault.setActiveRegime(PegSentinelVault.Regime.Normal);

        vm.stopBroadcast();

        console2.log("=== PegSentinelVault Deployed ===");
        console2.log("Address:", address(vault));
        console2.log("token0:", token0);
        console2.log("token1:", token1);
        console2.log("owner:", owner);
        console2.log("");

        // Log ranges
        (int24 nLo, int24 nHi, bool nEn) = vault.normalRange();
        (int24 mLo, int24 mHi, bool mEn) = vault.mildRange();
        (int24 sLo, int24 sHi, bool sEn) = vault.severeRange();

        console2.log("=== Ranges ===");
        console2.log("Normal: [", int256(nLo), ",", int256(nHi), "] enabled:", nEn);
        console2.log("Mild:   [", int256(mLo), ",", int256(mHi), "] enabled:", mEn);
        console2.log("Severe: [", int256(sLo), ",", int256(sHi), "] enabled:", sEn);
        console2.log("");

        // Log thresholds
        console2.log("=== Thresholds ===");
        console2.log("Mild threshold:", int256(vault.mildThreshold()));
        console2.log("Severe threshold:", int256(vault.severeThreshold()));
        console2.log("");
        console2.log("Regime logic:");
        console2.log("  tick > -240  -> Normal");
        console2.log("  tick <= -240 -> Mild");
        console2.log("  tick <= -540 -> Severe");
    }
}
