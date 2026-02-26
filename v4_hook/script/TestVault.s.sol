// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {PegSentinelVault} from "../src/PegSentinelVault.sol";

// Run:
// 1. set -a; source .env.anvil; set +a

// 5. TestKeeperSetupScript - Set keeper and test permissions
//    forge script script/TestVault.s.sol:TestKeeperSetupScript --rpc-url $RPC_URL --broadcast -vvvv --via-ir

// 6. TestWithdrawTreasuryScript - Test treasury withdrawal
//    forge script script/TestVault.s.sol:TestWithdrawTreasuryScript --rpc-url $RPC_URL --broadcast -vvvv --via-ir

// 7. TestPauseScript - Test pause/unpause
//    forge script script/TestVault.s.sol:TestPauseScript --rpc-url $RPC_URL --broadcast -vvvv --via-ir

// 8. TestRescueTokenScript - Test emergency token rescue
//    forge script script/TestVault.s.sol:TestRescueTokenScript --rpc-url $RPC_URL --broadcast -vvvv --via-ir

// 9. TestFullDefenseCycleScript - Full cycle: fees → depeg → buffer → recover → profit
//    forge script script/TestVault.s.sol:TestFullDefenseCycleScript --rpc-url $RPC_URL --broadcast -vvvv --via-ir


/// @title TestKeeperSetupScript
/// @notice Tests setKeeper and verifies keeper can call keeper-gated functions
contract TestKeeperSetupScript is Script, BaseScript {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));

        console2.log("========================================");
        console2.log("       Test Keeper Setup                ");
        console2.log("========================================");
        console2.log("");

        console2.log("Current keeper:", vault.keeper());

        vm.startBroadcast(pk);

        // Set deployer as keeper (for testing)
        address deployer = vm.addr(pk);
        console2.log("Setting keeper to deployer:", deployer);
        vault.setKeeper(deployer);
        console2.log("Keeper now:", vault.keeper());

        // Verify keeper can call collectFees (keeper-gated)
        console2.log("");
        console2.log("Testing keeper can call collectFees()...");
        vault.collectFees();
        console2.log("  Success: keeper can collect fees");

        // Verify keeper can call needsRebalance (view, no gate)
        (bool needed, , , int24 tick) = vault.needsRebalance();
        console2.log("  needsRebalance: needed=", needed);
        console2.log("  tick:", int256(tick));

        vm.stopBroadcast();

        console2.log("");
        console2.log("Keeper setup test complete!");
    }
}


/// @title TestWithdrawTreasuryScript
/// @notice Tests withdrawTreasury — owner pulls profits from vault
contract TestWithdrawTreasuryScript is Script, BaseScript {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        // How much to withdraw (default: 1000 tokens, 6 decimals)
        uint256 withdrawAmount0 = vm.envOr("WITHDRAW_AMOUNT0", uint256(1000e6));
        uint256 withdrawAmount1 = vm.envOr("WITHDRAW_AMOUNT1", uint256(1000e6));

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));
        address deployer = vm.addr(pk);

        console2.log("========================================");
        console2.log("       Test Treasury Withdrawal         ");
        console2.log("========================================");
        console2.log("");

        // Before
        (uint256 vaultBal0, uint256 vaultBal1) = vault.balances();
        (uint256 treas0, uint256 treas1) = vault.treasuryBalances();
        uint256 walletBal0 = IERC20(address(vault.token0())).balanceOf(deployer);
        uint256 walletBal1 = IERC20(address(vault.token1())).balanceOf(deployer);

        console2.log("Before withdrawal:");
        console2.log("  Vault balances  - USDC:", vaultBal0);
        console2.log("  Vault balances  - USDT:", vaultBal1);
        console2.log("  Treasury view   - USDC:", treas0);
        console2.log("  Treasury view   - USDT:", treas1);
        console2.log("  Wallet          - USDC:", walletBal0);
        console2.log("  Wallet          - USDT:", walletBal1);
        console2.log("");

        // Cap withdrawal to available balance
        if (withdrawAmount0 > vaultBal0) withdrawAmount0 = vaultBal0;
        if (withdrawAmount1 > vaultBal1) withdrawAmount1 = vaultBal1;

        console2.log("Withdrawing USDC:", withdrawAmount0);
        console2.log("Withdrawing USDT:", withdrawAmount1);

        vm.startBroadcast(pk);
        vault.withdrawTreasury(deployer, withdrawAmount0, withdrawAmount1);
        vm.stopBroadcast();

        // After
        (uint256 vaultBal0After, uint256 vaultBal1After) = vault.balances();
        uint256 walletBal0After = IERC20(address(vault.token0())).balanceOf(deployer);
        uint256 walletBal1After = IERC20(address(vault.token1())).balanceOf(deployer);

        console2.log("");
        console2.log("After withdrawal:");
        console2.log("  Vault balances  - USDC:", vaultBal0After);
        console2.log("  Vault balances  - USDT:", vaultBal1After);
        console2.log("  Wallet          - USDC:", walletBal0After);
        console2.log("  Wallet          - USDT:", walletBal1After);
        console2.log("  Wallet gained   - USDC:", walletBal0After - walletBal0);
        console2.log("  Wallet gained   - USDT:", walletBal1After - walletBal1);

        console2.log("");
        console2.log("Treasury withdrawal test complete!");
    }
}


