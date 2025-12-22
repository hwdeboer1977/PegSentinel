# PegSentinel

**Peg-aware execution + regime-based liquidity management for stablecoin pools on Uniswap v4**

PegSentinel is a Uniswap v4 research prototype that explores **on-chain peg defense** using two tightly integrated layers:

1. **Peg-aware swap execution (hook layer)**  
2. **Regime-based liquidity management (vault layer)**

The system is designed for **stablecoin pairs** (e.g. USDC/USDT) and focuses on how liquidity *should move* when a peg weakens.

---

## High-Level Idea

Stablecoin depegs are not binary events — they evolve through **stress regimes**.

PegSentinel models this explicitly:

- Under normal conditions, liquidity sits symmetrically around the peg
- As the peg weakens, liquidity shifts into **support ranges**
- Capital is deployed where arbitrage helps restore the peg most efficiently

Uniswap v4 hooks make this possible **without breaking pool composability**.

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
  │     - (future) enforces stress modes
  │
  └─▶ PegSentinelVault
        - owns LP NFT positions
        - stores regime ranges on-chain
        - rebalances liquidity between regimes
```

---

## Core Components

### 1. PegSentinelHook (execution layer)

**Status:** early / evolving

Responsibilities:
- Observe pool price relative to peg
- Apply **directional dynamic fees**
  - swaps *away* from peg → higher fee
  - swaps *toward* peg → lower fee
- (Planned) expose peg stress signals to off-chain or vault logic

This layer affects **all swaps**, even for LPs that do not use the vault.

---

### 2. PegSentinelVault (liquidity layer)

**Status:** functional POC++ (on-chain state, off-chain control)

The vault is:
- Protocol-owned
- Non-ERC4626
- No user deposits
- No share accounting

It acts as an **active LP manager** for one Uniswap v4 pool.

---

## Regime Model (On-chain)

PegSentinel explicitly models three regimes.

These are stored **on-chain in the vault** as tick ranges.

| Regime  | Purpose              | Tick Range (example) |
|--------|----------------------|----------------------|
| Normal | Stable peg            | `[-240, +240]`       |
| Mild   | Soft depeg support    | `[-540, 0]`          |
| Severe | Deep depeg defense    | `[-1620, -300]`      |

Configured during vault deployment via `setRange()`.

```solidity
vault.setRange(Regime.Normal, -240, 240, true);
vault.setRange(Regime.Mild, -540, 0, true);
vault.setRange(Regime.Severe, -1620, -300, true);
```

---

## LP Position Model

The vault tracks **LP NFTs explicitly**.

### Stored on-chain:

```solidity
struct PositionMeta {
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    bytes32 salt;
    bool active;
}
```

### Positions

- **normalPosition**
  - Active when `activeRegime == Normal`
- **supportPosition**
  - Shared by `Mild` and `Severe`
  - Only one support position exists at a time

This keeps the state minimal while still supporting regime transitions.

---

## Lifecycle

### 1. Deploy Vault
- Token addresses set
- Regime ranges initialized
- Active regime set to `Normal`

### 2. Fund Vault
- Protocol treasury sends token0 / token1
- Vault holds idle capital

### 3. Mint Initial Position
- `MintPositionToVault.s.sol`
- Uses `vault.normalRange()`
- Mints the **Normal LP position**
- Registers it via `setNormalPosition()`

---

### 4. Rebalancing (`06_AdjustLiquidity.s.sol`)

This script performs **full regime-aware rebalancing**.

#### What it does:

1. Reads current pool price (`currentTick`)
2. Determines:
   - `currentRegime`
   - `targetRegime` (auto or via `TARGET_REGIME`)
3. Withdraws liquidity from the **currently active position**
4. Either:
   - increases liquidity in an existing target position, or
   - mints a new LP NFT
5. Updates vault metadata
6. Sets `activeRegime`

#### Manual override

You can force transitions:

```bash
TARGET_REGIME=1 forge script script/06_AdjustLiquidity.s.sol ...
TARGET_REGIME=2 forge script script/06_AdjustLiquidity.s.sol ...
```

This is intentional — **strategy lives off-chain**, execution is on-chain.

---

## Example Rebalance Log

```
currentTick: 0
currentRegime: Normal
targetRegime : Normal

Decreasing liquidity from tokenId 185
Increasing liquidity in tokenId 185

activeRegime now: Normal
```

Or, when forced:

```
TARGET_REGIME=1

currentRegime: Normal
targetRegime : Mild

Liquidity moved from normalPosition → supportPosition
activeRegime now: Mild
```

---

## Design Philosophy

- **On-chain state, off-chain strategy**
- Vault is dumb, scripts are smart
- No hidden automation
- Fully inspectable transitions
- Reproducible with Forge scripts

This mirrors how **real protocol treasury operations** are executed today.

---

## What Exists Today

✅ On-chain regime ranges  
✅ Vault-owned LP NFTs  
✅ Manual + automatic regime switching  
✅ Increase vs mint logic  
✅ Deterministic liquidity movement  
✅ Full Foundry script pipeline

---

## What’s Next (Planned)

- Hook-driven automatic regime signals
- Keeper automation
- Time-based hysteresis
- Multi-pool support
- Risk caps per regime
- Simulation & stress testing

---

## Status

⚠️ **Research / Prototype**

- Not audited
- Not production-ready
- Intended for experimentation and design exploration

---

## One-liner

> **PegSentinel is a Uniswap v4 research system that models stablecoin depegs as explicit regimes and repositions protocol-owned liquidity accordingly to support peg recovery.**
