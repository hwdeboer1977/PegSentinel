// src/config.js
import "dotenv/config";

export const CONFIG = {
  // Required
  rpcUrl: process.env.ARB_RPC || process.env.RPC_URL,
  privateKey: process.env.PRIVATE_KEY,
  vault: process.env.VAULT_ADDRESS,

  // Chain
  chainId: Number(process.env.CHAIN_ID || 421614), // Arbitrum Sepolia default

  // Polling
  pollSeconds: Number(process.env.POLL_SECONDS || 15),

  // Price reference
  targetPrice: Number(process.env.TARGET_PRICE || 1.0),

  // Gas limit
  maxFeeGwei: Number(process.env.MAX_FEE_GWEI || 50),

  // Dry run mode (set to "1" or "true" to enable)
  dryRun: process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true",
};

// Validate required config
if (!CONFIG.rpcUrl) throw new Error("Missing ARB_RPC or RPC_URL");
if (!CONFIG.privateKey) throw new Error("Missing PRIVATE_KEY");
if (!CONFIG.vault) throw new Error("Missing VAULT_ADDRESS");
