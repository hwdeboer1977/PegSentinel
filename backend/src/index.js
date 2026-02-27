// src/index.js
// PegSentinel Keeper V2 - Treasury Buffer Model
// Keeper monitors tick, triggers autoRebalance() and collectFees()

import "dotenv/config";
import { ethers } from "ethers";
import { CONFIG } from "./config.js";
import { tickToPrice, deviationBpsFromPeg } from "./math.js";

const VaultABI = [
  // View functions
  "function activeRegime() view returns (uint8)",
  "function needsRebalance() view returns (bool needed, uint8 currentRegime, uint8 targetRegime, int24 currentTick)",
  "function getCurrentTick() view returns (int24)",
  "function defendThreshold() view returns (int24)",
  "function recoverThreshold() view returns (int24)",
  "function rebalanceCooldown() view returns (uint256)",
  "function lastRebalanceAt() view returns (uint256)",
  "function lpPosition() view returns (uint256 tokenId, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liquidity, bool active)",
  "function bufferPosition() view returns (uint256 tokenId, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liquidity, bool active)",
  "function balances() view returns (uint256 bal0, uint256 bal1)",
  "function treasuryBalances() view returns (uint256 treasury0, uint256 treasury1)",
  "function getBufferLiquidity() view returns (uint128)",
  "function totalFeesCollected0() view returns (uint256)",
  "function totalFeesCollected1() view returns (uint256)",
  "function lpRange() view returns (int24 tickLower, int24 tickUpper)",
  "function bufferRange() view returns (int24 tickLower, int24 tickUpper)",

  // Write functions
  "function autoRebalance()",
  "function collectFees()",

  // Events
  "event RegimeChanged(uint8 indexed from, uint8 indexed to, int24 currentTick)",
  "event FeesCollected(uint256 amount0, uint256 amount1)",
  "event BufferDeployed(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 usdtDeployed)",
  "event BufferRemoved(uint256 tokenId, uint128 liquidity)",
];

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function regimeName(n) {
  if (Number(n) === 0) return "Normal";
  if (Number(n) === 1) return "Defend";
  return `Unknown(${n})`;
}

function formatUsdc(val) {
  // 6 decimals
  return (Number(val) / 1e6).toFixed(2);
}

