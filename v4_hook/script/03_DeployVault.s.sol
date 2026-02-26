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
// - POOL_MANAGER        (Uniswap V4 PoolManager)
// - POSITION_MANAGER    (Uniswap V4 PositionManager)
// - PERMIT2             (Permit2 contract)
// - HOOK_ADDRESS        (PegSentinelHook address)
// - POOL_FEE            (e.g. 500 for 0.05%)
// - TICK_SPACING        (e.g. 10)

contract DeployVault is Script {
    function run() external returns (PegSentinelVault vault) {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));

        address token0 = vm.envAddress("TOKEN0_ADDRESS");
        address token1 = vm.envAddress("TOKEN1_ADDRESS");
        address owner  = vm.envAddress("OWNER");

        // Optional: read infra addresses from env (with defaults for local testing)
        address poolManager     = vm.envOr("POOL_MANAGER", address(0));
        address positionManager = vm.envOr("POSITION_MANAGER", address(0));
        address permit2Addr     = vm.envOr("PERMIT2", address(0));
        address hookAddress     = vm.envOr("HOOK_ADDRESS", address(0));
        uint24  poolFee         = uint24(vm.envOr("POOL_FEE", uint256(500)));
        int24   tickSpacing     = int24(int256(vm.envOr("TICK_SPACING", uint256(10))));

        vm.startBroadcast(pk);

        vault = new PegSentinelVault(token0, token1, owner);

        // ------------------------------------------------------------
        // Set Uniswap V4 infrastructure (if addresses provided)
        // ------------------------------------------------------------
        if (poolManager != address(0)) {
            vault.setPoolManager(poolManager);
        }
        if (positionManager != address(0)) {
            vault.setPositionManager(positionManager);
        }
        if (permit2Addr != address(0)) {
            vault.setPermit2(permit2Addr);
        }

        // Allow positionManager and permit2 as execution targets
        if (positionManager != address(0)) {
            vault.setAllowedTarget(positionManager, true);
        }
        if (permit2Addr != address(0)) {
            vault.setAllowedTarget(permit2Addr, true);
        }

        // ------------------------------------------------------------
        // Set pool key (links vault to the correct Uniswap V4 pool)
        // ------------------------------------------------------------
        if (hookAddress != address(0)) {
            vault.setPoolKey(token0, token1, poolFee, tickSpacing, hookAddress);
        }

        // ------------------------------------------------------------
        // LP range: tight around peg [-60, +60]
        // LP never moves — this is the core position range.
        // ------------------------------------------------------------
        vault.setLPRange(int24(-60), int24(60));

        // ------------------------------------------------------------
        // Buffer range: below LP [-240, -60]
        // Treasury USDT deployed here during depeg defense.
        // ------------------------------------------------------------
        vault.setBufferRange(int24(-240), int24(-60));

        // ------------------------------------------------------------
        // Regime thresholds with hysteresis:
        //   tick <= -50  → deploy buffer (Defend)
        //   tick >= -30  → remove buffer (Normal)
        // Gap between -50 and -30 prevents oscillation.
        // ------------------------------------------------------------
        vault.setThresholds(int24(-50), int24(-30));

        // ------------------------------------------------------------
        // Cooldown: 60 seconds between rebalances
        // ------------------------------------------------------------
        vault.setRebalanceCooldown(60);

        vm.stopBroadcast();

        // ============================================================
        // Logging
        // ============================================================
        console2.log("=== PegSentinelVault V2 Deployed ===");
        console2.log("Address:", address(vault));
        console2.log("token0 (USDC):", token0);
        console2.log("token1 (USDT):", token1);
        console2.log("owner:", owner);
        console2.log("");

        console2.log("=== Uniswap V4 Infrastructure ===");
        console2.log("PoolManager:", poolManager);
        console2.log("PositionManager:", positionManager);
        console2.log("Permit2:", permit2Addr);
        console2.log("Hook:", hookAddress);
        console2.log("");

        // Log ranges
        (int24 lpLo, int24 lpHi) = vault.lpRange();
        (int24 bufLo, int24 bufHi) = vault.bufferRange();

        console2.log("=== Ranges ===");
        console2.log("LP range (at peg, never moves):");
        console2.log("  tickLower:", int256(lpLo));
        console2.log("  tickUpper:", int256(lpHi));
        console2.log("Buffer range (treasury USDT during depeg):");
        console2.log("  tickLower:", int256(bufLo));
        console2.log("  tickUpper:", int256(bufHi));
        console2.log("");

        // Log thresholds
        console2.log("=== Thresholds (with hysteresis) ===");
        console2.log("Defend threshold:", int256(vault.defendThreshold()));
        console2.log("Recover threshold:", int256(vault.recoverThreshold()));
        console2.log("");
        console2.log("Regime logic:");
        console2.log("  tick <= -50  -> Defend (deploy buffer)");
        console2.log("  tick >= -30  -> Normal (remove buffer)");
        console2.log("  -50 < tick < -30 -> no change (hysteresis)");
        console2.log("");

        console2.log("=== Next Steps ===");
        console2.log("1. Set keeper:       vault.setKeeper(keeperAddr)");
        console2.log("2. Fund vault:       vault.fund(usdcAmt, usdtAmt)");
        console2.log("3. Mint LP position: (via separate script)");
        console2.log("4. Register LP:      vault.setLPPosition(tokenId, -60, 60, salt, true)");
        console2.log("5. Keeper runs:      vault.collectFees() + vault.autoRebalance()");
    }
}
