// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {PegSentinelVault} from "../src/PegSentinelVault.sol";

// Run:
// 1. set -a; source .env; set +a

// 1. TestVaultScript - Full vault inspection
// 1b. forge script script/TestVault.s.sol:TestVaultScript --rpc-url $ARB_RPC --broadcast -vvvv --via-ir

// 2. TestAutoRebalanceScript - Test automatic rebalancing
// 2b. forge script script/TestVault.s.sol:TestAutoRebalanceScript --rpc-url $ARB_RPC --broadcast -vvvv --via-ir

// 3. TestForceRebalanceScript - Force regime change
// 3a. TARGET_REGIME=1 forge script script/TestVault.s.sol:TestForceRebalanceScript --rpc-url $ARB_RPC --broadcast -vvvv --via-ir
// 3b. ARGET_REGIME=2 forge script script/TestVault.s.sol:TestForceRebalanceScript --rpc-url $ARB_RPC --broadcast -vvvv --via-ir

/// @title TestVaultScript
/// @notice Tests all core vault functions: config, regimes, thresholds, and needsRebalance
contract TestVaultScript is Script, BaseScript {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));

        console2.log("========================================");
        console2.log("       PegSentinelVault Test Script     ");
        console2.log("========================================");
        console2.log("");

        // ============ 1. Basic Config ============
        console2.log("=== 1. BASIC CONFIGURATION ===");
        console2.log("Vault address:", vaultAddr);
        console2.log("Owner:", vault.owner());
        console2.log("Keeper:", vault.keeper());
        console2.log("Token0:", address(vault.token0()));
        console2.log("Token1:", address(vault.token1()));
        console2.log("PositionManager:", address(vault.positionManager()));
        console2.log("Permit2:", address(vault.permit2()));
        console2.log("Rebalance cooldown:", vault.rebalanceCooldown());
        console2.log("Last rebalance at:", vault.lastRebalanceAt());
        console2.log("");

        // ============ 2. Regime Configuration ============
        console2.log("=== 2. REGIME CONFIGURATION ===");
        console2.log("Active regime:", uint256(vault.activeRegime()));
        console2.log("  (0=Normal, 1=Mild, 2=Severe)");
        console2.log("");

        // Normal range
        (int24 nLo, int24 nHi, bool nEn) = vault.normalRange();
        console2.log("Normal Range:");
        console2.log("  tickLower:", int256(nLo));
        console2.log("  tickUpper:", int256(nHi));
        console2.log("  enabled:", nEn);

        // Mild range
        (int24 mLo, int24 mHi, bool mEn) = vault.mildRange();
        console2.log("Mild Range:");
        console2.log("  tickLower:", int256(mLo));
        console2.log("  tickUpper:", int256(mHi));
        console2.log("  enabled:", mEn);

        // Severe range
        (int24 sLo, int24 sHi, bool sEn) = vault.severeRange();
        console2.log("Severe Range:");
        console2.log("  tickLower:", int256(sLo));
        console2.log("  tickUpper:", int256(sHi));
        console2.log("  enabled:", sEn);
        console2.log("");

        // ============ 3. Thresholds ============
        console2.log("=== 3. REGIME THRESHOLDS ===");
        console2.log("Mild threshold:", int256(vault.mildThreshold()));
        console2.log("Severe threshold:", int256(vault.severeThreshold()));
        console2.log("  (tick <= severe => Severe)");
        console2.log("  (tick <= mild => Mild)");
        console2.log("  (else => Normal)");
        console2.log("");

        // ============ 4. Position Metadata ============
        console2.log("=== 4. POSITION METADATA ===");
        
        (uint256 nTokenId, int24 nPosLo, int24 nPosHi, bytes32 nSalt, uint128 nLiq, bool nActive) = vault.normalPosition();
        console2.log("Normal Position:");
        console2.log("  tokenId:", nTokenId);
        console2.log("  tickLower:", int256(nPosLo));
        console2.log("  tickUpper:", int256(nPosHi));
        console2.log("  liquidity:", uint256(nLiq));
        console2.log("  active:", nActive);

        (uint256 sTokenId, int24 sPosLo, int24 sPosHi, bytes32 sSalt, uint128 sLiq, bool sActive) = vault.supportPosition();
        console2.log("Support Position:");
        console2.log("  tokenId:", sTokenId);
        console2.log("  tickLower:", int256(sPosLo));
        console2.log("  tickUpper:", int256(sPosHi));
        console2.log("  liquidity:", uint256(sLiq));
        console2.log("  active:", sActive);
        console2.log("");

        // ============ 5. Vault Balances ============
        console2.log("=== 5. VAULT BALANCES ===");
        (uint256 bal0, uint256 bal1) = vault.balances();
        console2.log("Token0 balance:", bal0);
        console2.log("Token1 balance:", bal1);
        console2.log("");

        // ============ 6. Pool State & Regime Detection ============
        console2.log("=== 6. POOL STATE & REGIME DETECTION ===");
        
        // Only test if poolKey is configured
        PoolId poolId = vault.getPoolId();
        if (PoolId.unwrap(poolId) != bytes32(0)) {
            int24 currentTick = vault.getCurrentTick();
            console2.log("Current tick:", int256(currentTick));

            PegSentinelVault.Regime determinedRegime = vault.determineRegime(currentTick);
            console2.log("Determined regime for current tick:", uint256(determinedRegime));

            PegSentinelVault.Regime targetRegime = vault.getTargetRegime();
            console2.log("Target regime (from getTargetRegime):", uint256(targetRegime));


        } else {
            console2.log("Pool key not configured yet - skipping pool state checks");
        }
        console2.log("");

        // ============ 7. Test Admin Functions (broadcast) ============
        console2.log("=== 7. TESTING ADMIN FUNCTIONS ===");
        
        vm.startBroadcast(pk);

        // Test setThresholds
        // Set thresholds to match ranges:
        // Tick > -240 → Normal (range -240 to 240)
        // Tick <= -240 and > -540 → Mild (range -540 to 0)  
        // Tick <= -540 → Severe (range -1620 to -300)
        console2.log("Setting thresholds: mild=-240, severe=-540...");
        vault.setThresholds(-240, -540);
        console2.log("  Thresholds set successfully");

        // needsRebalance check
        (bool needed, PegSentinelVault.Regime currReg, PegSentinelVault.Regime targReg, int24 tick) = vault.needsRebalance();
        console2.log("");
        console2.log("needsRebalance() result:");
        console2.log("  needs rebalance:", needed);
        console2.log("  current regime:", uint256(currReg));
        console2.log("  target regime:", uint256(targReg));
        console2.log("  current tick:", int256(tick));


        // Test setRebalanceCooldown
        console2.log("Setting rebalance cooldown to 60 seconds...");
        vault.setRebalanceCooldown(60);
        console2.log("  Cooldown set to:", vault.rebalanceCooldown());

        // Test setActiveRegime
        console2.log("Setting active regime to Normal (0)...");
        vault.setActiveRegime(PegSentinelVault.Regime.Normal);
        console2.log("  Active regime now:", uint256(vault.activeRegime()));

        // Test setAllowedTarget
        address testTarget = address(0x1234567890123456789012345678901234567890);
        console2.log("Setting test target as allowed...");
        vault.setAllowedTarget(testTarget, true);
        console2.log("  isAllowedTarget:", vault.isAllowedTarget(testTarget));

        // Remove it
        vault.setAllowedTarget(testTarget, false);
        console2.log("  Removed, isAllowedTarget:", vault.isAllowedTarget(testTarget));

        vm.stopBroadcast();

        console2.log("");
        console2.log("========================================");
        console2.log("       All Tests Completed!             ");
        console2.log("========================================");
    }
}


