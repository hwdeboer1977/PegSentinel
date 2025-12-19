// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


// forge script script/04_Swap.s.sol --rpc-url arbitrum_sepolia --private-key 0xYOUR_PRIVATE_KEY --broadcast

// 1. set -a; source .env.anvil; set +a
// 2. forge script script/04_Swap.s.sol --rpc-url http://127.0.0.1:8545 --private-key 0xYOUR_PRIVATE_KEY --broadcast -vvvv --via-ir


import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {console2} from "forge-std/console2.sol";
import {BaseScript} from "./base/BaseScript.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

contract SwapScript is BaseScript {
    function run() external {

        uint24 lpFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: 60,
            hooks: hookContract // This must match the pool
        });
        bytes memory hookData = new bytes(0);

        PoolId testPid = PoolIdLibrary.toId(poolKey);
        console2.logString("PoolId (bytes32):");
        console2.logBytes32(PoolId.unwrap(testPid));

        vm.startBroadcast();
        address recipient = msg.sender; // the EOA you’re broadcasting with

        // We'll approve both, just for testing.
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);

        console2.log("Address Swaprouter: ", address(swapRouter));
        console2.log("Address Poolmanager: ", address(poolManager));
        // Execute swap
        swapRouter.swapExactTokensForTokens({
            amountIn: 40e6,
            amountOutMin: 0, // Very bad, but we want to allow for unlimited price impact
            zeroForOne: true,
            poolKey: poolKey,
            hookData: hookData,
            receiver: recipient,
            deadline: block.timestamp + 30
        });

        // ---- Proper logging ----
        console2.log("--- PoolKey ---");
        console2.log("currency0", Currency.unwrap(poolKey.currency0));
        console2.log("currency1", Currency.unwrap(poolKey.currency1));
        console2.log("fee(uint24)", uint256(poolKey.fee));
        console2.log("tickSpacing(int24)", int256(poolKey.tickSpacing));
        console2.log("hooks", address(hookContract));

        console2.log("--- Hook Data ---");
        //console2.log(hookData);

        console2.log("--- This Contract ---");
        //console2.log("this", address(this));

        console2.log("Address swapRouter:", address(swapRouter));

        vm.stopBroadcast();
    }
}
