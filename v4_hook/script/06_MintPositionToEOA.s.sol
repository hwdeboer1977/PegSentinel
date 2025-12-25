// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";

// Usage:
// 1. set -a; source .env; set +a
// 2. export AMOUNT0=1000000000 AMOUNT1=1000000000  (1,000 USDT/USDC with 6 decimals)
// 3. forge script script/06_MintPositionToEOA.s.sol:MintFullRangePosition --rpc-url $ARB_RPC --broadcast -vv --via-ir

/// @title MintFullRangePosition
/// @notice Mints a full-range background liquidity position to your EOA
/// @dev This provides liquidity across all ticks so price can move gradually
contract MintFullRangePosition is Script, BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint24 lpFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 tickSpacing = 60;

    function run() external {
        // ---- env ----
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        uint256 amount0 = vm.envOr("AMOUNT0", uint256(1000e6)); // Default 1,000 USDT
        uint256 amount1 = vm.envOr("AMOUNT1", uint256(1000e6)); // Default 1,000 USDC

        // ---- pool key ----
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        bytes memory hookData = new bytes(0);

        // ---- full range ticks (aligned to tickSpacing) ----
        // TickMath.MIN_TICK = -887272, MAX_TICK = 887272
        // We need to align to tickSpacing (60)
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing; // -887220
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing; // 887220

        // ---- read current price ----
        (uint160 sqrtPriceX96Now,,,) = poolManager.getSlot0(poolKey.toId());
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96Now);

        console2.log("=== MintFullRangePosition (to EOA) ===");
        console2.log("currentTick:", int256(currentTick));
        console2.log("tickLower:", int256(tickLower));
        console2.log("tickUpper:", int256(tickUpper));
        console2.log("amount0 (USDT):", amount0);
        console2.log("amount1 (USDC):", amount1);

        // ---- compute liquidity ----
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96Now,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        console2.log("liquidity:", uint256(liq));

        uint256 amount0Max = amount0 + 1;
        uint256 amount1Max = amount1 + 1;

        vm.startBroadcast(pk);

        // ---- token approvals (EOA approves Permit2) ----
        tokenApprovals();

        // ---- build mint params ----
        (bytes memory actions, bytes[] memory params) = _mintLiquidityParams(
            poolKey,
            tickLower,
            tickUpper,
            uint256(liq),
            amount0Max,
            amount1Max,
            deployerAddress, // EOA owns the position
            hookData
        );

        // ---- mint via multicall ----
        bytes[] memory multicallParams = new bytes[](1);
        multicallParams[0] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(actions, params),
            block.timestamp + 60
        );

        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        uint256 tokenId = positionManager.nextTokenId();
        console2.log("Minting tokenId:", tokenId);

        positionManager.multicall{value: valueToPass}(multicallParams);

        vm.stopBroadcast();

        console2.log("=== Done ===");
        console2.log("Minted FULL RANGE position to EOA");
        console2.log("tokenId:", tokenId);
        console2.log("owner:", deployerAddress);
    }
}
