# PegSentinel

**Peg-aware execution and adaptive liquidity for stablecoin markets on Uniswap v4**

PegSentinel is a Uniswap v4–native stabilization system that combines **directional dynamic fees** with an **active liquidity vault** to defend stablecoin pegs during market stress — without breaking permissionless liquidity or pool composability.

---

## Overview

Stablecoin pools are vulnerable to:
- asymmetric toxic orderflow,
- MEV-driven peg attacks,
- liquidity fragmentation during stress events.

PegSentinel introduces a **two-layer architecture**:

1. **PegSentinelHook** — enforces peg-aware swap execution at the hook level  
2. **PegSentinelVault** — actively repositions liquidity to where it is most effective

The hook defines *policy*.  
The vault executes *capital deployment*.  

This separation is a deliberate design choice for auditability, safety, and composability.

---

## Architecture

```
Trader
  │
  ▼
Uniswap v4 Pool
  │
  ├─▶ PegSentinelHook
  │     - observes price vs peg
  │     - applies directional fees
  │     - enforces stress regimes
  │
  └─▶ PegSentinelVault (optional LP)
        - repositions liquidity
        - biases liquidity toward peg recovery zones
        - earns pool fees + incentives
```

---

## Core Components

### 1. PegSentinelHook (Hook Layer)

**Responsibility:** Peg-aware execution policy

Implemented using Uniswap v4 hooks (primarily `beforeSwap`).

#### Features
- **Directional dynamic fees**
  - Swaps *away from the peg* → higher fees
  - Swaps *toward the peg* → lower fees
- **Stress regimes**
  - normal
  - soft stress
  - hard stress
- **Extreme protection (optional)**
  - max trade size
  - throttling
  - circuit breaker logic

#### Effects
- Orderflow is economically steered toward peg recovery
- Toxic flow and MEV become more expensive
- Works for **all LPs**, permissionlessly
- No vault or opt-in required

> This is the baseline peg defense layer.

---

### 2. PegSentinelVault (Liquidity Layer)

**Responsibility:** Active peg support via adaptive liquidity placement

The PegSentinelVault is a **non-exclusive LP** that deploys capital into the pool.

#### During peg stress
- Liquidity is repositioned toward the **support zone**
- Liquidity placement becomes **asymmetric**
  - biased above or below the peg, depending on deviation
- Capital is concentrated where arbitrage restores the peg most efficiently

#### Effects
- Depth appears where it is economically needed
- Arbitrage becomes cheaper in the *correct direction*
- Peg recovers with lower capital loss

> This is the active stabilization layer.

---

## Design Principles

- **Hook sets policy, vault executes**
- **Permissionless by default**
- **Non-invasive under normal conditions**
- **Composable with external vaults and LP strategies**
- **Not possible in Uniswap v2 or v3**

---

## Why Uniswap v4

PegSentinel relies on v4-specific primitives:

- Hook-level fee control
- Hook-level state (stress modes)
- Native composability with vault-based LP strategies

This design is **not implementable** in earlier Uniswap versions.

---

## Intended Use Cases

- Stablecoin pairs (USDC/DAI, USDT/USDC, algorithmic stables)
- L2-native stable liquidity
- Institutional-grade liquidity with policy constraints
- Research into on-chain monetary policy primitives

---

## Status

⚠️ **Early-stage / Research prototype**

- Hook logic under active development
- Vault strategy subject to iteration
- Not audited
- Not production-ready

---

## Disclaimer

This repository is experimental research software.
Do not use in production or with real funds.

---

## One-liner

> **PegSentinel combines directional dynamic fees that steer orderflow back toward the peg with an active liquidity vault that repositions capital during stress events to provide targeted peg support.**
