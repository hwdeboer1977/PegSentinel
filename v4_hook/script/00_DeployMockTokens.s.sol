// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Run on Sepolia Arbitrum:
// 1. set -a; source .env; set +a
// 2. forge script script/00_DeployMockTokens.s.sol:DeployMockTokens --rpc-url $ARB_RPC --broadcast -vvvv --via-ir

// Run on anvil:
// 1. set -a; source .env; set +a
// 2. anvil --fork-url $ARB_RPC --dump-state state.json

// 3. set -a; source .env.anvil; set +a
// 4. forge script script/00_DeployMockTokens.s.sol:DeployMockTokens --rpc-url http://127.0.0.1:8545 --broadcast -vvvv --via-ir
// Store token addresses in .env.anvil
// Update base/BaseScript.sol with addresses token0 and token1 
import "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockUSDT} from "../src/MockUSDT.sol";

contract DeployMockTokens is Script {
    function run() external {
        // --- Env ---
        // PRIVATE_KEY: uint256 private key of deployer
        // RECIPIENT: address receiving initial supply (e.g., your EOA)
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address recipient = vm.envAddress("WALLET_ADDRESS");

        uint256 usdcHuman = uint256(100_000_000);
        uint256 usdtHuman = uint256(100_000_000);

        uint256 usdcInitial = usdcHuman * 10 ** 6;     // 6 decimals
        uint256 usdtInitial = usdtHuman * 10 ** 6;     // 6 decimals

        vm.startBroadcast(pk);

        MockUSDC usdc = new MockUSDC(recipient, usdcInitial);
        MockUSDT usdt = new MockUSDT(recipient, usdtInitial);

        vm.stopBroadcast();

        console2.log("Deployer:", vm.addr(pk));
        console2.log("USDC:    ", address(usdc));
        console2.log("USDT:    ", address(usdt));

    }
}