async function main() {
  // Setup
  const provider = new ethers.JsonRpcProvider(CONFIG.rpcUrl, CONFIG.chainId);
  const signer = new ethers.Wallet(CONFIG.privateKey, provider);

  const vault = new ethers.Contract(CONFIG.vault, VaultABI, signer);
  const vaultRead = new ethers.Contract(CONFIG.vault, VaultABI, provider);

  console.log("===========================================");
  console.log("  PegSentinel Keeper V2 (Treasury Buffer)  ");
  console.log("===========================================");
  console.log("");
  console.log("Vault:", CONFIG.vault);
  console.log("Keeper:", signer.address);
  console.log("Poll interval:", CONFIG.pollSeconds, "seconds");
  console.log("Fee collection interval:", CONFIG.feeCollectMinutes || 60, "minutes");
  console.log("Dry run:", CONFIG.dryRun ? "YES" : "NO");
  console.log("");

  let lastFeeCollect = 0;
  const feeCollectInterval = (CONFIG.feeCollectMinutes || 60) * 60 * 1000;

  // Main loop
  while (true) {
    try {
      // 1. Check if rebalance is needed
      const [needed, currentRegime, targetRegime, currentTick] =
        await vaultRead.needsRebalance();

      // 2. Calculate price info for logging
      const price = tickToPrice(Number(currentTick));
      const devBps = deviationBpsFromPeg(price, CONFIG.targetPrice);

      // 3. Get treasury state
      const [bal0, bal1] = await vaultRead.balances();

      // 4. Log status
      const timestamp = new Date().toISOString();
      console.log(
        `[${timestamp}] tick=${currentTick} price=$${price.toFixed(6)} dev=${(devBps / 100).toFixed(2)}% ` +
          `regime=${regimeName(currentRegime)} target=${regimeName(targetRegime)} ` +
          `treasury=[${formatUsdc(bal0)} USDC, ${formatUsdc(bal1)} USDT] ` +
          `needsRebalance=${needed}`
      );

      // 5. Periodic fee collection
      const now = Date.now();
      if (now - lastFeeCollect > feeCollectInterval) {
        console.log("📥 Collecting fees from LP position...");

        if (CONFIG.dryRun) {
          console.log("[DRY_RUN] Would call vault.collectFees()");
        } else {
          try {
            const tx = await vault.collectFees();
            console.log(`📤 collectFees TX: ${tx.hash}`);
            const receipt = await tx.wait();
            console.log(`✅ Fees collected in block ${receipt.blockNumber}`);

            // Parse FeesCollected event
            for (const log of receipt.logs) {
              try {
                const parsed = vault.interface.parseLog(log);
                if (parsed?.name === "FeesCollected") {
                  console.log(
                    `   USDC: ${formatUsdc(parsed.args.amount0)}, USDT: ${formatUsdc(parsed.args.amount1)}`
                  );
                }
              } catch {}
            }
          } catch (err) {
            console.error("❌ collectFees failed:", err?.reason || err?.message);
          }
        }
        lastFeeCollect = now;
        console.log("");
      }

      // 6. Trigger rebalance if needed
      if (needed) {
        console.log("");
        console.log(
          `⚡ Rebalance needed: ${regimeName(currentRegime)} → ${regimeName(targetRegime)}`
        );

        if (targetRegime === 1) {
          console.log(
            `   Action: DEPLOY buffer (treasury USDT → LP at buffer range)`
          );
          console.log(`   Treasury USDT available: ${formatUsdc(bal1)}`);
          if (Number(bal1) === 0) {
            console.log(
              "   ⚠️  No USDT in treasury! Buffer deploy will fail."
            );
          }
        } else {
          console.log(
            `   Action: REMOVE buffer (LP at buffer range → treasury)`
          );
        }

        if (CONFIG.dryRun) {
          console.log("[DRY_RUN] Would call vault.autoRebalance()");
        } else {
          // Check gas price
          const feeData = await provider.getFeeData();
          const gasPriceGwei = Number(feeData.gasPrice) / 1e9;

          if (gasPriceGwei > CONFIG.maxFeeGwei) {
            console.log(
              `⚠️  Gas price ${gasPriceGwei.toFixed(1)} gwei > max ${CONFIG.maxFeeGwei} gwei. Skipping.`
            );
          } else {
            console.log(
              `Gas price: ${gasPriceGwei.toFixed(1)} gwei. Executing...`
            );

            try {
              const tx = await vault.autoRebalance();
              console.log(`📤 TX sent: ${tx.hash}`);

              const receipt = await tx.wait();
              console.log(`✅ Mined in block ${receipt.blockNumber}`);

              // Log events
              for (const log of receipt.logs) {
                try {
                  const parsed = vault.interface.parseLog(log);
                  if (parsed?.name === "RegimeChanged") {
                    console.log(
                      `   Regime: ${regimeName(parsed.args.from)} → ${regimeName(parsed.args.to)}`
                    );
                    console.log(`   Tick: ${parsed.args.currentTick}`);
                  }
                  if (parsed?.name === "BufferDeployed") {
                    console.log(
                      `   Buffer deployed: [${parsed.args.tickLower}, ${parsed.args.tickUpper}]`
                    );
                    console.log(
                      `   USDT deployed: ${formatUsdc(parsed.args.usdtDeployed)}`
                    );
                    console.log(`   Liquidity: ${parsed.args.liquidity}`);
                  }
                  if (parsed?.name === "BufferRemoved") {
                    console.log(`   Buffer removed: tokenId ${parsed.args.tokenId}`);
                    console.log(`   Liquidity removed: ${parsed.args.liquidity}`);
                  }
                } catch {}
              }
            } catch (txError) {
              const reason =
                txError?.reason || txError?.message || "Unknown error";

              if (reason.includes("CooldownActive")) {
                console.log(`⏳ Cooldown active. Waiting...`);
              } else if (reason.includes("NoRegimeChange")) {
                console.log(`ℹ️  No regime change needed (race condition)`);
              } else if (reason.includes("InsufficientTreasuryUSDT")) {
                console.log(`⚠️  No USDT in treasury for buffer deployment`);
              } else if (reason.includes("BufferAlreadyActive")) {
                console.log(`ℹ️  Buffer already deployed`);
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
