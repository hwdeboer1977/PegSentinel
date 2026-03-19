# PegSentinel Smart Contracts

> Solidity contracts and Foundry scripts for the PegSentinel Uniswap v4 prototype.

This package contains the hook, vault, mock stablecoins, deployment scripts, and utility scripts used to demonstrate peg-aware execution and treasury-backed liquidity defense.

Related docs:

- [Root system overview](../README.md)
- [Backend keeper](../backend/README.md)
- [Frontend dashboard](../frontend/README.md)

---

## Package Contents

```text
v4_hook/
├── src/
│   ├── PegSentinelHook.sol
│   ├── PegSentinelVault.sol
│   ├── MockUSDC.sol
│   └── MockUSDT.sol
├── script/
│   ├── 00_DeployMockTokens.s.sol
│   ├── 01_DeployHook.s.sol
│   ├── 02_CreatePoolAndAddLiquidity.s.sol
│   ├── 03_DeployVault.s.sol
│   ├── 04_FundVault.s.sol
│   ├── 05_MintPositionToVault.s.sol
│   ├── 06_MintPositionToEOA.s.sol
│   ├── Swap.s.sol
│   ├── AddLiquidity.s.sol
│   ├── Check_liquidity.s.sol
│   └── TestVault.s.sol
├── test/
├── foundry.toml
└── README.md
```

---

## Main Contracts

### `PegSentinelHook.sol`

Custom Uniswap v4 hook for directional dynamic fees.

Purpose:

- inspect swap direction relative to the peg
- increase fees for destabilizing flow
- decrease fees for restorative flow
- expose fee preview logic for the frontend

Key fee constants:

| Constant   | Value   | Description                      |
| ---------- | ------- | -------------------------------- |
| `MIN_FEE`  | 500     | 0.05% — for swaps toward peg     |
| `BASE_FEE` | 3000    | 0.30% — at peg                   |
| `MAX_FEE`  | 100,000 | 10.00% — for swaps away from peg |

Useful functions:

```solidity
previewFee(PoolKey, bool zeroForOne)
keyDynamic(int24 tickSpacing)
```

---

### `PegSentinelVault.sol`

Vault contract that owns the LP strategy and treasury defense mechanism.

Purpose:

- maintain the main LP position at peg `[-60, +60]` — never moves
- collect fees into treasury balances
- detect regime changes from tick thresholds
- deploy a lower defensive buffer range `[-240, -60]` during stress
- remove that buffer when the peg normalizes

**Defense thresholds (with hysteresis):**

```
tick <= -50          → Defend  (deploy treasury USDT as buffer buy wall)
tick >= -30          → Normal  (remove buffer, treasury reclaims tokens)
-50 < tick < -30     → no change  (hysteresis gap prevents oscillation)
```

Useful functions:

```solidity
// View
getCurrentTick() → int24
needsRebalance() → (bool, Regime current, Regime target, int24 tick)
balances() → (uint256 bal0, uint256 bal1)
treasuryBalances() → (uint256 treasury0, uint256 treasury1)
getBufferLiquidity() → uint128

// Keeper
collectFees()       // Pull LP fees into treasury
autoRebalance()     // Deploy or remove buffer based on tick

// Owner override
forceDeployBuffer()
forceRemoveBuffer()

// Admin
setKeeper(address)
setThresholds(int24 defend, int24 recover)
withdrawTreasury(address, uint256, uint256)
```

---

### `MockUSDC.sol` and `MockUSDT.sol`

Simple 6-decimal mock tokens for local and testnet experimentation.

```solidity
mint(address to, uint256 amount)  // Anyone can mint
```

---

## Defense Model

PegSentinel uses a **treasury buffer model** with two layers of defense.

```
┌─────────────────────────────────────────────────┐
│  NORMAL: LP at [-60, +60]                       │
│  Fees accumulate in treasury                    │
│                                                 │
│  Keeper calls collectFees() periodically        │
│  Treasury grows: USDC + USDT from LP fees       │
├─────────────────────────────────────────────────┤
│  DEPEG: tick drops below -50                    │
│                                                 │
│  autoRebalance() → deployBuffer()               │
│  Treasury USDT → single-sided LP at [-240, -60] │
│  Two layers of defense:                         │
│    Layer 1: Dynamic fees (hook)                 │
│    Layer 2: Buffer buy wall (vault)             │
├─────────────────────────────────────────────────┤
│  RECOVERY: tick rises above -30                 │
│                                                 │
│  autoRebalance() → removeBuffer()               │
│  Buffer returns to treasury                     │
│  Treasury now holds USDC bought at discount     │
│  Profit = discount + dynamic fee revenue        │
└─────────────────────────────────────────────────┘
```

**Key design principles:**

1. **LP never moves** — thick liquidity at peg is optimal defense
2. **Fees fund defense** — treasury grows from LP fee collection
3. **Asymmetric design** — hard to push down (buffer + high fees), easy to recover
4. **Treasury profits from volatility** — buys the dip + earns enhanced fees
5. **Hysteresis prevents oscillation** — gap between defend and recover thresholds

