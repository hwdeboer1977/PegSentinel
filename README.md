# PegSentinel

> **Peg-aware swap execution and treasury buffer defense for stablecoin pools on Uniswap V4**

---

## What Is PegSentinel?

PegSentinel is a Uniswap V4 research prototype that defends stablecoin pegs using two coordinated on-chain layers:

1. **Peg-aware swap execution (hook)** — directional dynamic fees applied to every swap, penalizing depeg pressure and rewarding arbitrage
2. **Treasury buffer defense (vault)** — accumulated fees deploy as a single-sided buy wall below the LP range during stress events

The system is purpose-built for **stablecoin pairs** (e.g. USDC/USDT).

The core insight: **don't move the LP position — use accumulated fees as strategic defensive capital.**

---

## How It Works

Stablecoin depegs are not binary events — they unfold progressively. PegSentinel models this explicitly with two always-active defense layers:

**Layer 1 — Dynamic Fees (PegSentinelHook)**

Every swap is assessed relative to the $1.00 peg. The fee adjusts in real time:

| Swap Direction | Fee |
|---|---|
| Away from peg | Up to **10%** |
| At peg (±0.25%) | **0.3%** (base fee) |
| Toward peg | As low as **0.05%** |

The penalty slope is 8× steeper in the harmful direction. This creates continuous friction against depegging and incentivizes arbitrage at all times.

**Layer 2 — Treasury Buffer (PegSentinelVault V2)**

The vault's LP position earns fees that accumulate in a protocol treasury. When the peg weakens past a configured tick threshold, treasury USDT deploys as a **single-sided buy wall** below the LP range. This absorbs sell pressure that would otherwise crash through undefended price space — and profits when the peg restores.

---

## Defense Playbook

```
Phase 1 — EARN (Normal regime)
  LP at [-60, +60] earns fees from every swap
  Keeper calls collectFees() periodically → treasury grows

Phase 2 — DEFEND (tick drops below -50)
  autoRebalance() deploys treasury USDT as buffer at [-240, -60]
  Dynamic fees spike on away-from-peg swaps
  Two-layer defense: fee friction + buffer buy wall

Phase 3 — ABSORB
  Buffer absorbs sell pressure below the LP range
  Buffer is buying USDC at ~$0.98 discount

Phase 4 — RECOVER (tick rises above -30)
  autoRebalance() removes buffer
  Price snaps back through now-empty zone to LP range
  Dynamic fees drop to encourage buying

Phase 5 — PROFIT
  Treasury holds USDC bought at discount → profit on peg restore
  Enhanced dynamic fees earned during stress → additional revenue
```

**Key asymmetry:** hard to push down (thick buffer + high fees) → easy to recover (thin zone + low fees)

**Flywheel:** volatility → higher fees → bigger treasury → stronger buffer next time

---

## Architecture

```
Trader
  │
  ▼
Uniswap V4 Pool
  │
  ├─▶ PegSentinelHook (execution layer)
  │     · intercepts every swap via beforeSwap
  │     · applies directional dynamic fees
  │     · fees flow to LP → vault collects into treasury
  │
  └─▶ PegSentinelVault V2 (defense layer)
        · owns LP NFT at [-60, +60] — never moves
        · collects swap fees into treasury
        · deploys treasury USDT as buffer at [-240, -60] during depeg
        · removes buffer on recovery, profiting from discount USDC

Keeper (backend)
  │
  └─▶ polls needsRebalance() every N seconds
        · calls collectFees() on schedule
        · calls autoRebalance() when regime change detected

Dashboard (frontend)
  └─▶ read-only monitor + manual rebalance trigger
        · live price, tick, deviation
        · fee preview for both swap directions
        · vault reserves and LP position details
```

---

## Regime Model

Two regimes with hysteresis prevent oscillation:

| Regime | Trigger | Vault State |
|---|---|---|
| `Normal` | `tick >= -30` | LP only, treasury accumulates |
| `Defend` | `tick <= -50` | LP + buffer deployed from treasury |

The gap between `-50` and `-30` is the hysteresis zone — no regime transition fires here, preventing rapid deploy/remove cycles.

---

## PegSentinel vs Classic LP

| | Classic LP | PegSentinel |
|---|---|---|
| LP at peg | Static | Static — never moves |
| Fee destination | Compounds back to LP | Accumulates in treasury |
| Below LP range | No defense | Buffer buy wall |
| Dynamic fees | None | 0.05% – 10% directional |
| Recovery | Passive | Asymmetric snap-back |
| Treasury P&L | None | Profits from buying the dip |

---

## Repository Structure

```
PegSentinel/
├── v4_hook/          # Solidity contracts + Foundry deployment pipeline
│   ├── src/
│   │   ├── PegSentinelHook.sol    # Dynamic fee hook
│   │   └── PegSentinelVault.sol  # Treasury + buffer vault
│   └── script/                   # Numbered deployment scripts (00–06)
│
├── backend/          # Node.js keeper — monitors vault, triggers rebalancing
│   └── src/
│       ├── index.js  # Main keeper loop
│       ├── config.js # Environment config
│       └── math.js   # Tick/price helpers
│
└── frontend/         # Next.js dashboard — live monitoring + manual control
    └── app/
        ├── page.tsx           # Overview
        ├── swap/page.tsx      # Swap interface + fee preview
        └── liquidity/page.tsx # Vault state + rebalance control
```

---

## Quickstart

### 1. Deploy Contracts

See [`v4_hook/README.md`](./v4_hook/README.md) for the full Foundry deployment pipeline (mock tokens → hook → pool → vault → fund → mint LP).

### 2. Run the Keeper

See [`backend/README.md`](./backend/README.md) for keeper setup. The keeper monitors the vault and calls `collectFees()` and `autoRebalance()` automatically.

### 3. Open the Dashboard

See [`frontend/README.md`](./frontend/README.md) for the Next.js dashboard. Point it at your deployed contracts to monitor live state.

---

## Tech Stack

| Layer | Stack |
|---|---|
| Contracts | Solidity 0.8.30, Foundry, Uniswap V4, OpenZeppelin |
| Keeper | Node.js, ethers.js v6, dotenv |
| Frontend | Next.js 16, React 19, TypeScript, Tailwind CSS v4, ethers.js v6 |
| Network | Arbitrum Sepolia (chain ID 421614) |

---

## Disclaimer

> ⚠️ **Research prototype — not production-ready.**
>
> PegSentinel has not been audited. It is intended for experimentation and design exploration around on-chain peg defense mechanisms. Do not deploy with real assets.

---

## License

MIT
