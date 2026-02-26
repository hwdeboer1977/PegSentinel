# PegSentinel v4_hook

Technical documentation for deployment scripts and smart contracts.

---

## Quick Start

```bash
# 1. Setup environment
set -a; source .env; set +a

# 2. Deploy everything (in order)
forge script script/00_DeployMockTokens.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/01_DeployHook.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/02_CreatePoolAndAddLiquidity.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/03_DeployVault.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/04_FundVault.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/05_MintPositionToVault.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
forge script script/06_MintPositionToEOA.s.sol --rpc-url $ARB_RPC --broadcast --via-ir

# 3. Test vault
forge script script/TestVault.s.sol:TestVaultScript --rpc-url $ARB_RPC --broadcast --via-ir

# 4. Test full defense cycle
forge script script/TestVault_v2.s.sol:TestFullDefenseCycleScript --rpc-url $ARB_RPC --broadcast --via-ir

# Other tests
forge script script/AddLiquidity.s.sol --rpc-url $ARB_RPC --broadcast -vvvv --via-ir
forge script script/Check_liquidity.s.sol --rpc-url $ARB_RPC --broadcast -vvvv --via-ir
forge script script/Swap.s.sol --rpc-url $ARB_RPC --broadcast -vvvv --via-ir
```

---

## Environment Variables (.env)

```bash
# Required
PRIVATE_KEY=0x...
ARB_RPC=https://sepolia-rollup.arbitrum.io/rpc

# Token addresses (after 00_DeployMockTokens)
TOKEN0_ADDRESS=0x...
TOKEN1_ADDRESS=0x...

# Hook address (after 01_DeployHook)
HOOK_ADDRESS=0x...

# Vault address (after 03_DeployVault)
VAULT_ADDRESS=0x...

# Uniswap V4 infra (Arbitrum Sepolia)
POOL_MANAGER=0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317
POSITION_MANAGER=0xAc631556d3d4019C95769033B5E719dD77124BAc
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3

# Optional
AMOUNT0=10000000000  # 10,000 with 6 decimals
AMOUNT1=10000000000
POOL_FEE=500
TICK_SPACING=60
```

---

## Contracts

### `src/PegSentinelHook.sol`

Uniswap V4 hook implementing **dynamic peg-aware fees**.

| Feature      | Description                                      |
| ------------ | ------------------------------------------------ |
| `beforeSwap` | Calculates directional fee based on price vs peg |
| `MIN_FEE`    | 500 (0.05%) — for swaps toward peg               |
| `BASE_FEE`   | 3000 (0.3%) — at peg                             |
| `MAX_FEE`    | 100,000 (10%) — for swaps away from peg          |

**Key functions:**

```solidity
previewFee(PoolKey, bool zeroForOne) → (uint24 fee, PegDebug dbg)
keyDynamic(int24 tickSpacing) → PoolKey
```

---

### `src/PegSentinelVault.sol` (V2 — Treasury Buffer Model)

Protocol-owned vault for stablecoin peg defense. The core LP stays at peg permanently. Treasury from collected fees deploys as a buffer wall during depeg events.

| Feature               | Description                                              |
| --------------------- | -------------------------------------------------------- |
| **LP Position**       | Tight range at peg `[-60, +60]` — never moves            |
| **Buffer Position**   | Single-sided USDT below LP `[-240, -60]` — deploy/remove |
| **Treasury**          | Accumulated fees sitting in vault, funds the buffer       |
| **Fee Collection**    | `collectFees()` pulls LP fees into treasury               |
| **Regime Detection**  | Two regimes: Normal and Defend, with hysteresis           |
| **Auto Rebalance**    | `autoRebalance()` — deploy or remove buffer               |
| **Force Override**    | `forceDeployBuffer()` / `forceRemoveBuffer()`             |

**Key functions:**

```solidity
// View
getCurrentTick() → int24
needsRebalance() → (bool, Regime current, Regime target, int24 tick)
balances() → (uint256 bal0, uint256 bal1)
treasuryBalances() → (uint256 treasury0, uint256 treasury1)
getBufferLiquidity() → uint128

// Fee collection
collectFees()  // Keeper: pull fees from LP into treasury

// Buffer management
autoRebalance()        // Keeper: deploy or remove buffer based on tick
forceDeployBuffer()    // Owner: emergency deploy
forceRemoveBuffer()    // Owner: emergency remove

// Admin
setLPRange(int24, int24)
setBufferRange(int24, int24)
setThresholds(int24 defend, int24 recover)
setKeeper(address)
withdrawTreasury(address, uint256, uint256)
```

**Defense Thresholds (with hysteresis):**

```
tick <= defendThreshold   → Defend (deploy buffer)
tick >= recoverThreshold  → Normal (remove buffer)
defendThreshold < tick < recoverThreshold → no change
```

---

### `src/MockUSDT.sol` & `src/MockUSDC.sol`

Test ERC20 tokens with 6 decimals and public `mint()`.

```solidity
mint(address to, uint256 amount)  // Anyone can mint
```

---

## Deployment Scripts

### `00_DeployMockTokens.s.sol`

