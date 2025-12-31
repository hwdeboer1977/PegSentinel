# PegSentinel Dashboard

A Next.js frontend for monitoring and controlling the PegSentinel stablecoin peg defense system on Uniswap V4.

![PegSentinel Dashboard](./screenshots/dashboard.png)

## Features

### Peg Status
- Real-time price tracking relative to $1.00 peg
- Current tick and deviation percentage
- Active regime indicator (Normal/Mild/Severe)

### Layer 1: Dynamic Fees
- Live swap fee preview for both directions
- Direction indicator (TOWARD PEG / AWAY FROM PEG)
- Lower fees encourage swaps toward peg, higher fees discourage swaps away

### Layer 2: Liquidity Management
- Visual tick range representation
- Active position details (Token ID, tick range)
- In-range status indicator

### Vault Reserves
- Protocol-owned USDC/USDT balances
- Ready to defend the peg

### Current LP Overview
- Position liquidity
- Token amounts (USDC/USDT)
- Price range in USD

### Rebalance Control
- Current vs target regime comparison
- Configured ranges from vault (Normal, Mild, Severe)
- Connect wallet to trigger rebalance

---

## Getting Started

```bash
# Install dependencies
npm install

# Set environment variables
cp .env.example .env.local

# Run development server
npm run dev
```

Open [http://localhost:3000](http://localhost:3000)

---

## Environment Variables

```bash
NEXT_PUBLIC_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc
NEXT_PUBLIC_VAULT_ADDRESS=0x...
NEXT_PUBLIC_HOOK_ADDRESS=0x...
NEXT_PUBLIC_POOL_MANAGER=0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317
NEXT_PUBLIC_POSITION_MANAGER=0xAc631556d3d4019C95769033B5E719dD77124BAc
```

---

## Tech Stack

- **Next.js 14** - React framework
- **TypeScript** - Type safety
- **Tailwind CSS** - Styling
- **viem** - Ethereum interactions
- **wagmi** - Wallet connection

---

## Architecture

```
Frontend (this repo)
    │
    ├── Reads from chain:
    │   ├── Pool price/tick (PoolManager)
    │   ├── Position data (PositionManager)
    │   ├── Vault state (PegSentinelVault)
    │   └── Fee preview (PegSentinelHook)
    │
    └── Writes to chain:
        └── Rebalance trigger (PegSentinelVault)
```

---

## Related

- [v4_hook/](../v4_hook/) - Smart contracts and deployment scripts
- [PegSentinel README](../v4_hook/README.md) - System architecture

---

## Status

⚠️ **Hackathon Demo** - Not production ready