/// @title TestPauseScript
/// @notice Tests pause/unpause and verifies paused vault blocks operations
contract TestPauseScript is Script, BaseScript {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));

        console2.log("========================================");
        console2.log("       Test Pause / Unpause             ");
        console2.log("========================================");
        console2.log("");

        vm.startBroadcast(pk);

        // 1. Pause the vault
        console2.log("Pausing vault...");
        vault.pause();
        console2.log("  Paused successfully");

        // 2. Try collectFees while paused — should still work (not pausable-gated)
        // But fund() and autoRebalance() are whenNotPaused
        console2.log("");
        console2.log("Testing fund() while paused...");
        try vault.fund(0, 0) {
            console2.log("  ERROR: fund() should have reverted while paused!");
        } catch {
            console2.log("  Correctly reverted: fund() blocked while paused");
        }

        console2.log("");
        console2.log("Testing forceDeployBuffer() while paused...");
        try vault.forceDeployBuffer() {
            console2.log("  ERROR: forceDeployBuffer() should have reverted!");
        } catch {
            console2.log("  Correctly reverted: forceDeployBuffer() blocked while paused");
        }

        // 3. Unpause
        console2.log("");
        console2.log("Unpausing vault...");
        vault.unpause();
        console2.log("  Unpaused successfully");

        // 4. Verify operations work again
        console2.log("Testing fund(0,0) after unpause...");
        vault.fund(0, 0);
        console2.log("  Success: fund() works after unpause");

        vm.stopBroadcast();

        console2.log("");
        console2.log("Pause/Unpause test complete!");
    }
}


/// @title TestRescueTokenScript
/// @notice Tests rescueToken — emergency recovery of stuck tokens
contract TestRescueTokenScript is Script, BaseScript {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));
        address deployer = vm.addr(pk);
        address token0Addr = address(vault.token0());

        console2.log("========================================");
        console2.log("       Test Rescue Token                ");
        console2.log("========================================");
        console2.log("");

        (uint256 vaultBal0, ) = vault.balances();
        uint256 walletBal0 = IERC20(token0Addr).balanceOf(deployer);

        console2.log("Before rescue:");
        console2.log("  Vault USDC:", vaultBal0);
        console2.log("  Wallet USDC:", walletBal0);

        if (vaultBal0 == 0) {
            console2.log("");
            console2.log("No tokens in vault to rescue. Fund vault first.");
            return;
        }

        // Rescue a small amount (1 token)
        uint256 rescueAmount = 1e6; // 1 USDC
        if (rescueAmount > vaultBal0) rescueAmount = vaultBal0;

        console2.log("");
        console2.log("Rescuing USDC:", rescueAmount);

        vm.startBroadcast(pk);
        vault.rescueToken(token0Addr, deployer, rescueAmount);
        vm.stopBroadcast();

        (uint256 vaultBal0After, ) = vault.balances();
        uint256 walletBal0After = IERC20(token0Addr).balanceOf(deployer);

        console2.log("");
        console2.log("After rescue:");
        console2.log("  Vault USDC:", vaultBal0After);
        console2.log("  Wallet USDC:", walletBal0After);
        console2.log("  Rescued:", walletBal0After - walletBal0);

        console2.log("");
        console2.log("Rescue token test complete!");
    }
}


