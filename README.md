# PegSentinel

**Peg-aware execution + treasury buffer defense for stablecoin pools on Uniswap V4**

PegSentinel is a Uniswap V4 research prototype that explores **on-chain peg defense** using two tightly integrated layers:

1. **Peg-aware swap execution (hook layer)** — dynamic directional fees
2. **Treasury buffer defense (vault layer)** — accumulated fees deploy as buy wall during depeg

The system is designed for **stablecoin pairs** (e.g. USDC/USDT) and focuses on how protocol-owned capital should be *strategically deployed* when a peg weakens.

---

## High-Level Idea

Stablecoin depegs are not binary events — they evolve through stress phases. PegSentinel defends the peg using two layers:

**Layer 1 — Dynamic Fees (always active):**
Swaps away from peg pay higher fees (up to 10%). Swaps toward peg pay lower fees (down to 0.05%). This creates friction against depegging and incentivizes arbitrage.

**Layer 2 — Treasury Buffer (deployed during stress):**
The vault's LP position earns fees that accumulate in a treasury. When the peg weakens past a threshold, the treasury USDT deploys as a single-sided buy wall below the LP range. This absorbs sell pressure that would otherwise crash through undefended price space.

The key insight: **don't move LP — use accumulated fees as strategic capital.**

---

## Architecture

```
Trader
  │
  ▼
Uniswap V4 Pool
  │
  ├─▶ PegSentinelHook (execution layer)
  │     - observes price vs peg
  │     - applies directional dynamic fees
  │     - fees flow to LP → vault collects into treasury
  │
  └─▶ PegSentinelVault (defense layer)
        - owns LP NFT at peg [-60, +60] — never moves
        - collects fees into treasury
        - deploys treasury USDT as buffer [-240, -60] during depeg
        - removes buffer on recovery — profits from buying USDC at discount
```

---

## Core Components

### 1. PegSentinelHook (execution layer)

Responsibilities:
- Observe pool price relative to $1.00 peg
- Apply **directional dynamic fees** via `beforeSwap`
  - Swaps *away* from peg → higher fee (up to 10%)
  - Swaps *toward* peg → lower fee (down to 0.05%)
  - Asymmetric slopes: 8x stronger penalty for harmful trades

This layer affects **all swaps** in the pool, creating continuous fee-based peg defense.

---

### 2. PegSentinelVault V2 (defense layer)

The vault is protocol-owned, non-ERC4626, with no user deposits or share accounting.

**Two positions:**
- **LP Position** — two-sided at `[-60, +60]`, earns fees, **never moves**
- **Buffer Position** — single-sided USDT at `[-240, -60]`, deployed only during depeg

**Treasury:**
- Fees collected from LP position accumulate as USDC + USDT
- Treasury USDT funds the buffer during defense
- Treasury profits when buffer buys USDC at discount during depeg

---

## Defense Playbook

```
Phase 1 — EARN (Normal)
  LP at [-60, +60] earns fees from every swap
  Keeper calls collectFees() → treasury grows

Phase 2 — DEFEND (tick drops below -50)
  autoRebalance() deploys treasury USDT as buffer at [-240, -60]
  Dynamic fees spike on away-from-peg swaps
  Two-layer defense: fee friction + buffer buy wall

Phase 3 — ABSORB
  Buffer absorbs sell pressure that would crash through empty price space
  Buffer is buying USDC at discount (~$0.98)

Phase 4 — RECOVER (tick rises above -30)
  autoRebalance() removes buffer
  Price snaps back through empty zone to LP range
  Dynamic fees drop to encourage buying

Phase 5 — PROFIT
  Treasury holds USDC bought at discount → profit on peg restore
  Enhanced dynamic fees earned during stress → additional revenue
```

### Key Asymmetry

Hard to push down (thick buffer + high fees) → Easy to recover (thin zone + low fees)

### Flywheel

```
Volatility → higher dynamic fees → bigger treasury → stronger buffer next time
```

---

## Regime Model

PegSentinel V2 uses two regimes with hysteresis to prevent oscillation:

| Regime  | Condition              | Action                              |
|---------|------------------------|-------------------------------------|
| Normal  | `tick >= -30`          | LP only, treasury accumulates       |
| Defend  | `tick <= -50`          | LP + buffer deployed from treasury  |

The gap between -50 and -30 is the hysteresis zone — no regime change occurs here, preventing rapid deploy/remove cycles.

---

## LP Position Model

The vault tracks two LP NFTs:

```solidity
struct PositionMeta {
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    bytes32 salt;
    uint128 liquidity;
    bool active;
}
```

- **lpPosition** — always active, always at `[-60, +60]`
- **bufferPosition** — active only during Defend regime, at `[-240, -60]`

---

## Lifecycle

### 1. Deploy Vault
- Token addresses set
- LP range `[-60, +60]` and buffer range `[-240, -60]` configured
- Defend/recover thresholds set with hysteresis

### 2. Fund & Mint LP
- Protocol treasury sends USDC + USDT to vault
- LP NFT minted at `[-60, +60]`, owned by vault
- Registered via `setLPPosition()`

### 3. Earn Fees
- LP earns fees from every swap in the pool
- Keeper calls `collectFees()` periodically
- Fees accumulate in vault as treasury

### 4. Defend Peg
- Tick drops below defend threshold
- Keeper calls `autoRebalance()`
- Treasury USDT deploys as buffer at `[-240, -60]`
- Buffer acts as buy wall absorbing sell pressure

### 5. Recover
- Tick rises above recover threshold
- Keeper calls `autoRebalance()`
- Buffer removed, tokens return to treasury
- Treasury profits from USDC bought at discount

---

## Comparison: Classic LP vs PegSentinel

| Metric                     | Classic LP        | PegSentinel                    |
|---------------------------|-------------------|--------------------------------|
| LP at peg                 | Same $10M         | Same $10M                      |
| Fees earned               | To LP (compound)  | To treasury (strategic deploy) |
| Below LP range            | Zero defense      | Buffer buy wall                |
| Dynamic fees              | None              | Up to 10% away-from-peg       |
| Recovery                  | Passive           | Asymmetric (easy snap-back)    |
| Treasury P&L              | None              | Profits from buying dip        |

---

## What Exists Today

✅ Dynamic peg-aware fees (hook)  
✅ Vault-owned LP at peg (never moves)  
✅ Fee collection into treasury  
✅ Buffer deploy/remove with hysteresis  
✅ Force override for emergencies  
✅ Pause/unpause and rescue functions  
✅ Full Foundry script pipeline  
✅ Anvil and testnet tested  

---

## What's Next (Planned)

- TWAP oracle for manipulation resistance
- Keeper automation (Chainlink/Gelato)
- Hook-driven automatic regime signals
- Multi-pool support
- Risk caps per regime
- Simulation and stress testing
- Cross-chain deployment

---

## Status

⚠️ **Research / Prototype**

- Not audited
- Not production-ready
- Intended for experimentation and design exploration

---

## One-liner

> **PegSentinel defends stablecoin pegs using dynamic fees and treasury-funded buffer walls that profit from buying the dip.**
