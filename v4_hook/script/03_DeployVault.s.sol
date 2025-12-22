// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {PegSentinelVault} from "../src/PegSentinelVault.sol";

// 1) set -a; source .env.anvil; set +a
// 2) forge script script/03_DeployVault.s.sol:DeployVault --rpc-url $RPC_URL --broadcast -vv --via-ir
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
        // Initialize regime ranges (tickSpacing=60 assumed)
        // Normal:  [-240, +240]
        // Mild:    [-540, 0]
        // Severe:  [-1620, -300]
        // ------------------------------------------------------------
        vault.setRange(PegSentinelVault.Regime.Normal, int24(-240), int24(240), true);
        vault.setRange(PegSentinelVault.Regime.Mild,   int24(-540), int24(0),   true);
        vault.setRange(PegSentinelVault.Regime.Severe, int24(-1620), int24(-300), true);

        // Optional: set initial regime explicitly
        vault.setActiveRegime(PegSentinelVault.Regime.Normal);

        vm.stopBroadcast();

        console2.log("PegSentinelVault deployed at:", address(vault));
        console2.log("token0:", token0);
        console2.log("token1:", token1);
        console2.log("owner :", owner);

        // Optional logs
        (int24 nLo, int24 nHi, bool nEn) = vault.normalRange();
        (int24 mLo, int24 mHi, bool mEn) = vault.mildRange();
        (int24 sLo, int24 sHi, bool sEn) = vault.severeRange();

        console2.log("Normal range:", nEn);
        console2.log("Normal range lower bound:", int256(nLo));
        console2.log("Normal range upper bound:", int256(nHi));
        console2.log("Mild range:", mEn);
        console2.log("Mild range lower bound:", int256(mLo));
        console2.log("Mild range upper bound:", int256(mHi));
        console2.log("Severe range:", sEn);
        console2.log("Severe range lower bound:", int256(sLo));
        console2.log("Severe range upper bound:", int256(sHi)); 
    }
}
