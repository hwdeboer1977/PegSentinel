# PegSentinel — Keeper

> **Node.js keeper service that monitors the PegSentinelVault and triggers on-chain rebalancing**

The keeper is a lightweight polling loop. All rebalancing logic lives on-chain in the vault — the keeper simply checks whether action is needed and sends the transaction.

---

## How It Works

```
Keeper                              Vault (on-chain)
  │                                      │
  ├─► needsRebalance() ─────────────────►│ Reads current tick vs thresholds
  │◄─ (needed, currentRegime, target) ───│
  │                                      │
  │  [if needed]                         │
  ├─► autoRebalance() ──────────────────►│ 1. Checks regime transition
  │                                      │ 2. Deploys or removes buffer
  │                                      │ 3. Updates activeRegime
  │◄─ TX confirmed ──────────────────────│ 4. Emits RegimeChanged event
  │                                      │
  │  [on schedule]                       │
  ├─► collectFees() ───────────────────► │ Pulls LP fees into treasury
  │◄─ FeesCollected event ───────────────│
```

---

## Tech Stack

| | |
|---|---|
| **Runtime** | Node.js (ESM) |
| **Ethereum library** | ethers.js v6 |
| **Config** | dotenv |
| **Target network** | Arbitrum Sepolia (chain ID 421614) |

---

## Setup

### 1. Install Dependencies

```bash
cd backend
npm install
```

### 2. Configure Environment

```bash
cp .env.example .env
```

Edit `.env`:

```bash
# Required
ARB_RPC=https://sepolia-rollup.arbitrum.io/rpc
PRIVATE_KEY=0x...
VAULT_ADDRESS=0x...

# Optional
CHAIN_ID=421614          # Arbitrum Sepolia (default)
POLL_SECONDS=15          # How often to poll (default: 15s)
FEE_COLLECT_MINUTES=60   # Fee collection interval (default: 60min)
TARGET_PRICE=1.0         # Reference peg price for logging
MAX_FEE_GWEI=50          # Max gas price to execute (default: 50 gwei)
DRY_RUN=0                # Set to 1 to disable transactions
```

### 3. Authorize the Keeper Wallet

The keeper wallet must be either the vault **owner** or set as the designated **keeper**:

```bash
# Run this once after deployment (owner only)
cast send $VAULT_ADDRESS "setKeeper(address)" $KEEPER_ADDRESS \
  --rpc-url $ARB_RPC --private-key $OWNER_PRIVATE_KEY
```

---

## Running

```bash
# Production
npm start

# Development (auto-restart on file change)
npm run dev

# Dry run — logs what it would do, no transactions sent
npm run dry-run
# or: DRY_RUN=1 npm start
```

---

## Example Output

**Normal conditions:**
```
===========================================
  PegSentinel Keeper V2 (Treasury Buffer)  
===========================================

Vault:  0xb64A...bed68
Keeper: 0x6122...D0997
Poll interval: 15 seconds
Fee collection interval: 60 minutes
Dry run: NO

[2025-03-13T09:00:00Z] tick=2 price=$1.000200 dev=+0.02% regime=Normal target=Normal treasury=[4821.50 USDC, 6103.20 USDT] needsRebalance=false
[2025-03-13T09:00:15Z] tick=0 price=$1.000000 dev=+0.00% regime=Normal target=Normal treasury=[4821.50 USDC, 6103.20 USDT] needsRebalance=false
```

**Fee collection:**
```
📥 Collecting fees from LP position...
📤 collectFees TX: 0xabc123...
✅ Fees collected in block 87654321
   USDC: 12.34, USDT: 9.87
```

**Depeg detected — buffer deploy:**
```
[2025-03-13T09:15:00Z] tick=-52 price=$0.994800 dev=-0.52% regime=Normal target=Defend treasury=[4833.84 USDC, 6113.07 USDT] needsRebalance=true

⚡ Rebalance needed: Normal → Defend
   Action: DEPLOY buffer (treasury USDT → LP at buffer range)
   Treasury USDT available: 6113.07
Gas price: 0.1 gwei. Executing...
📤 TX sent: 0xdef456...
✅ Mined in block 87654400
   Regime: Normal → Defend
   Tick: -52
   Buffer deployed: [-240, -60]
   USDT deployed: 6113.07
```

**Recovery:**
```
[2025-03-13T09:22:00Z] tick=-28 price=$0.997200 dev=-0.28% regime=Defend target=Normal treasury=[10921.34 USDC, 0.00 USDT] needsRebalance=true

⚡ Rebalance needed: Defend → Normal
   Action: REMOVE buffer (LP at buffer range → treasury)
📤 TX sent: 0xghi789...
✅ Mined in block 87654510
   Regime: Defend → Normal
   Buffer removed: tokenId 42
```

---

## Error Handling

The keeper handles common on-chain revert reasons gracefully:

| Revert | Keeper response |
|---|---|
| `CooldownActive` | Logs and waits until next poll |
| `NoRegimeChange` | Treats as race condition, no action |
| `InsufficientTreasuryUSDT` | Warns that buffer deploy will fail until fees accumulate |
| `BufferAlreadyActive` | Skips without error |
| Gas price above `MAX_FEE_GWEI` | Skips the transaction |

---

## File Structure

```
backend/
├── src/
│   ├── index.js    # Main keeper loop — polling, fee collection, rebalance
│   ├── config.js   # Environment variable loading and validation
│   └── math.js     # tickToPrice(), deviationBpsFromPeg()
├── package.json
├── .env.example
└── README.md
```

---

## Production Checklist

- [ ] Use a dedicated keeper wallet with minimal ETH for gas
- [ ] Set `MAX_FEE_GWEI` appropriate for the network
- [ ] Add alerting (Telegram, Discord, PagerDuty) for failed transactions
- [ ] Run multiple instances for redundancy
- [ ] Consider Flashbots for MEV protection on rebalance transactions
- [ ] Monitor treasury balance — buffer deploy fails if USDT treasury is empty

---

## Related

- [`../v4_hook/`](../v4_hook/README.md) — Smart contracts and deployment
- [`../frontend/`](../frontend/README.md) — Dashboard for monitoring vault state
- [`../README.md`](../README.md) — System overview and architecture
