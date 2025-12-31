# PegSentinel Keeper

Minimal keeper service that monitors the PegSentinelVault and triggers on-chain rebalancing.

## How It Works

All rebalancing logic is **on-chain** in the vault. The keeper simply:

1. Polls `vault.needsRebalance()` every N seconds
2. If rebalance needed, calls `vault.autoRebalance()`
3. The vault handles everything: withdraw → calculate liquidity → mint/increase → update state

```
Keeper                          Vault (on-chain)
  │                                  │
  ├─► needsRebalance() ─────────────►│ Check tick vs thresholds
  │◄─ (needed, current, target, tick)│
  │                                  │
  │   if needed:                     │
  ├─► autoRebalance() ──────────────►│ 1. Withdraw from current position
  │                                  │ 2. Add liquidity to target range
  │                                  │ 3. Update activeRegime
  │◄─ TX confirmed ──────────────────│ 4. Emit Rebalanced event
```

## Setup

```bash
# Install dependencies
npm install

# Copy and configure environment
cp .env.example .env
# Edit .env with your values

# Run keeper
npm start

# Or dry-run mode (no transactions)
npm run dry-run
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ARB_RPC` | Yes | - | Arbitrum Sepolia RPC URL |
| `PRIVATE_KEY` | Yes | - | Keeper wallet private key |
| `VAULT_ADDRESS` | Yes | - | PegSentinelVault address |
| `CHAIN_ID` | No | 421614 | Chain ID (Arbitrum Sepolia) |
| `POLL_SECONDS` | No | 15 | Polling interval |
| `TARGET_PRICE` | No | 1.0 | Reference peg price for logging |
| `MAX_FEE_GWEI` | No | 50 | Max gas price to execute |
| `DRY_RUN` | No | 0 | Set to 1 to disable transactions |

## Example Output

```
===========================================
  PegSentinel Keeper (On-Chain Rebalance)  
===========================================

Vault: 0xb64Ae380D88A283a256Cd63303A41Dc3dEcbed68
Keeper: 0x6122db054706cD0Ff66301F5Afc5D121644D0997
Poll interval: 15 seconds
Dry run: NO

[2024-12-31T10:00:00Z] tick=-174 price=$0.982815 dev=-1.72% regime=Normal target=Normal needsRebalance=false
[2024-12-31T10:00:15Z] tick=-250 price=$0.975310 dev=-2.47% regime=Normal target=Mild needsRebalance=true

⚡ Rebalance needed: Normal → Mild
Gas price: 0.1 gwei. Executing...
📤 TX sent: 0x123...
✅ Mined in block 12345678
   From: Normal
   To: Mild
   Tick: -250
```

## Keeper Requirements

The keeper wallet must be either:
- The vault **owner**, or
- Set as the vault **keeper** via `vault.setKeeper(address)`

```solidity
// Set keeper address (owner only)
vault.setKeeper(0xYourKeeperAddress);
```

## Files

```
keeper/
├── src/
│   ├── index.js    # Main keeper loop
│   ├── config.js   # Environment config
│   └── math.js     # Price/tick helpers
├── package.json
├── .env.example
└── README.md
```

## Comparison: Before vs After

### Before (off-chain logic)
```javascript
// Keeper had to:
// 1. Read pool state
// 2. Compute target regime
// 3. Build decrease liquidity bundle
// 4. Call vault.execute(positionManager, ...)
// 5. Build increase/mint liquidity bundle  
// 6. Call vault.execute(positionManager, ...)
// 7. Update vault metadata
// 8. Set active regime
```

### After (on-chain logic)
```javascript
// Keeper just calls:
await vault.autoRebalance();
// Done! Vault handles everything atomically.
```

## Production Considerations

- [ ] Add alerting (Telegram, Discord, PagerDuty)
- [ ] Add metrics (Prometheus)
- [ ] Run multiple instances for redundancy
- [ ] Use a more robust transaction manager
- [ ] Consider Flashbots for MEV protection
