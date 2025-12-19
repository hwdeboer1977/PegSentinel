// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// Anvil:
// 1. set -a; source .env.anvil; set +a
// 2. forge script script/05_check_liquidity.s.sol --rpc-url http://127.0.0.1:8545 --private-key 0xYOUR_PRIVATE_KEY --broadcast -vvvv --via-ir


import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";

contract CheckLiquidityScript is BaseScript {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external view {
        // ---- HARD CODE ----
        uint256 tokenId = 184;
        int24 tickLower = -45000;
        int24 tickUpper =  45000;
        bytes32 salt = bytes32(tokenId);
        // -------------------



        // same pool params as your other scripts
        uint24 lpFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        int24 tickSpacing = 60;

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        PoolId pid = poolKey.toId();

        console2.log("=== CheckLiquidity (PoolManager PositionInfo) ===");
        console2.log("tokenId:", tokenId);
        console2.log("salt:");
        console2.logBytes32(salt);

        console2.log("PositionManager (owner in PM):", address(positionManager));
        console2.log("PoolManager:", address(poolManager));
        console2.log("Hook:", address(hookContract));
        console2.log("PoolId:");
        console2.logBytes32(PoolId.unwrap(pid));

        // pool state
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pid);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        console2.log("--- Pool State ---");
        console2.log("sqrtPriceX96:", uint256(sqrtPriceX96));
        console2.log("currentTick:", int256(currentTick));

        console2.log("--- Position Key ---");
        console2.log("tickLower:", int256(tickLower));
        console2.log("tickUpper:", int256(tickUpper));

        // Read position from PoolManager (v4 canonical)
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            poolManager.getPositionInfo(pid, address(positionManager), tickLower, tickUpper, salt);

        console2.log("--- PoolManager PositionInfo ---");
        console2.log("liquidity:", uint256(liquidity));
        console2.log("feeGrowthInside0LastX128:", feeGrowthInside0LastX128);
        console2.log("feeGrowthInside1LastX128:", feeGrowthInside1LastX128);

        bool inRange = (currentTick >= tickLower) && (currentTick < tickUpper);
        console2.log("inRange:", inRange);

        // Convert liquidity -> principal amounts at current price
        if (liquidity > 0) {
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidity
            );

            console2.log("--- Principal (ex-fees) at current price ---");
            console2.log("amount0:", amount0);
            console2.log("amount1:", amount1);
        } else {
            console2.log("NOTE: liquidity=0 => tick mismatch OR salt scheme differs from bytes32(tokenId).");
        }
    }
}
