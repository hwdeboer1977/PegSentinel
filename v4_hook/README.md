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

# 3. Test rebalancing
forge script script/TestVault.s.sol:TestVaultScript --rpc-url $ARB_RPC --broadcast --via-ir

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

# Optional
AMOUNT0=10000000000  # 10,000 with 6 decimals
AMOUNT1=10000000000
```

---

## Contracts

### `src/PegSentinelHook.sol`

Uniswap V4 hook implementing **dynamic peg-aware fees**.

| Feature      | Description                                      |
| ------------ | ------------------------------------------------ |
| `beforeSwap` | Calculates directional fee based on price vs peg |
| `MIN_FEE`    | 500 (0.05%) - for swaps toward peg               |
| `BASE_FEE`   | 3000 (0.3%) - at peg                             |
| `MAX_FEE`    | 100,000 (10%) - for swaps away from peg          |

**Key functions:**

```solidity
previewFee(PoolKey, bool zeroForOne) → (uint24 fee, PegDebug dbg)
keyDynamic(int24 tickSpacing) → PoolKey
```

---

### `src/PegSentinelVault.sol`

Protocol-owned vault managing LP positions across regimes.

| Feature               | Description                                      |
| --------------------- | ------------------------------------------------ |
| **Regime Detection**  | On-chain tick thresholds determine regime        |
| **Auto Rebalance**    | `autoRebalance()` - keeper calls, vault executes |
| **Force Rebalance**   | `forceRebalance(Regime)` - owner override        |
| **Position Tracking** | `normalPosition` and `supportPosition`           |

**Key functions:**

```solidity
// View
getCurrentTick() → int24
needsRebalance() → (bool, Regime current, Regime target, int24 tick)
balances() → (uint256 bal0, uint256 bal1)

// Admin
setPoolManager(address)
setPositionManager(address)
setPermit2(address)
setPoolKey(currency0, currency1, fee, tickSpacing, hooks)
setRange(Regime, tickLower, tickUpper, enabled)
setThresholds(int24 mild, int24 severe)

// Rebalancing
autoRebalance()          // Keeper: auto-detect and rebalance
forceRebalance(Regime)   // Owner: force specific regime
```

**Regime Thresholds:**

```
tick > mildThreshold     → Normal
tick <= mildThreshold    → Mild
tick <= severeThreshold  → Severe
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

```bash
forge script script/00_DeployMockTokens.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

**Output:** TOKEN0_ADDRESS, TOKEN1_ADDRESS

---

### `01_DeployHook.s.sol`

Deploys PegSentinelHook with CREATE2 address mining.

```bash
forge script script/01_DeployHook.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

**Output:** HOOK_ADDRESS

---

### `02_CreatePoolAndAddLiquidity.s.sol`

Initializes pool and adds initial liquidity.

```bash
forge script script/02_CreatePoolAndAddLiquidity.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

**Creates:**

- Pool with dynamic fee flag
- Initial LP position to EOA

---

### `03_DeployVault.s.sol`

Deploys PegSentinelVault and configures regime ranges.

```bash
forge script script/03_DeployVault.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

**Configures:**

- Normal range: [-240, +240]
- Mild range: [-540, 0]
- Severe range: [-1620, -300]

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

Mints LP position owned by vault.

```bash
AMOUNT0=10000000000 AMOUNT1=10000000000 \
forge script script/05_MintPositionToVault.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

**Actions:**

1. Sets poolManager, positionManager, permit2
2. Funds vault
3. Mints LP NFT to vault
4. Registers as `normalPosition`
5. Sets `activeRegime = Normal`

---

### `06_MintPositionToEOA.s.sol`

Mints LP position to your wallet (not vault).

```bash
forge script script/06_MintPositionToEOA.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

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

Three test contracts for vault functionality.

```bash
# Full vault inspection
forge script script/TestVault.s.sol:TestVaultScript --rpc-url $ARB_RPC --broadcast --via-ir

# Test autoRebalance
forge script script/TestVault.s.sol:TestAutoRebalanceScript --rpc-url $ARB_RPC --broadcast --via-ir

# Force regime change
TARGET_REGIME=1 forge script script/TestVault.s.sol:TestForceRebalanceScript --rpc-url $ARB_RPC --broadcast --via-ir
```

---

### `Check_liquidity.s.sol`

Inspect position liquidity and pool state.

```bash
forge script script/Check_liquidity.s.sol --rpc-url $ARB_RPC --via-ir
```

---

### `AddLiquidity.s.sol`

Add liquidity to existing vault position.

```bash
AMOUNT0=5000000000 AMOUNT1=5000000000 \
forge script script/AddLiquidity.s.sol --rpc-url $ARB_RPC --broadcast --via-ir
```

---

## Regime Configuration

### Ranges (where liquidity goes)

```solidity
vault.setRange(Regime.Normal, -240, 240, true);   // Tight around peg
vault.setRange(Regime.Mild, -540, 0, true);       // Below peg support
vault.setRange(Regime.Severe, -1620, -300, true); // Deep depeg defense
```

### Thresholds (when to switch)

```solidity
vault.setThresholds(-240, -540);
// tick > -240       → Normal
// tick <= -240      → Mild
// tick <= -540      → Severe
```

---

## Rebalancing Flow

```
1. Keeper/Owner calls autoRebalance() or forceRebalance(Regime)

2. Vault reads currentTick from PoolManager

3. Vault determines targetRegime from thresholds

4. If targetRegime != activeRegime:
   a. Withdraw liquidity from current position
   b. Add liquidity to target regime's range
   c. Update activeRegime

5. Emit Rebalanced event
```

---