Deploys MockUSDT and MockUSDC tokens.

**Output:** TOKEN0_ADDRESS, TOKEN1_ADDRESS

---

### `01_DeployHook.s.sol`

Deploys PegSentinelHook with CREATE2 address mining.

**Output:** HOOK_ADDRESS

---

### `02_CreatePoolAndAddLiquidity.s.sol`

Initializes pool and adds initial liquidity.

**Creates:** Pool with dynamic fee flag and initial LP position to EOA.

---

### `03_DeployVault.s.sol`

Deploys PegSentinelVault V2 and configures ranges and thresholds.

**Configures:**

- LP range: `[-60, +60]` (tight at peg, never moves)
- Buffer range: `[-240, -60]` (treasury USDT during depeg)
- Defend threshold: `-50` (deploy buffer when tick drops below)
- Recover threshold: `-30` (remove buffer when tick rises above)
- Rebalance cooldown: `60s`
- Uniswap V4 infrastructure (PoolManager, PositionManager, Permit2)

**Output:** VAULT_ADDRESS

---

### `04_FundVault.s.sol`

Transfers tokens to vault.

```bash
AMOUNT0=10000000000 AMOUNT1=10000000000 \
forge script script/04_FundVault.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

---

### `05_MintPositionToVault.s.sol`

Mints LP position owned by vault at the configured LP range.

```bash
AMOUNT0=10000000000 AMOUNT1=10000000000 \
forge script script/05_MintPositionToVault.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

**Actions:**

1. Reads `vault.lpRange()` → `[-60, +60]`
2. Sets poolManager, positionManager, permit2
3. Funds vault with tokens
4. Mints LP NFT to vault (vault owns the position)
5. Registers via `setLPPosition()`

---

### `06_MintPositionToEOA.s.sol`

Mints LP position to your wallet (not vault).

---

## Utility Scripts

### `Swap.s.sol`

Execute swaps to move pool price.

```bash
# Swap 100 tokens, token0 → token1 (price down)
forge script script/Swap.s.sol:SwapScript --rpc-url $ARB_RPC --broadcast --via-ir

# Swap 500 tokens
AMOUNT_IN=500000000 forge script script/Swap.s.sol:SwapScript --rpc-url $ARB_RPC --broadcast --via-ir

# Swap token1 → token0 (price up)
ZERO_FOR_ONE=false forge script script/Swap.s.sol:SwapScript --rpc-url $ARB_RPC --broadcast --via-ir
```

---

### `TestVault.s.sol`

Four test contracts for vault V2 functionality.

```bash
# Full vault inspection
forge script script/TestVault.s.sol:TestVaultScript --rpc-url $ARB_RPC --broadcast --via-ir

# Test autoRebalance (buffer deploy/remove based on tick)
forge script script/TestVault.s.sol:TestAutoRebalanceScript --rpc-url $ARB_RPC --broadcast --via-ir

# Force deploy or remove buffer
BUFFER_ACTION=1 forge script script/TestVault.s.sol:TestForceBufferScript --rpc-url $ARB_RPC --broadcast --via-ir

# Test fee collection
forge script script/TestVault.s.sol:TestCollectFeesScript --rpc-url $ARB_RPC --broadcast --via-ir
```

---

### `TestVault_v2.s.sol`

Extended V2 tests covering remaining functions.

```bash
# Keeper setup
forge script script/TestVault_v2.s.sol:TestKeeperSetupScript --rpc-url $ARB_RPC --broadcast --via-ir

# Treasury withdrawal
forge script script/TestVault_v2.s.sol:TestWithdrawTreasuryScript --rpc-url $ARB_RPC --broadcast --via-ir

# Pause/unpause
forge script script/TestVault_v2.s.sol:TestPauseScript --rpc-url $ARB_RPC --broadcast --via-ir

# Rescue stuck tokens
forge script script/TestVault_v2.s.sol:TestRescueTokenScript --rpc-url $ARB_RPC --broadcast --via-ir

# Full defense cycle (collect fees → deploy buffer → remove buffer → P&L)
forge script script/TestVault_v2.s.sol:TestFullDefenseCycleScript --rpc-url $ARB_RPC --broadcast --via-ir
```

---

### `Check_liquidity.s.sol`

Inspect position liquidity and pool state.

---

### `AddLiquidity.s.sol`

Add liquidity to existing vault LP position.

```bash
AMOUNT0=5000000000 AMOUNT1=5000000000 \
forge script script/AddLiquidity.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

---

## Defense Model (V2)

### How It Works

PegSentinel V2 uses a **treasury buffer model** instead of moving LP positions between regimes.

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

### Key Design Principles

1. **LP never moves** — thick liquidity at peg is optimal defense
2. **Fees fund defense** — treasury grows from LP fee collection
3. **Asymmetric design** — hard to push down (buffer + high fees), easy to recover (thin zone + low fees)
4. **Treasury profits from volatility** — buys the dip + earns enhanced fees
5. **Hysteresis prevents oscillation** — gap between defend and recover thresholds

### Flywheel

```
Volatility → higher dynamic fees → bigger treasury → stronger buffer next time
```

---
