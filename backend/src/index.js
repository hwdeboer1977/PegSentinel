// src/index.js
// PegSentinel Keeper - Simple version
// All rebalance logic is now ON-CHAIN in the vault
// Keeper just monitors and triggers autoRebalance()

import "dotenv/config";
import { ethers } from "ethers";
import { CONFIG } from "./config.js";
import { tickToPrice, deviationBpsFromPeg } from "./math.js";

const VaultABI = [
  // View functions
  "function activeRegime() view returns (uint8)",
  "function needsRebalance() view returns (bool needed, uint8 currentRegime, uint8 targetRegime, int24 currentTick)",
  "function getCurrentTick() view returns (int24)",
  "function mildThreshold() view returns (int24)",
  "function severeThreshold() view returns (int24)",
  "function rebalanceCooldown() view returns (uint256)",
  "function lastRebalanceAt() view returns (uint256)",
  "function normalPosition() view returns (uint256 tokenId, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liquidity, bool active)",
  "function supportPosition() view returns (uint256 tokenId, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liquidity, bool active)",
  "function balances() view returns (uint256 bal0, uint256 bal1)",
  
  // Write functions
  "function autoRebalance()",
  
  // Events
  "event Rebalanced(address indexed caller, uint8 fromRegime, uint8 toRegime, int24 currentTick)",
];

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function regimeName(n) {
  if (n === 0) return "Normal";
  if (n === 1) return "Mild";
  if (n === 2) return "Severe";
  return `Unknown(${n})`;
}

async function main() {
  // Setup
  const provider = new ethers.JsonRpcProvider(CONFIG.rpcUrl, CONFIG.chainId);
  const signer = new ethers.Wallet(CONFIG.privateKey, provider);
  
  const vault = new ethers.Contract(CONFIG.vault, VaultABI, signer);
  const vaultRead = new ethers.Contract(CONFIG.vault, VaultABI, provider);

  console.log("===========================================");
  console.log("  PegSentinel Keeper (On-Chain Rebalance)  ");
  console.log("===========================================");
  console.log("");
  console.log("Vault:", CONFIG.vault);
  console.log("Keeper:", signer.address);
  console.log("Poll interval:", CONFIG.pollSeconds, "seconds");
  console.log("Dry run:", CONFIG.dryRun ? "YES" : "NO");
  console.log("");

  // Main loop
  while (true) {
    try {
      // 1. Check if rebalance is needed (single call!)
      const [needed, currentRegime, targetRegime, currentTick] = await vaultRead.needsRebalance();
      
      // 2. Calculate price info for logging
      const price = tickToPrice(Number(currentTick));
      const devBps = deviationBpsFromPeg(price, CONFIG.targetPrice);
      
      // 3. Log status
      const timestamp = new Date().toISOString();
      console.log(
        `[${timestamp}] tick=${currentTick} price=$${price.toFixed(6)} dev=${(devBps / 100).toFixed(2)}% ` +
        `regime=${regimeName(currentRegime)} target=${regimeName(targetRegime)} ` +
        `needsRebalance=${needed}`
      );

      // 4. Trigger rebalance if needed
      if (needed) {
        console.log("");
        console.log(`⚡ Rebalance needed: ${regimeName(currentRegime)} → ${regimeName(targetRegime)}`);
        
        if (CONFIG.dryRun) {
          console.log("[DRY_RUN] Would call vault.autoRebalance()");
        } else {
          // Check gas price
          const feeData = await provider.getFeeData();
          const gasPriceGwei = Number(feeData.gasPrice) / 1e9;
          
          if (gasPriceGwei > CONFIG.maxFeeGwei) {
            console.log(`⚠️  Gas price ${gasPriceGwei.toFixed(1)} gwei > max ${CONFIG.maxFeeGwei} gwei. Skipping.`);
          } else {
            console.log(`Gas price: ${gasPriceGwei.toFixed(1)} gwei. Executing...`);
            
            try {
              const tx = await vault.autoRebalance();
              console.log(`📤 TX sent: ${tx.hash}`);
              
              const receipt = await tx.wait();
              console.log(`✅ Mined in block ${receipt.blockNumber}`);
              
              // Log the event
              const rebalanceEvent = receipt.logs.find(log => {
                try {
                  const parsed = vault.interface.parseLog(log);
                  return parsed?.name === "Rebalanced";
                } catch { return false; }
              });
              
              if (rebalanceEvent) {
                const parsed = vault.interface.parseLog(rebalanceEvent);
                console.log(`   From: ${regimeName(parsed.args.fromRegime)}`);
                console.log(`   To: ${regimeName(parsed.args.toRegime)}`);
                console.log(`   Tick: ${parsed.args.currentTick}`);
              }
            } catch (txError) {
              // Handle specific errors
              const reason = txError?.reason || txError?.message || "Unknown error";
              
              if (reason.includes("CooldownActive")) {
                console.log(`⏳ Cooldown active. Waiting...`);
              } else if (reason.includes("NoRegimeChange")) {
                console.log(`ℹ️  No regime change needed (race condition)`);
              } else {
                console.error(`❌ TX failed: ${reason}`);
              }
            }
          }
        }
        console.log("");
      }

    } catch (err) {
      console.error("Loop error:", err?.reason || err?.message || err);
    }

    await sleep(CONFIG.pollSeconds * 1000);
  }
}

main().catch((e) => {
  console.error("Fatal error:", e);
  process.exit(1);
});