/// @title TestFullDefenseCycleScript
/// @notice Tests the complete V2 defense cycle:
///   1. Check LP position & treasury
///   2. Collect fees into treasury
///   3. Force deploy buffer (simulate depeg)
///   4. Check buffer state & treasury depletion
///   5. Force remove buffer (simulate recovery)
///   6. Check treasury P&L
///
/// NOTE: This uses forceDeployBuffer/forceRemoveBuffer to simulate the cycle
/// without needing actual swaps to move the tick. For a real test with swaps,
/// use the swap script between steps.
contract TestFullDefenseCycleScript is Script, BaseScript {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));

        console2.log("========================================");
        console2.log("     Full Defense Cycle Test (V2)       ");
        console2.log("========================================");
        console2.log("");

        // ============ PHASE 1: Initial State ============
        console2.log("=== PHASE 1: INITIAL STATE ===");

        (uint256 lpTokenId, , , , uint128 lpLiq, bool lpActive) = vault.lpPosition();
        console2.log("LP tokenId:", lpTokenId);
        console2.log("LP liquidity:", uint256(lpLiq));
        console2.log("LP active:", lpActive);

        if (!lpActive || lpTokenId == 0) {
            console2.log("ERROR: No active LP position. Run 05_MintPositionToVault first.");
            return;
        }

        (uint256 bal0Start, uint256 bal1Start) = vault.balances();
        console2.log("Treasury USDC:", bal0Start);
        console2.log("Treasury USDT:", bal1Start);

        uint128 bufferLiqStart = vault.getBufferLiquidity();
        console2.log("Buffer liquidity:", uint256(bufferLiqStart));
        console2.log("Active regime:", uint256(vault.activeRegime()));

        PoolId poolId = vault.getPoolId();
        if (PoolId.unwrap(poolId) != bytes32(0)) {
            console2.log("Current tick:", int256(vault.getCurrentTick()));
        }
        console2.log("");

        vm.startBroadcast(pk);

        // ============ PHASE 2: Collect Fees ============
        console2.log("=== PHASE 2: COLLECT FEES ===");
        vault.collectFees();

        (uint256 bal0AfterFees, uint256 bal1AfterFees) = vault.balances();
        console2.log("Treasury after collectFees:");
        console2.log("  USDC:", bal0AfterFees);
        console2.log("  USDT:", bal1AfterFees);
        console2.log("  Fees earned USDC:", bal0AfterFees - bal0Start);
        console2.log("  Fees earned USDT:", bal1AfterFees - bal1Start);
        console2.log("  Total fees collected USDC:", vault.totalFeesCollected0());
        console2.log("  Total fees collected USDT:", vault.totalFeesCollected1());
        console2.log("");

        // ============ PHASE 3: Deploy Buffer (Simulate Depeg) ============
        console2.log("=== PHASE 3: DEPLOY BUFFER (DEFEND) ===");

        if (bal1AfterFees == 0) {
            console2.log("WARNING: No USDT in treasury to deploy buffer.");
            console2.log("Need swaps to generate fees, or fund vault with USDT.");
            console2.log("Funding 1000 USDT for testing...");

            // Fund some USDT for testing
            address t1 = address(vault.token1());
            uint256 testFund = 1000e6;
            IERC20(t1).approve(vaultAddr, testFund);
            vault.fund(0, testFund);

            (, bal1AfterFees) = vault.balances();
            console2.log("  Treasury USDT after fund:", bal1AfterFees);
        }

        console2.log("Deploying buffer (forceDeployBuffer)...");
        vault.forceDeployBuffer();

        console2.log("Regime after deploy:", uint256(vault.activeRegime()));

        (, , , , uint128 bufLiqAfterDeploy, bool bufActiveAfterDeploy) = vault.bufferPosition();
        console2.log("Buffer active:", bufActiveAfterDeploy);
        console2.log("Buffer liquidity:", uint256(bufLiqAfterDeploy));

        uint128 bufLiqOnChain = vault.getBufferLiquidity();
        console2.log("Buffer L (on-chain):", uint256(bufLiqOnChain));

        (uint256 bal0AfterDeploy, uint256 bal1AfterDeploy) = vault.balances();
        console2.log("Treasury after deploy:");
        console2.log("  USDC:", bal0AfterDeploy);
        console2.log("  USDT:", bal1AfterDeploy);
        console2.log("  USDT deployed to buffer:", bal1AfterFees - bal1AfterDeploy);
        console2.log("");

        // ============ PHASE 4: Remove Buffer (Simulate Recovery) ============
        console2.log("=== PHASE 4: REMOVE BUFFER (RECOVER) ===");
        console2.log("Removing buffer (forceRemoveBuffer)...");
        vault.forceRemoveBuffer();

        console2.log("Regime after remove:", uint256(vault.activeRegime()));

        (, , , , uint128 bufLiqAfterRemove, bool bufActiveAfterRemove) = vault.bufferPosition();
        console2.log("Buffer active:", bufActiveAfterRemove);
        console2.log("Buffer liquidity:", uint256(bufLiqAfterRemove));

        (uint256 bal0AfterRemove, uint256 bal1AfterRemove) = vault.balances();
        console2.log("Treasury after remove:");
        console2.log("  USDC:", bal0AfterRemove);
        console2.log("  USDT:", bal1AfterRemove);
        console2.log("");

        // ============ PHASE 5: P&L Summary ============
        console2.log("=== PHASE 5: P&L SUMMARY ===");
        console2.log("Starting treasury:");
        console2.log("  USDC:", bal0Start);
        console2.log("  USDT:", bal1Start);
        console2.log("Ending treasury:");
        console2.log("  USDC:", bal0AfterRemove);
        console2.log("  USDT:", bal1AfterRemove);

        // Calculate changes (handle underflow safely)
        if (bal0AfterRemove >= bal0Start) {
            console2.log("  USDC gained:", bal0AfterRemove - bal0Start);
        } else {
            console2.log("  USDC lost:", bal0Start - bal0AfterRemove);
        }
        if (bal1AfterRemove >= bal1Start) {
            console2.log("  USDT gained:", bal1AfterRemove - bal1Start);
        } else {
            console2.log("  USDT lost:", bal1Start - bal1AfterRemove);
        }

        console2.log("");
        console2.log("LP position unchanged:");
        (, , , , uint128 lpLiqEnd, bool lpActiveEnd) = vault.lpPosition();
        console2.log("  LP liquidity:", uint256(lpLiqEnd));
        console2.log("  LP active:", lpActiveEnd);
        console2.log("  LP liquidity same:", lpLiq == lpLiqEnd);

        vm.stopBroadcast();

        console2.log("");
        console2.log("========================================");
        console2.log("   Full Defense Cycle Test Complete!     ");
        console2.log("========================================");
        console2.log("");
        console2.log("NOTE: In this test, no swaps occurred during buffer");
        console2.log("deployment, so treasury should be roughly unchanged.");
        console2.log("For real P&L, run swaps between deploy and remove.");
        console2.log("The buffer would absorb sell pressure (buying USDC");
        console2.log("at discount) and profit on recovery.");
    }
}