**The flywheel:**

```
Volatility → higher dynamic fees → bigger treasury → stronger buffer next time
```

---

## Requirements

- Foundry installed
- Arbitrum Sepolia RPC URL
- Funded deployer wallet
- Uniswap v4 infrastructure addresses for the target chain

---

## Environment Variables

Create a local `.env` inside `v4_hook/` with at least:

```bash
PRIVATE_KEY=0x...
ARB_RPC=https://sepolia-rollup.arbitrum.io/rpc

# Token addresses (populated after 00_DeployMockTokens)
TOKEN0_ADDRESS=0x...
TOKEN1_ADDRESS=0x...

# Hook address (populated after 01_DeployHook)
HOOK_ADDRESS=0x...

# Vault address (populated after 03_DeployVault)
VAULT_ADDRESS=0x...

# Uniswap V4 infra (Arbitrum Sepolia)
POOL_MANAGER=0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317
POSITION_MANAGER=0xAc631556d3d4019C95769033B5E719dD77124BAc
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3

AMOUNT0=10000000000   # 10,000 with 6 decimals
AMOUNT1=10000000000
POOL_FEE=500
TICK_SPACING=60
```

---

## Deployment Order

Run the scripts in this order:

```bash
forge script script/00_DeployMockTokens.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/01_DeployHook.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/02_CreatePoolAndAddLiquidity.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/03_DeployVault.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/04_FundVault.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/05_MintPositionToVault.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/06_MintPositionToEOA.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

### What each script does

#### `00_DeployMockTokens.s.sol`
Deploys mock USDC and USDT.

#### `01_DeployHook.s.sol`
Deploys the PegSentinel hook using CREATE2 address mining.

#### `02_CreatePoolAndAddLiquidity.s.sol`
Creates the v4 pool with dynamic fee flag and adds initial liquidity.

#### `03_DeployVault.s.sol`
Deploys the vault and configures LP range `[-60, +60]`, buffer range `[-240, -60]`, defend/recover thresholds, and core addresses.

#### `04_FundVault.s.sol`
Transfers treasury tokens into the vault.

#### `05_MintPositionToVault.s.sol`
Mints the protocol-owned LP position to the vault.

#### `06_MintPositionToEOA.s.sol`
Optional helper to mint a position to the wallet instead of the vault.

---

## Utility Scripts

### Inspect or test the vault

```bash
# Full vault inspection
forge script script/TestVault.s.sol:TestVaultScript --rpc-url $ARB_RPC --broadcast --via-ir

# Test autoRebalance (buffer deploy/remove based on tick)
forge script script/TestVault.s.sol:TestAutoRebalanceScript --rpc-url $ARB_RPC --broadcast --via-ir

# Force deploy or remove buffer
BUFFER_ACTION=1 forge script script/TestVault.s.sol:TestForceBufferScript --rpc-url $ARB_RPC --broadcast --via-ir

# Test fee collection
forge script script/TestVault.s.sol:TestCollectFeesScript --rpc-url $ARB_RPC --broadcast --via-ir

# Full defense cycle (collect fees → deploy buffer → remove buffer → P&L)
forge script script/TestVault_v2.s.sol:TestFullDefenseCycleScript --rpc-url $ARB_RPC --broadcast --via-ir
```

### Simulate swaps

```bash
# Swap 100 tokens, token0 → token1 (price down)
forge script script/Swap.s.sol:SwapScript --rpc-url $ARB_RPC --broadcast --via-ir

# Swap 500 tokens
AMOUNT_IN=500000000 forge script script/Swap.s.sol:SwapScript --rpc-url $ARB_RPC --broadcast --via-ir

# Swap token1 → token0 (price up)
ZERO_FOR_ONE=false forge script script/Swap.s.sol:SwapScript --rpc-url $ARB_RPC --broadcast --via-ir
```

### Extra helpers

```bash
forge script script/AddLiquidity.s.sol --rpc-url $ARB_RPC --broadcast -vvvv --via-ir
forge script script/Check_liquidity.s.sol --rpc-url $ARB_RPC --broadcast -vvvv --via-ir
```

---

## Suggested Demo Flow

For a hackathon demo, a clean sequence is:

1. Deploy mock tokens, hook, pool, and vault
2. Fund the vault and mint the main LP position
3. Run swaps to move price off peg
4. Inspect `needsRebalance()` and vault state
5. Trigger `autoRebalance()`
6. Show treasury-funded defensive liquidity deployment
7. Let price recover and show buffer removal + P&L

---

## Important Notes

- This repo targets experimentation and demonstration, not production deployment.
- The current setup is best suited for Arbitrum Sepolia testing.
- Some admin and testing flows are intentionally exposed for rapid iteration during development.

---

## Safety Notice

These contracts are unaudited and should not be used with real funds.
