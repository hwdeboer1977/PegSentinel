// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import "forge-std/Script.sol";

// forge script script/02_CreatePoolAndAddLiquidity.s.sol --rpc-url arbitrum_sepolia --private-key 0xYOUR_PRIVATE_KEY --broadcast -vvvv --via-ir

// Anvil
// 1. set -a; source .env.anvil; set +a
// 2. forge script script/02_CreatePoolAndAddLiquidity.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvvv --via-ir

contract CreatePoolAndAddLiquidityScript is BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;

    // -----------------------------
    // Price helpers (unchanged)
    // -----------------------------
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // price = token1 per token0 = (num / den) in human units
    function sqrtPriceX96FromPriceFraction(
        uint256 num,
        uint256 den,
        uint8 decimalsToken0,
        uint8 decimalsToken1
    ) internal pure returns (uint160) {
        uint256 numerator   = num * (10 ** decimalsToken1);
        uint256 denominator = den * (10 ** decimalsToken0);

        uint256 ratioX192 = (numerator << 192) / denominator;
        uint256 sqrtX96 = _sqrt(ratioX192);
        require(sqrtX96 <= type(uint160).max, "sqrtPriceX96 overflow");
        return uint160(sqrtX96);
    }

    // range of the position, must be a multiple of tickSpacing
    int24 tickLower;
    int24 tickUpper;

    function run() external {
        // -----------------------------
        // Read config from .env / .env.anvil
        // -----------------------------
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));

        uint24 lpFee = uint24(vm.envOr("LP_FEE", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        int24 rangeMult = int24(int256(vm.envOr("RANGE_MULT", uint256(750))));
        uint256 deadlineSeconds = vm.envOr("DEADLINE_SECONDS", uint256(3600));

        uint256 token0Amount = vm.envUint("AMOUNT0");
        uint256 token1Amount = vm.envUint("AMOUNT1");

        uint256 priceNum = vm.envOr("START_PRICE_NUM", uint256(1));
        uint256 priceDen = vm.envOr("START_PRICE_DEN", uint256(1));

        // IMPORTANT:
        // Your original script hardcoded decimals=6/6.
        // Keep that for now (stable across anvil mocks if you use 6-dec mocks).
        // If you want live decimals per network, we can switch to IERC20Metadata later.
        uint160 startingPrice = sqrtPriceX96FromPriceFraction(
            priceNum,
            priceDen,
            6, // token0 decimals
            6  // token1 decimals
        );

        // -----------------------------
        // PoolKey (same)
        // -----------------------------
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        bytes memory hookData = new bytes(0);

        int24 currentTick = TickMath.getTickAtSqrtPrice(startingPrice);

        // tickLower = truncateTickSpacing((currentTick - rangeMult * tickSpacing), tickSpacing);
        // tickUpper = truncateTickSpacing((currentTick + rangeMult * tickSpacing), tickSpacing);
        tickLower = -180;
        tickUpper = 180;
        
        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        console2.log("=== Pre-Transaction Balances ===");
        console2.log("Deployer:", deployerAddress);
        console2.log(
            "Token0 balance:",
            currency0.isAddressZero()
                ? deployerAddress.balance
                : IERC20(Currency.unwrap(currency0)).balanceOf(deployerAddress)
        );
        console2.log("Token1 balance:", IERC20(Currency.unwrap(currency1)).balanceOf(deployerAddress));

        // slippage limits
        uint256 amount0Max = token0Amount + 1;
        uint256 amount1Max = token1Amount + 1;

        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            deployerAddress,
            hookData
        );

        // multicall parameters
        bytes[] memory params = new bytes[](2);

        // Initialize Pool
        params[0] = abi.encodeWithSelector(
            positionManager.initializePool.selector,
            poolKey,
            startingPrice,
            hookData
        );

        // Mint Liquidity
        params[1] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            block.timestamp + deadlineSeconds
        );

        // If the pool is an ETH pair, native tokens are to be transferred
        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        // Get tokenId before minting
        uint256 tokenId = positionManager.nextTokenId();
        console2.log("Next Token ID (will be yours):", tokenId);

        // Broadcast using env key (no --private-key needed)
        vm.startBroadcast(pk);

        tokenApprovals();

        // Multicall to atomically create pool & add liquidity
        positionManager.multicall{value: valueToPass}(params);

        vm.stopBroadcast();

        console2.log("Position Token ID:", tokenId);
        console2.log("tickLower:", tickLower);
        console2.log("tickUpper:", tickUpper);
        console2.log("startingPriceX96:", startingPrice);
    }
}