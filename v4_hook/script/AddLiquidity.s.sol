// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// Usage:
// 1. set -a; source .env; set +a
// 2. Optional: export AMOUNT0=10000000000 AMOUNT1=10000000000  (10,000 USDT/USDC with 6 decimals)
// 3. forge script script/AddLiquidity.s.sol:AddLiquidityScript --rpc-url $ARB_RPC --broadcast -vv --via-ir

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";
import {PegSentinelVault} from "../src/PegSentinelVault.sol";

// Sepolia:
// 1. set -a; source .env; set +a
// 2. forge script script/AddLiquidity.s.sol --rpc-url $ARB_RPC --broadcast -vvvv --via-ir


interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @title AddLiquidityScript
/// @notice Adds liquidity to existing PegSentinel vault position
contract AddLiquidityScript is Script, BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        // --- Environment Variables ---
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        
        // Token amounts (default: 1000 tokens with 6 decimals = 1000e6)
        uint256 amount0 = vm.envOr("AMOUNT0", uint256(1000e6));
        uint256 amount1 = vm.envOr("AMOUNT1", uint256(1000e6));
        
        uint24 lpFee = uint24(vm.envOr("LP_FEE", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        uint256 deadlineSeconds = vm.envOr("DEADLINE_SECONDS", uint256(300));

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));

        // --- Get existing position from vault (6 fields now) ---
        (
            uint256 tokenId,
            int24 tickLower,
            int24 tickUpper,
            ,  // salt
            ,  // liquidity
            bool active
        ) = vault.normalPosition();
        
        require(active, "Normal position not active");
        require(tokenId != 0, "No existing position");

        // --- Pool Key ---
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });
        
        PoolId pid = poolKey.toId();
        bytes memory hookData = new bytes(0);

        // --- Get Current Pool State ---
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pid);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        console2.log("=== AddLiquidity to Existing Position ===");
        console2.log("vault:", vaultAddr);
        console2.log("tokenId:", tokenId);
        console2.log("tickLower:", int256(tickLower));
        console2.log("tickUpper:", int256(tickUpper));
        console2.log("currentTick:", int256(currentTick));
        console2.log("amount0 (USDT):", amount0);
        console2.log("amount1 (USDC):", amount1);

        // --- Calculate Liquidity ---
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        
        console2.log("liquidity to add:", uint256(liquidity));

        // Slippage buffer
        uint256 amount0Max = amount0 + 1;
        uint256 amount1Max = amount1 + 1;

        // --- Get token addresses ---
        address t0 = Currency.unwrap(currency0);
        address t1 = Currency.unwrap(currency1);

        vm.startBroadcast(pk);

        // 1. Transfer tokens from caller to vault
        console2.log("Transferring tokens to vault...");
        if (t0 != address(0)) {
            IERC20(t0).transfer(vaultAddr, amount0);
        }
        if (t1 != address(0)) {
            IERC20(t1).transfer(vaultAddr, amount1);
        }

        // 2. Setup vault allowlists (idempotent)
        vault.setAllowedTarget(address(positionManager), true);
        vault.setAllowedTarget(address(permit2), true);
        if (t0 != address(0)) vault.setAllowedTarget(t0, true);
        if (t1 != address(0)) vault.setAllowedTarget(t1, true);

        // 3. Approvals from vault to Permit2 and PositionManager
        console2.log("Setting up approvals...");
        if (t0 != address(0)) {
            vault.execute(
                t0,
                0,
                abi.encodeWithSelector(IERC20.approve.selector, address(permit2), type(uint256).max)
            );
            vault.execute(
                address(permit2),
                0,
                abi.encodeWithSelector(
                    IPermit2.approve.selector,
                    t0,
                    address(positionManager),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        }
        if (t1 != address(0)) {
            vault.execute(
                t1,
                0,
                abi.encodeWithSelector(IERC20.approve.selector, address(permit2), type(uint256).max)
            );
            vault.execute(
                address(permit2),
                0,
                abi.encodeWithSelector(
                    IPermit2.approve.selector,
                    t1,
                    address(positionManager),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        }

        // 4. Increase liquidity via vault.execute()
        console2.log("Increasing liquidity...");
        (bytes memory incActions, bytes[] memory incParams) = _increaseLiquidityParams(
            tokenId,
            uint256(liquidity),
            amount0Max,
            amount1Max,
            hookData
        );

        bytes memory incCall = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(incActions, incParams),
            block.timestamp + deadlineSeconds
        );

        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;
        vault.execute(address(positionManager), valueToPass, incCall);

        vm.stopBroadcast();

        console2.log("=== Done ===");
        console2.log("Added liquidity to position #", tokenId);
    }
}
