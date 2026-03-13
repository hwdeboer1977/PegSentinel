# PegSentinel — Dashboard

> **Next.js monitoring dashboard for the PegSentinel stablecoin peg defense system**

The dashboard provides real-time visibility into vault state, live fee previews, and a manual rebalance trigger for protocol operators. It reads directly from the chain — no backend API required.

---

## Features

### Swap Page (`/swap`)
- Live price and deviation from the $1.00 peg
- Fee preview for both swap directions before executing
- Direction indicator: **TOWARD PEG** (low fee) vs **AWAY FROM PEG** (high fee)
- Execute swaps directly via connected wallet
- Links to Arbiscan for transaction confirmation

### Liquidity Page (`/liquidity`)
- Vault reserves — idle USDC/USDT treasury balance
- LP position details: tick range, liquidity, token amounts, in-range status
- Buffer position card — appears only when `Defend` regime is active
- Visual tick range representation showing current price vs position bounds
- Rebalance control panel with current vs target regime comparison
- Advanced configuration panel: LP range, buffer range, defend/recover thresholds
- Connect wallet to trigger `autoRebalance()` on-chain

---

## Tech Stack

| | |
|---|---|
| **Framework** | Next.js 16 (App Router) |
| **Language** | TypeScript 5 |
| **Styling** | Tailwind CSS v4 |
| **Ethereum** | ethers.js v6 |
| **Network** | Arbitrum Sepolia (chain ID 421614) |

---

## Setup

### 1. Install Dependencies

```bash
cd frontend
npm install
```

### 2. Configure Environment

```bash
cp .env.example .env.local
```

Edit `.env.local` with your deployed contract addresses:

```bash
# RPC
NEXT_PUBLIC_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc

# Your deployed contracts (from v4_hook deployment)
NEXT_PUBLIC_VAULT_ADDRESS=0x...
NEXT_PUBLIC_HOOK_ADDRESS=0x...

# Uniswap V4 infrastructure — Arbitrum Sepolia
NEXT_PUBLIC_POOL_MANAGER_ADDRESS=0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317
NEXT_PUBLIC_POSITION_MANAGER_ADDRESS=0xAc631556d3d4019C95769033B5E719dD77124BAc
NEXT_PUBLIC_STATE_VIEW_ADDRESS=0x...
NEXT_PUBLIC_SWAP_ROUTER_ADDRESS=0x...

# Pool
NEXT_PUBLIC_POOL_ID=0x...

# Tokens
NEXT_PUBLIC_TOKEN0_ADDRESS=0x...
NEXT_PUBLIC_TOKEN1_ADDRESS=0x...
```

Contract addresses for `VAULT_ADDRESS` and `HOOK_ADDRESS` come from running the `v4_hook` deployment scripts. See [`../v4_hook/README.md`](../v4_hook/README.md).

---

## Running

### Development (against Anvil local node)

Use the provided helper script, which loads addresses from `v4_hook/.env.anvil` automatically:

```bash
# Make executable (once)
chmod +x dev-anvil.sh

# Start dev server pointed at local Anvil
./dev-anvil.sh
```

This sources `../v4_hook/.env.anvil` and injects the addresses as `NEXT_PUBLIC_*` env vars before starting `npm run dev`.

### Development (against Arbitrum Sepolia)

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000)

### Production Build

```bash
npm run build
npm start
```

---

## Pages

### `/` — Overview

Entry point with system status and navigation.

### `/swap` — Swap Interface

Connect wallet and execute swaps directly against the PegSentinel pool. The fee preview panel updates in real time based on the current tick, showing the exact fee each direction would pay before confirming.

### `/liquidity` — Vault Monitor

Full vault state view. Operators can connect their wallet and call `autoRebalance()` directly from the UI. The rebalance button is only enabled when `vault.needsRebalance()` returns true.

> **Note:** The UI triggers `autoRebalance()` for regime changes. Full liquidity repositioning (minting new NFTs, etc.) still requires the keeper script or Forge scripts.

---

## Architecture

```
Frontend (Next.js)
    │
    ├── Reads from chain (read-only, no wallet needed):
    │   ├── Pool price + tick         ← PoolManager / StateView
    │   ├── Vault state               ← PegSentinelVault
    │   │   ├── activeRegime
    │   │   ├── lpPosition / bufferPosition
    │   │   ├── balances() / treasuryBalances()
    │   │   └── needsRebalance()
    │   └── Fee preview               ← PegSentinelHook.previewFee()
    │
    └── Writes to chain (wallet required):
        ├── Swap execution            ← SwapRouter
        └── Rebalance trigger         ← PegSentinelVault.autoRebalance()
```

---

## File Structure

```
frontend/
├── app/
│   ├── layout.tsx               # Root layout + nav shell
│   ├── page.tsx                 # Overview / home
│   ├── swap/
│   │   └── page.tsx             # Swap interface + fee preview
│   ├── liquidity/
│   │   └── page.tsx             # Vault monitor + rebalance control
│   └── lib/
│       ├── shared.tsx           # usePegSentinel hook + shared UI components
│       ├── Shell.tsx            # Page shell with loading/error states
│       ├── addresses.ts         # Contract address config from env vars
│       ├── provider.ts          # ethers.js provider setup
│       ├── providers.tsx        # React context providers
│       └── format.ts            # Number formatting helpers
├── dev-anvil.sh                 # Dev helper: load Anvil addresses + start next dev
├── next.config.ts
├── package.json
└── .env.example
```

---

## Related

- [`../v4_hook/`](../v4_hook/README.md) — Smart contracts and deployment pipeline
- [`../backend/`](../backend/README.md) — Keeper service for automated rebalancing
- [`../README.md`](../README.md) — System overview and architecture
