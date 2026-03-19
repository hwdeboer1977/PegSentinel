# PegSentinel

> Peg-aware stablecoin defense on Uniswap v4 through directional fees, a protocol treasury, and active buffer liquidity.

PegSentinel is a hackathon prototype for stablecoin peg defense. It combines a **Uniswap v4 hook**, a **treasury-backed vault**, a **keeper service**, and a **frontend dashboard** into one system.

The design goal is simple: when a stablecoin starts drifting away from $1, the protocol should not remain passive. PegSentinel raises friction for harmful swaps, lowers friction for restorative swaps, and uses accumulated fees to deploy defensive liquidity when stress appears.

---

## Core Idea

PegSentinel has two coordinated defense layers:

1. **Directional dynamic fees**  
   The hook evaluates swap direction relative to the peg. Trades that push price farther away from $1 pay more. Trades that help restore the peg pay less.

2. **Treasury-funded buffer liquidity**  
   The vault collects fees and holds them as treasury reserves. During a depeg, it can deploy those reserves as a single-sided defensive buffer below the main LP range.

This creates a feedback loop:

```
more stress → more fees → larger treasury → stronger future defense
```

---

## How the System Works

### Layer 1 — Hook

The hook runs on every swap and computes a fee based on peg deviation and direction.

- harmful direction: fee can rise toward **10%**
- near-peg trading: base fee around **0.30%**
- restorative direction: fee can drop toward **0.05%**

The goal is to make depegging more expensive and arbitrage back to peg more attractive.

### Layer 2 — Vault

The vault holds the protocol-owned liquidity strategy.

- the main LP position remains centered near peg
- fees are collected into treasury balances
- if the pool enters a defend regime, treasury funds deploy into a lower buffer range
- when the peg recovers, the buffer is removed again

This means PegSentinel does not rely only on passive LP fees. It turns fees into active defense capital.

---

## Regime Logic

PegSentinel uses a two-regime model with hysteresis.

| Regime | Meaning |
|---|---|
| `Normal` | Main LP active, treasury accumulates |
| `Defend` | Main LP active plus lower defensive buffer |

The vault checks the current pool tick against configured thresholds.

- below the defend threshold → deploy buffer
- above the recover threshold → remove buffer
- between both thresholds → do nothing

That hysteresis band prevents noisy back-and-forth switching.

---

## Why This Is Different From a Classic LP

| Topic | Classic LP | PegSentinel |
|---|---|---|
| Fee policy | Static | Dynamic and directional |
| Behavior during depeg | Passive | Penalizes harmful flow |
| Fee usage | Sits idle or compounds | Accumulates as defense treasury |
| Below-range support | None | Single-sided buy wall |
| Recovery profile | Passive | Designed for asymmetric snap-back |

In short, a normal LP provides liquidity. PegSentinel tries to **defend a peg**.

---

## Repository Structure

```text
PegSentinel/
├── README.md
├── v4_hook/      # Solidity contracts, scripts, and Foundry config
├── backend/      # Node.js keeper for fee collection and autoRebalance()
└── frontend/     # Next.js dashboard for monitoring and manual actions
```

Subproject documentation:

- [Smart contracts / hook README](./v4_hook/README.md)
- [Backend keeper README](./backend/README.md)
- [Frontend dashboard README](./frontend/README.md)

---

## Architecture Overview

```text
Trader
  │
  ▼
Uniswap v4 Pool
  │
  ├─ PegSentinelHook
  │    - inspects each swap
  │    - applies peg-aware dynamic fees
  │    - fee revenue flows → Vault treasury
  │
  └─ PegSentinelVault
       - owns protocol LP positions
       - collects fees into treasury
       - deploys/removes defensive buffer liquidity

Keeper (backend)
  - polls needsRebalance()
  - calls collectFees()
  - calls autoRebalance()

Frontend (dashboard)
  - shows live price, tick, regime, balances, fee previews
  - supports wallet connection
  - can manually trigger vault actions
```

---

## Tech Stack

| Layer | Stack |
|---|---|
| Contracts | Solidity 0.8.30, Foundry, Uniswap v4, OpenZeppelin |
| Backend | Node.js, ethers v6, dotenv |
| Frontend | Next.js, React, TypeScript, Tailwind v4, ethers v6 |
| Target network | Arbitrum Sepolia |

---

## Quick Start

### 1. Deploy the contracts

Go to the contracts package and follow the deployment sequence:

- [v4_hook/README.md](./v4_hook/README.md)

### 2. Start the keeper

Run the backend service that monitors the vault and triggers on-chain actions:

- [backend/README.md](./backend/README.md)

### 3. Run the dashboard

Launch the frontend to inspect pool status, fees, vault reserves, and rebalance state:

- [frontend/README.md](./frontend/README.md)

---

## Hackathon Scope

This repository demonstrates:

- a custom Uniswap v4 hook for peg-aware swap execution
- a treasury-based vault with defensive liquidity deployment
- automated keeper logic for regime changes
- a frontend interface to monitor and interact with the system

It is intended as a working prototype and design exploration for active stablecoin peg defense.

---

## Safety Notice

This is an experimental hackathon project. It has **not** been audited and is **not production-ready**. Do not use it with real funds.

---

## License

MIT
