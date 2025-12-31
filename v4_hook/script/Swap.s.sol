// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


// Run on Sepolia Arbitrum:
// 1. set -a; source .env; set +a
// 2. forge script script/Swap.s.sol --rpc-url $ARB_RPC --broadcast -vv --via-ir


// 1. set -a; source .env.anvil; set +a
// 2. forge script script/Swap.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvvv --via-ir

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BaseScript} from "./base/BaseScript.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract SwapScript is Script, BaseScript {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        // ---- Read from .env ----
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        uint256 amountIn = vm.envOr("AMOUNT_IN", uint256(100e6));  // Default 100 tokens
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);          // Default: swap token0 → token1

        // ---- Build pool key ----
        uint24 lpFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        int24 tickSpacing = 60;

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        PoolId poolId = poolKey.toId();
        bytes memory hookData = new bytes(0);

        // ---- Get pool state before swap ----
        (uint160 sqrtPriceBefore, int24 tickBefore,,) = poolManager.getSlot0(poolId);

        console2.log("=== Swap Script ===");
        console2.log("");
        console2.log("--- Pool Key ---");
        console2.log("currency0:", Currency.unwrap(poolKey.currency0));
        console2.log("currency1:", Currency.unwrap(poolKey.currency1));
        console2.log("fee:", uint256(poolKey.fee));
        console2.log("tickSpacing:", int256(poolKey.tickSpacing));
        console2.log("hooks:", address(poolKey.hooks));
        console2.log("");
        console2.log("PoolId:");
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("");
        console2.log("--- Before Swap ---");
        console2.log("sqrtPriceX96:", uint256(sqrtPriceBefore));
        console2.log("tick:", int256(tickBefore));
        console2.log("");
        console2.log("--- Swap Params ---");
        console2.log("amountIn:", amountIn);
        console2.log("zeroForOne:", zeroForOne);
        console2.log("swapRouter:", address(swapRouter));

        vm.startBroadcast(pk);

        // ---- Approve tokens to swapRouter ----
        if (zeroForOne) {
            token0.approve(address(swapRouter), amountIn);
            console2.log("Approved token0 to swapRouter");
        } else {
            token1.approve(address(swapRouter), amountIn);
            console2.log("Approved token1 to swapRouter");
        }

        // ---- Execute swap ----
        address recipient = vm.addr(pk);  // Send output to the signer

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,  // No slippage protection for testing
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: hookData,
            receiver: recipient,
            deadline: block.timestamp + 60
        });

        vm.stopBroadcast();

        // ---- Get pool state after swap ----
        (uint160 sqrtPriceAfter, int24 tickAfter,,) = poolManager.getSlot0(poolId);

        console2.log("");
        console2.log("--- After Swap ---");
        console2.log("sqrtPriceX96:", uint256(sqrtPriceAfter));
        console2.log("tick:", int256(tickAfter));
        console2.log("tick change:", int256(tickAfter - tickBefore));
        console2.log("");
        console2.log("=== Swap Complete ===");
    }
}

