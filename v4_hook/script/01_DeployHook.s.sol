// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BaseScript} from "./base/BaseScript.sol";

import {PegSentinelHook} from "../src/PegSentinelHook.sol";

import "forge-std/Script.sol";

// Testnet
// forge script script/01_DeployHook.s.sol  --rpc-url arbitrum_sepolia --private-key 0xYOUR_PRIVATE_KEY --broadcast


// Anvil:
// 1. set -a; source .env.anvil; set +a
// 2. forge script script/01_DeployHook.s.sol --rpc-url http://127.0.0.1:8545 --private-key 0xYOUR_PRIVATE_KEY --broadcast -vvvv --via-ir

// This code follows https://github.com/uniswapfoundation/v4-template

// 1. Update addresses token0 and token1 in BaseScript.sol
// 2. Run this deployscript 
// 3. Update hook address in BaseScript.sol
// 4. Run other scripts to add liquidity, swap tokens etc

/// @notice Mines the address and deploys the Peghook.sol Hook contract

contract DeployHookScript is BaseScript {
    function run() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG
        );

        // Use token0 and token1 from BaseScript
        bytes memory constructorArgs = abi.encode(poolManager, address(token0), address(token1));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(PegSentinelHook).creationCode, constructorArgs);

        vm.startBroadcast();
        PegSentinelHook hook = new PegSentinelHook{salt: salt}(poolManager, address(token0), address(token1));
        vm.stopBroadcast();

        console.log("Hook address: ", hookAddress);
        require(address(hook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}