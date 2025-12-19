// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";

// Anvil:
// 1. set -a; source .env.anvil; set +a
// 2. forge script script/03b_RemoveLiquidity.s.sol --rpc-url http://127.0.0.1:8545 --private-key 0xYOUR_PRIVATE_KEY --broadcast -vvvv --via-ir


contract RemoveLiquidityScript is BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint24 lpFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 tickSpacing = 60;

    uint256 public token0Amount = 100000e6;
    uint256 public token1Amount = 100000e6;

    int24 tickLower;
    int24 tickUpper;

    function run() external {
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        bytes memory hookData = new bytes(0);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        tickLower = truncateTickSpacing((currentTick - 1000 * tickSpacing), tickSpacing);
        tickUpper = truncateTickSpacing((currentTick + 1000 * tickSpacing), tickSpacing);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        uint256 amount0Min = 0;  // Set to 0 for testing, or calculate slippage
        uint256 amount1Min = 0;

        // Build DECREASE_LIQUIDITY action bundle
        (bytes memory actions, bytes[] memory p) =
            _decreaseLiquidityParams(184, liquidity, amount0Min, amount1Min, deployerAddress, hookData);

        // multicall payload
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(actions, p),
            block.timestamp + 60
        );

        vm.startBroadcast();
        positionManager.multicall(calls);
        vm.stopBroadcast();
    }
}