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

import {PegSentinelVault} from "../src/PegSentinelVault.sol";

// 1. set -a; source .env.anvil; set +a;
// 2. forge script script/05_MintPositionToVault.s.sol:MintPositionToVault --rpc-url $RPC_URL --broadcast -vvvv --via-ir


/// Minimal interface for Permit2 approve used in your helper
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}


contract MintPositionToVault is Script, BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint24 lpFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 tickSpacing = 60;

    function run() external {
        // ---- env ----
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        uint256 amount0 = vm.envUint("AMOUNT0");
        uint256 amount1 = vm.envUint("AMOUNT1");

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));

        // ---- pool key ----
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        bytes memory hookData = new bytes(0);

        // ---- read Normal range from vault (must already be configured) ----
        (int24 tickLower, int24 tickUpper, bool enabled) = vault.normalRange();
        require(enabled, "vault.normalRange not enabled");
        require(tickLower < tickUpper, "invalid ticks");
        require(tickLower % tickSpacing == 0 && tickUpper % tickSpacing == 0, "ticks not aligned");

        // Optional: log current tick/price context
        (uint160 sqrtPriceX96Now,,,) = poolManager.getSlot0(poolKey.toId());
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96Now);

        console2.log("=== MintPositionToVault (Normal) ===");
        console2.log("vault:", vaultAddr);
        console2.log("currentTick:", int256(currentTick));
        console2.log("tickLower:", int256(tickLower));
        console2.log("tickUpper:", int256(tickUpper));
        console2.log("amount0:", amount0);
        console2.log("amount1:", amount1);

        vm.startBroadcast(pk);

        // --- allowlist targets the vault will call ---
        vault.setAllowedTarget(address(positionManager), true);
        vault.setAllowedTarget(address(permit2), true);

        address t0 = address(0);
        address t1 = address(0);

        if (!currency0.isAddressZero()) {
            t0 = Currency.unwrap(currency0);
            vault.setAllowedTarget(t0, true);
        }
        if (!currency1.isAddressZero()) {
            t1 = Currency.unwrap(currency1);
            vault.setAllowedTarget(t1, true);
        }

        // ---- approvals FROM VAULT (idempotent) ----
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

        // ---- compute liquidity at current price ----
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96Now,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        uint256 amount0Max = amount0 + 1;
        uint256 amount1Max = amount1 + 1;

        (bytes memory actions, bytes[] memory params) =
            _mintLiquidityParams(
                poolKey,
                tickLower,
                tickUpper,
                uint256(liq),
                amount0Max,
                amount1Max,
                vaultAddr, // vault owns the position NFT
                hookData
            );

        bytes memory mintCall = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(actions, params),
            block.timestamp + 60
        );

        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        uint256 tokenId = positionManager.nextTokenId();
        console2.log("Minting tokenId:", tokenId);

        vault.execute(address(positionManager), valueToPass, mintCall);

        // ---- register the new baseline position in the vault ----
        vault.setNormalPosition(tokenId, tickLower, tickUpper, bytes32(tokenId), true);
        vault.setActiveRegime(PegSentinelVault.Regime.Normal);

        vm.stopBroadcast();

        console2.log("Minted NORMAL position to vault.");
        console2.log("tokenId:", tokenId);
    }
}