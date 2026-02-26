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
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {PegSentinelVault} from "../src/PegSentinelVault.sol";


// Run on Sepolia Arbitrum:
// 1. set -a; source .env; set +a
// 2. forge script script/05_MintPositionToVault.s.sol:MintPositionToVault --rpc-url $ARB_RPC --broadcast -vv --via-ir

// On Anvil
// 1. set -a; source .env.anvil; set +a;
// 2. forge script script/05_MintPositionToVault.s.sol:MintPositionToVault --rpc-url $RPC_URL --broadcast -vvvv --via-ir


/// Minimal interface for Permit2 approve
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}


contract MintPositionToVault is Script, BaseScript {
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

        // ---- read LP range from vault (must already be configured) ----
        (int24 tickLower, int24 tickUpper) = vault.lpRange();
        require(tickLower < tickUpper, "invalid ticks");
        require(tickLower % tickSpacing == 0 && tickUpper % tickSpacing == 0, "ticks not aligned");

        // Get current tick
        (uint160 sqrtPriceX96Now,,,) = poolManager.getSlot0(poolKey.toId());
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96Now);

        console2.log("=== MintPositionToVault (LP at peg) ===");
        console2.log("vault:", vaultAddr);
        console2.log("currentTick:", int256(currentTick));
        console2.log("tickLower:", int256(tickLower));
        console2.log("tickUpper:", int256(tickUpper));
        console2.log("amount0:", amount0);
        console2.log("amount1:", amount1);

        vm.startBroadcast(pk);

        // ---- Configure vault if not already done ----
        vault.setPoolManager(address(poolManager));  
        vault.setPositionManager(address(positionManager));
        vault.setPermit2(address(permit2));
        vault.setPoolKey(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            lpFee,
            tickSpacing,
            address(hookContract)
        );

        // ---- Fund vault with tokens (from deployer) ----
        address t0 = Currency.unwrap(currency0);
        address t1 = Currency.unwrap(currency1);
        
        if (t0 != address(0)) {
            IERC20(t0).approve(vaultAddr, amount0);
        }
        if (t1 != address(0)) {
            IERC20(t1).approve(vaultAddr, amount1);
        }
        vault.fund(amount0, amount1);

        // ---- Compute liquidity ----
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96Now,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        console2.log("Computed liquidity:", uint256(liq));

        // ---- Build mint action ----
        uint256 amount0Max = amount0 + 1;
        uint256 amount1Max = amount1 + 1;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liq,
            amount0Max,
            amount1Max,
            vaultAddr,  // vault owns the NFT
            bytes("")   // hookData
        );
        params[1] = abi.encode(t0, t1);

        // ---- Set allowed targets BEFORE calling execute ----
        vault.setAllowedTarget(address(positionManager), true);
        vault.setAllowedTarget(address(permit2), true);
        if (t0 != address(0)) {
            vault.setAllowedTarget(t0, true);
        }
        if (t1 != address(0)) {
            vault.setAllowedTarget(t1, true);
        }

        // ---- Approve tokens from vault to Permit2 and PositionManager ----
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

        // ---- Mint via vault.execute ----
        uint256 tokenId = positionManager.nextTokenId();
        console2.log("Minting tokenId:", tokenId);

        bytes memory mintCall = abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector,
            abi.encode(actions, params),
            block.timestamp + 60
        );

        uint256 valueToPass = (t0 == address(0)) ? amount0Max : 0;
        vault.execute(address(positionManager), valueToPass, mintCall);

        // ---- Register LP position in vault (this position never moves) ----
        vault.setLPPosition(tokenId, tickLower, tickUpper, bytes32(tokenId), true);

        vm.stopBroadcast();

        console2.log("=== Done ===");
        console2.log("Minted LP position to vault (never moves)");
        console2.log("tokenId:", tokenId);
        console2.log("");
        console2.log("Next: keeper calls vault.collectFees() periodically");
    }
}