/// @title TestAutoRebalanceScript  
/// @notice Tests the autoRebalance function (requires funded position)
contract TestAutoRebalanceScript is Script, BaseScript {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));

        console2.log("========================================");
        console2.log("     Test autoRebalance Function        ");
        console2.log("========================================");
        console2.log("");

        // Check if rebalance is needed
        (bool needed, PegSentinelVault.Regime currReg, PegSentinelVault.Regime targReg, int24 tick) = vault.needsRebalance();
        
        console2.log("Current state:");
        console2.log("  Current tick:", int256(tick));
        console2.log("  Current regime:", uint256(currReg));
        console2.log("  Target regime:", uint256(targReg));
        console2.log("  Needs rebalance:", needed);
        console2.log("");

        if (!needed) {
            console2.log("No rebalance needed - regimes match");
            console2.log("To test, either:");
            console2.log("  1. Swap to move the price (change tick)");
            console2.log("  2. Use forceRebalance(Regime) to force a regime change");
            return;
        }

        console2.log("Rebalance IS needed. Executing autoRebalance()...");
        
        vm.startBroadcast(pk);
        
        vault.autoRebalance();
        
        vm.stopBroadcast();

        // Check new state
        (bool neededAfter, PegSentinelVault.Regime currRegAfter, PegSentinelVault.Regime targRegAfter, int24 tickAfter) = vault.needsRebalance();
        
        console2.log("");
        console2.log("After rebalance:");
        console2.log("  Current tick:", int256(tickAfter));
        console2.log("  Current regime:", uint256(currRegAfter));
        console2.log("  Target regime:", uint256(targRegAfter));
        console2.log("  Needs rebalance:", neededAfter);
        
        console2.log("");
        console2.log("autoRebalance test complete!");
    }
}


/// @title TestForceRebalanceScript
/// @notice Tests forceRebalance to a specific regime
contract TestForceRebalanceScript is Script, BaseScript {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        uint256 targetRegimeRaw = vm.envOr("TARGET_REGIME", uint256(1)); // Default to Mild

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));
        PegSentinelVault.Regime targetRegime = PegSentinelVault.Regime(targetRegimeRaw);

        console2.log("========================================");
        console2.log("     Test forceRebalance Function       ");
        console2.log("========================================");
        console2.log("");

        console2.log("Current active regime:", uint256(vault.activeRegime()));
        console2.log("Target regime:", uint256(targetRegime));
        console2.log("");

        if (vault.activeRegime() == targetRegime) {
            console2.log("Already in target regime! Set TARGET_REGIME env to a different value.");
            console2.log("  0 = Normal");
            console2.log("  1 = Mild");
            console2.log("  2 = Severe");
            return;
        }

        console2.log("Executing forceRebalance...");
        
        vm.startBroadcast(pk);
        
        vault.forceRebalance(targetRegime);
        
        vm.stopBroadcast();

        console2.log("");
        console2.log("After forceRebalance:");
        console2.log("  Active regime:", uint256(vault.activeRegime()));
        
        // Show position info
        if (targetRegime == PegSentinelVault.Regime.Normal) {
            (uint256 tokenId,,,,uint128 liq, bool active) = vault.normalPosition();
            console2.log("  Normal position tokenId:", tokenId);
            console2.log("  Normal position liquidity:", uint256(liq));
            console2.log("  Normal position active:", active);
        } else {
            (uint256 tokenId,,,,uint128 liq, bool active) = vault.supportPosition();
            console2.log("  Support position tokenId:", tokenId);
            console2.log("  Support position liquidity:", uint256(liq));
            console2.log("  Support position active:", active);
        }

        console2.log("");
        console2.log("forceRebalance test complete!");
    }
}
