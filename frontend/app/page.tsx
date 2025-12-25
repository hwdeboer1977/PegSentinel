"use client";

import { useEffect, useMemo, useState, useCallback } from "react";
import { Contract } from "ethers";
import { getProvider } from "./lib/provider";
import { ADDR, isZeroAddress } from "./lib/addresses";

// ============================================================================
// ABIs
// ============================================================================

const VaultABI = [
  "function activeRegime() view returns (uint8)",
  "function normalRange() view returns (int24 tickLower, int24 tickUpper, bool enabled)",
  "function mildRange() view returns (int24 tickLower, int24 tickUpper, bool enabled)",
  "function severeRange() view returns (int24 tickLower, int24 tickUpper, bool enabled)",
  "function normalPosition() view returns (uint256 tokenId, int24 tickLower, int24 tickUpper, bytes32 salt, bool active)",
  "function supportPosition() view returns (uint256 tokenId, int24 tickLower, int24 tickUpper, bytes32 salt, bool active)",
  "function balances() view returns (uint256 bal0, uint256 bal1)",
  "function setActiveRegime(uint8 regime) external",
  "function rebalance(address targetA, bytes calldata callA, address targetB, bytes calldata callB) external",
  "function owner() view returns (address)",
  "function keeper() view returns (address)",
];

const HookABI = [
  "function previewFee((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, bool zeroForOne) view returns (uint24 fee, (bool toward, uint256 devBps, uint256 rawFee) dbg)",
  "function MIN_FEE() view returns (uint24)",
  "function BASE_FEE() view returns (uint24)",
  "function MAX_FEE() view returns (uint24)",
  "function DEADZONE_BPS() view returns (uint256)",
  "function token0() view returns (address)",
  "function token1() view returns (address)",
];

const ERC20ABI = [
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
];

// Uniswap V4 PositionManager ABI (from docs)
const PositionManagerABI = [
  "function getPoolAndPositionInfo(uint256 tokenId) view returns ((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, uint256 info)",
  "function getPositionLiquidity(uint256 tokenId) view returns (uint128 liquidity)",
  "function ownerOf(uint256 tokenId) view returns (address)",
];

// PoolManager ABI for getting current price
const PoolManagerABI = [
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
];

// StateView ABI (v4-periphery lens contract for offchain reads)
const StateViewABI = [
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
];

// PoolSwapTest ABI (for testing swaps on V4)
const PoolSwapTestABI = [
  "function swap((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, (bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) params, (bool takeClaims, bool settleUsingBurn) testSettings, bytes hookData) payable returns (int256 delta)",
];

// Custom SwapRouter ABI (your deployed router)
const SwapRouterABI = [
  "function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, bool zeroForOne, (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bytes hookData, address receiver, uint256 deadline) returns (uint256 amountOut)",
];

// Helper to decode packed position info from V4
function decodePositionInfo(value: bigint): { tickUpper: number; tickLower: number; hasSubscriber: boolean } {
  const getTickUpper = () => {
    const raw = Number((value >> 32n) & 0xffffffn);
    return raw >= 0x800000 ? raw - 0x1000000 : raw;
  };
  
  const getTickLower = () => {
    const raw = Number((value >> 8n) & 0xffffffn);
    return raw >= 0x800000 ? raw - 0x1000000 : raw;
  };
  
  const hasSubscriber = () => (value & 0xffn) !== 0n;
  
  return {
    tickUpper: getTickUpper(),
    tickLower: getTickLower(),
    hasSubscriber: hasSubscriber(),
  };
}

// ============================================================================
// Uniswap Math Helpers (TickMath & LiquidityAmounts)
// ============================================================================

const Q96 = 2n ** 96n;

// Get sqrtPriceX96 from tick (equivalent to TickMath.getSqrtPriceAtTick)
function getSqrtPriceAtTick(tick: number): bigint {
  const absTick = Math.abs(tick);
  
  // Using the formula: sqrtPrice = 1.0001^(tick/2) * 2^96
  // We compute this using the precomputed magic numbers from Uniswap
  let ratio: bigint = (absTick & 0x1) !== 0 
    ? 0xfffcb933bd6fad37aa2d162d1a594001n 
    : 0x100000000000000000000000000000000n;
  
  if ((absTick & 0x2) !== 0) ratio = (ratio * 0xfff97272373d413259a46990580e213an) >> 128n;
  if ((absTick & 0x4) !== 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdccn) >> 128n;
  if ((absTick & 0x8) !== 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0n) >> 128n;
  if ((absTick & 0x10) !== 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644n) >> 128n;
  if ((absTick & 0x20) !== 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0n) >> 128n;
  if ((absTick & 0x40) !== 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861n) >> 128n;
  if ((absTick & 0x80) !== 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053n) >> 128n;
  if ((absTick & 0x100) !== 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4n) >> 128n;
  if ((absTick & 0x200) !== 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54n) >> 128n;
  if ((absTick & 0x400) !== 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3n) >> 128n;
  if ((absTick & 0x800) !== 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9n) >> 128n;
  if ((absTick & 0x1000) !== 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825n) >> 128n;
  if ((absTick & 0x2000) !== 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5n) >> 128n;
  if ((absTick & 0x4000) !== 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7n) >> 128n;
  if ((absTick & 0x8000) !== 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6n) >> 128n;
  if ((absTick & 0x10000) !== 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9n) >> 128n;
  if ((absTick & 0x20000) !== 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604n) >> 128n;
  if ((absTick & 0x40000) !== 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98n) >> 128n;
  if ((absTick & 0x80000) !== 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2n) >> 128n;

  if (tick > 0) ratio = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffn / ratio;

  // Round to nearest and shift to Q96
  return (ratio >> 32n) + (ratio % (1n << 32n) === 0n ? 0n : 1n);
}

// Calculate token amounts from liquidity (equivalent to LiquidityAmounts.getAmountsForLiquidity)
function getAmountsForLiquidity(
  sqrtPriceX96: bigint,
  sqrtPriceAX96: bigint,
  sqrtPriceBX96: bigint,
  liquidity: bigint
): { amount0: bigint; amount1: bigint } {
  // Ensure sqrtPriceA < sqrtPriceB
  if (sqrtPriceAX96 > sqrtPriceBX96) {
    [sqrtPriceAX96, sqrtPriceBX96] = [sqrtPriceBX96, sqrtPriceAX96];
  }

  let amount0 = 0n;
  let amount1 = 0n;

  if (sqrtPriceX96 <= sqrtPriceAX96) {
    // Current price is below the range - all token0
    amount0 = getAmount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
  } else if (sqrtPriceX96 < sqrtPriceBX96) {
    // Current price is in the range - both tokens
    amount0 = getAmount0ForLiquidity(sqrtPriceX96, sqrtPriceBX96, liquidity);
    amount1 = getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceX96, liquidity);
  } else {
    // Current price is above the range - all token1
    amount1 = getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
  }

  return { amount0, amount1 };
}

function getAmount0ForLiquidity(sqrtPriceAX96: bigint, sqrtPriceBX96: bigint, liquidity: bigint): bigint {
  if (sqrtPriceAX96 > sqrtPriceBX96) {
    [sqrtPriceAX96, sqrtPriceBX96] = [sqrtPriceBX96, sqrtPriceAX96];
  }
  return (liquidity * Q96 * (sqrtPriceBX96 - sqrtPriceAX96)) / sqrtPriceBX96 / sqrtPriceAX96;
}

function getAmount1ForLiquidity(sqrtPriceAX96: bigint, sqrtPriceBX96: bigint, liquidity: bigint): bigint {
  if (sqrtPriceAX96 > sqrtPriceBX96) {
    [sqrtPriceAX96, sqrtPriceBX96] = [sqrtPriceBX96, sqrtPriceAX96];
  }
  return (liquidity * (sqrtPriceBX96 - sqrtPriceAX96)) / Q96;
}

// ============================================================================
// Types
// ============================================================================

type Regime = "Normal" | "Mild" | "Severe" | "Unknown";
type RegimeStatus = "ok" | "warn" | "bad" | "na";

interface FeePreview {
  fee: number;
  toward: boolean;
  devBps: number;
}

interface PositionData {
  tokenId: string;
  tickLower: number;
  tickUpper: number;
  active: boolean;
  label: string;
}

interface VaultBalances {
  bal0: bigint;
  bal1: bigint;
}

interface LPPositionDetails {
  tokenId: number;
  owner: string;
  tickLower: number;
  tickUpper: number;
  liquidity: string;
  amount0: string;
  amount1: string;
  poolKey: {
    currency0: string;
    currency1: string;
    fee: number;
    tickSpacing: number;
    hooks: string;
  };
}

// ============================================================================
// Helpers
// ============================================================================

function regimeFromNumber(n: number): { regime: Regime; status: RegimeStatus } {
  if (n === 0) return { regime: "Normal", status: "ok" };
  if (n === 1) return { regime: "Mild", status: "warn" };
  if (n === 2) return { regime: "Severe", status: "bad" };
  return { regime: "Unknown", status: "na" };
}

function formatFee(feeBps: number): string {
  return `${(feeBps / 10000).toFixed(2)}%`;
}

function formatBps(bps: number): string {
  const sign = bps >= 0 ? "+" : "";
  return `${sign}${(bps / 100).toFixed(2)}%`;
}

function tickToPrice(tick: number): number {
  return Math.pow(1.0001, tick);
}

function formatPrice(price: number): string {
  return price.toFixed(4);
}

function formatBalance(bal: bigint, decimals: number): string {
  const divisor = BigInt(10 ** decimals);
  const whole = bal / divisor;
  const frac = bal % divisor;
  const fracStr = frac.toString().padStart(decimals, "0").slice(0, 2);
  return `${whole.toLocaleString()}.${fracStr}`;
}

// ============================================================================
// Components
// ============================================================================

function StatusBadge({ regime, status }: { regime: Regime; status: RegimeStatus }) {
  const colors = {
    ok: "bg-emerald-100 text-emerald-700 border-emerald-300",
    warn: "bg-amber-100 text-amber-700 border-amber-300",
    bad: "bg-red-100 text-red-700 border-red-300",
    na: "bg-gray-100 text-gray-600 border-gray-300",
  };

  return (
    <span className={`px-3 py-1.5 rounded-full border text-sm font-medium ${colors[status]}`}>
      {regime}
    </span>
  );
}

function Card({ title, children, accent }: { title: string; children: React.ReactNode; accent?: string }) {
  return (
    <div className="bg-white border border-gray-200 rounded-2xl p-6 shadow-sm">
      <h2 className={`text-sm font-semibold uppercase tracking-wider mb-4 ${accent || "text-gray-500"}`}>
        {title}
      </h2>
      <div className="space-y-3">{children}</div>
    </div>
  );
}

function DataRow({ label, value, highlight }: { label: string; value: React.ReactNode; highlight?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-4">
      <span className="text-sm text-gray-500">{label}</span>
      <span className={`text-sm font-mono ${highlight ? "text-gray-900" : "text-gray-700"}`}>{value}</span>
    </div>
  );
}

function PegGauge({ deviation, price }: { deviation: number; price: number }) {
  // deviation in bps, range roughly -5000 to +5000 for display
  const clampedDev = Math.max(-500, Math.min(500, deviation));
  const position = ((clampedDev + 500) / 1000) * 100;

  const getColor = () => {
    const absDev = Math.abs(deviation);
    if (absDev < 25) return "bg-emerald-500";
    if (absDev < 100) return "bg-amber-500";
    return "bg-red-500";
  };

  return (
    <div className="space-y-2">
      <div className="flex justify-between text-xs text-gray-400 font-mono">
        <span>$0.95</span>
        <span className="text-gray-600">$1.00</span>
        <span>$1.05</span>
      </div>
      <div className="relative h-3 bg-gray-100 rounded-full overflow-hidden">
        {/* Peg marker */}
        <div className="absolute left-1/2 top-0 bottom-0 w-0.5 bg-gray-300 -translate-x-1/2" />
        {/* Current position */}
        <div
          className={`absolute top-0.5 bottom-0.5 w-3 rounded-full ${getColor()} transition-all duration-500`}
          style={{ left: `calc(${position}% - 6px)` }}
        />
      </div>
      <div className="text-center">
        <span className="text-2xl font-mono text-gray-900">${formatPrice(price)}</span>
        <span className={`ml-2 text-sm font-mono ${deviation >= 0 ? "text-emerald-600" : "text-red-600"}`}>
          {formatBps(deviation)}
        </span>
      </div>
    </div>
  );
}

function FeeDisplay({
  label,
  fee,
  toward,
  symbol0,
  symbol1,
  zeroForOne,
}: {
  label: string;
  fee: number;
  toward: boolean;
  symbol0: string;
  symbol1: string;
  zeroForOne: boolean;
}) {
  const direction = zeroForOne ? `${symbol0} → ${symbol1}` : `${symbol1} → ${symbol0}`;
  const statusColor = toward ? "text-emerald-600" : "text-red-600";
  const statusBg = toward ? "bg-emerald-50" : "bg-red-50";
  const statusText = toward ? "TOWARD PEG" : "AWAY FROM PEG";

  return (
    <div className={`p-4 rounded-xl ${statusBg} border ${toward ? "border-emerald-200" : "border-red-200"}`}>
      <div className="flex items-center justify-between mb-2">
        <span className="text-sm text-gray-600">{direction}</span>
        <span className={`text-xs font-medium ${statusColor}`}>{statusText}</span>
      </div>
      <div className="flex items-baseline gap-2">
        <span className="text-3xl font-mono text-gray-900">{formatFee(fee)}</span>
        <span className="text-sm text-gray-500">swap fee</span>
      </div>
    </div>
  );
}

function LiquidityRangeViz({
  currentTick,
  tickLower,
  tickUpper,
  regime,
}: {
  currentTick: number;
  tickLower: number;
  tickUpper: number;
  regime: Regime;
}) {
  // Map ticks to visual range (roughly 0.90 to 1.10 in price terms)
  const minTick = -1054; // ~0.90
  const maxTick = 953; // ~1.10
  const range = maxTick - minTick;

  const lowerPos = ((tickLower - minTick) / range) * 100;
  const upperPos = ((tickUpper - minTick) / range) * 100;
  const currentPos = ((currentTick - minTick) / range) * 100;
  const rangeWidth = upperPos - lowerPos;

  const inRange = currentTick >= tickLower && currentTick <= tickUpper;

  const regimeColors = {
    Normal: "bg-emerald-200 border-emerald-400",
    Mild: "bg-amber-200 border-amber-400",
    Severe: "bg-red-200 border-red-400",
    Unknown: "bg-gray-200 border-gray-400",
  };

  return (
    <div className="space-y-2">
      <div className="flex justify-between text-xs text-gray-400 font-mono">
        <span>$0.90</span>
        <span>$0.95</span>
        <span className="text-gray-600">$1.00</span>
        <span>$1.05</span>
        <span>$1.10</span>
      </div>
      <div className="relative h-8 bg-gray-100 rounded-lg overflow-hidden">
        {/* Peg line */}
        <div className="absolute left-1/2 top-0 bottom-0 w-0.5 bg-gray-300 -translate-x-1/2 z-10" />

        {/* Liquidity range */}
        <div
          className={`absolute top-1 bottom-1 rounded border-2 ${regimeColors[regime]} transition-all duration-500`}
          style={{ left: `${lowerPos}%`, width: `${rangeWidth}%` }}
        />

        {/* Current price marker */}
        <div
          className={`absolute top-0 bottom-0 w-1 ${inRange ? "bg-gray-800" : "bg-red-500"} transition-all duration-500 z-20`}
          style={{ left: `${Math.max(0, Math.min(100, currentPos))}%` }}
        />
      </div>
      <div className="flex justify-between items-center text-sm">
        <span className="text-gray-500">
          Range: <span className="text-gray-700 font-mono">${formatPrice(tickToPrice(tickLower))} – ${formatPrice(tickToPrice(tickUpper))}</span>
        </span>
        <span className={inRange ? "text-emerald-600" : "text-red-600"}>
          {inRange ? "● In Range" : "○ Out of Range"}
        </span>
      </div>
    </div>
  );
}

function ActivityItem({
  time,
  action,
  detail,
  type,
}: {
  time: string;
  action: string;
  detail: string;
  type: "swap" | "regime" | "rebalance";
}) {
  const icons = {
    swap: "↔",
    regime: "◆",
    rebalance: "⟳",
  };
  const colors = {
    swap: "text-blue-500",
    regime: "text-amber-500",
    rebalance: "text-purple-500",
  };

  return (
    <div className="flex items-start gap-3 py-2 border-b border-gray-100 last:border-0">
      <span className={`${colors[type]} text-lg`}>{icons[type]}</span>
      <div className="flex-1 min-w-0">
        <div className="flex justify-between items-center">
          <span className="text-sm text-gray-700">{action}</span>
          <span className="text-xs text-gray-400 font-mono">{time}</span>
        </div>
        <span className="text-xs text-gray-500">{detail}</span>
      </div>
    </div>
  );
}

// ============================================================================
// Main Page
// ============================================================================

export default function Page() {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Regime & Position
  const [regime, setRegime] = useState<number>(0);
  const [position, setPosition] = useState<PositionData | null>(null);
  const [balances, setBalances] = useState<VaultBalances | null>(null);

  // Fee previews
  const [fee0to1, setFee0to1] = useState<FeePreview | null>(null);
  const [fee1to0, setFee1to0] = useState<FeePreview | null>(null);

  // Token info
  const [symbol0, setSymbol0] = useState("TOKEN0");
  const [symbol1, setSymbol1] = useState("TOKEN1");
  const [decimals0, setDecimals0] = useState(6);
  const [decimals1, setDecimals1] = useState(6);

  // LP Position from PositionManager
  const [lpPosition, setLpPosition] = useState<LPPositionDetails | null>(null);

  // Swap state
  const [swapDirection, setSwapDirection] = useState<"0to1" | "1to0">("0to1");
  const [swapAmount, setSwapAmount] = useState("");
  const [swapLoading, setSwapLoading] = useState(false);
  const [swapTxHash, setSwapTxHash] = useState<string | null>(null);
  const [walletConnected, setWalletConnected] = useState(false);
  const [walletAddress, setWalletAddress] = useState<string | null>(null);
  const [token0Address, setToken0Address] = useState<string | null>(null);
  const [token1Address, setToken1Address] = useState<string | null>(null);

  // Rebalance state
  const [rebalanceLoading, setRebalanceLoading] = useState(false);
  const [rebalanceTxHash, setRebalanceTxHash] = useState<string | null>(null);

  // Pool state from StateView
  const [currentTick, setCurrentTick] = useState(0);
  const [sqrtPriceX96, setSqrtPriceX96] = useState<string>("79228162514264337593543950336"); // Default tick 0

  // Range configs from vault
  const [rangeConfigs, setRangeConfigs] = useState<{
    normal: { tickLower: number; tickUpper: number; enabled: boolean };
    mild: { tickLower: number; tickUpper: number; enabled: boolean };
    severe: { tickLower: number; tickUpper: number; enabled: boolean };
  } | null>(null);

  // Derived values
  const { regime: regimeName, status: regimeStatus } = useMemo(() => regimeFromNumber(regime), [regime]);

  // Calculate current price and deviation from tick
  const currentPrice = useMemo(() => tickToPrice(currentTick), [currentTick]);
  const deviationBps = useMemo(() => Math.round((currentPrice - 1.0) * 10000), [currentPrice]);

  // Check if LP is out of range
  const isOutOfRange = useMemo(() => {
    if (!position) return false;
    return currentTick < position.tickLower || currentTick > position.tickUpper;
  }, [currentTick, position]);

  // Determine target regime based on current tick
  const targetRegime = useMemo(() => {
    if (!rangeConfigs) return 0;
    
    const { normal, mild } = rangeConfigs;
    
    // Check from Normal outward
    // Is tick within Normal range?
    if (currentTick >= normal.tickLower && currentTick <= normal.tickUpper) {
      return 0; // Normal
    }
    
    // Below peg: tick < normal.tickLower (-240)
    if (currentTick < normal.tickLower) {
      // Is it still above mild.tickLower (-540)?
      if (currentTick >= mild.tickLower) {
        return 1; // Mild
      }
      // Below mild.tickLower (-540) = Severe
      return 2; // Severe
    }
    
    // Above peg: tick > normal.tickUpper (240)
    if (currentTick > normal.tickUpper) {
      // Mirror logic for above peg
      if (currentTick <= -mild.tickLower) { // Assuming symmetric: 540
        return 1; // Mild
      }
      return 2; // Severe
    }
    
    return 0; // Normal (fallback)
  }, [currentTick, rangeConfigs]);

  // Get target range for display
  const targetRange = useMemo(() => {
    if (!rangeConfigs) return null;
    if (targetRegime === 0) return rangeConfigs.normal;
    if (targetRegime === 1) return rangeConfigs.mild;
    return rangeConfigs.severe;
  }, [targetRegime, rangeConfigs]);

  // Check if rebalancing is needed
  const needsRebalance = useMemo(() => {
    return targetRegime !== regime || isOutOfRange;
  }, [targetRegime, regime, isOutOfRange]);

  // Load data
  const loadData = useCallback(async () => {
    try {
      const provider = getProvider();

      // Load pool state from StateView (tick, price)
      if (!isZeroAddress(ADDR.stateView) && ADDR.poolId !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
        try {
          const stateView = new Contract(ADDR.stateView, StateViewABI, provider);
          const slot0 = await stateView.getSlot0(ADDR.poolId);
          const tick = Number(slot0.tick);
          const sqrtPrice = slot0.sqrtPriceX96.toString();
          
          setCurrentTick(tick);
          setSqrtPriceX96(sqrtPrice);
          
          console.log("Pool state from StateView:", { tick, sqrtPriceX96: sqrtPrice });
        } catch (e) {
          console.warn("Could not load pool state from StateView:", e);
        }
      }

      // Load vault data
      if (!isZeroAddress(ADDR.vault)) {
        const vault = new Contract(ADDR.vault, VaultABI, provider);

        const [regimeVal, normalPos, supportPos, bals, normalRng, mildRng, severeRng] = await Promise.all([
          vault.activeRegime(),
          vault.normalPosition(),
          vault.supportPosition(),
          vault.balances(),
          vault.normalRange(),
          vault.mildRange(),
          vault.severeRange(),
        ]);

        setRegime(Number(regimeVal));
        setBalances({ bal0: bals.bal0, bal1: bals.bal1 });
        
        // Store range configs
        setRangeConfigs({
          normal: { tickLower: Number(normalRng[0]), tickUpper: Number(normalRng[1]), enabled: normalRng[2] },
          mild: { tickLower: Number(mildRng[0]), tickUpper: Number(mildRng[1]), enabled: mildRng[2] },
          severe: { tickLower: Number(severeRng[0]), tickUpper: Number(severeRng[1]), enabled: severeRng[2] },
        });

        // Determine active position tokenId
        let activeTokenId: string | null = null;
        
        // Prefer support position if active, else normal
        if (supportPos[4]) {
          activeTokenId = supportPos[0].toString();
          setPosition({
            tokenId: activeTokenId,
            tickLower: Number(supportPos[1]),
            tickUpper: Number(supportPos[2]),
            active: true,
            label: "Support",
          });
        } else if (normalPos[4]) {
          activeTokenId = normalPos[0].toString();
          setPosition({
            tokenId: activeTokenId,
            tickLower: Number(normalPos[1]),
            tickUpper: Number(normalPos[2]),
            active: true,
            label: "Normal",
          });
        } else {
          setPosition(null);
        }

        // Load LP Position from PositionManager (using tokenId from vault)
        if (!isZeroAddress(ADDR.positionManager) && activeTokenId && activeTokenId !== "0") {
          try {
            const tokenId = BigInt(activeTokenId);
            const posManager = new Contract(ADDR.positionManager, PositionManagerABI, provider);
            
            // Get pool key and packed position info
            const result = await posManager.getPoolAndPositionInfo(tokenId);
            const poolKey = result[0];
            const packedInfo = BigInt(result[1].toString());
            
            // Get liquidity
            const liquidity = await posManager.getPositionLiquidity(tokenId);
            
            // Get owner
            const owner = await posManager.ownerOf(tokenId);
            
            // Decode packed position info
            const decoded = decodePositionInfo(packedInfo);
            
            // Calculate token amounts from liquidity
            let amount0 = 0n;
            let amount1 = 0n;
            
            // Get sqrtPriceX96 and tick from StateView (Uniswap V4 lens contract)
            try {
              let sqrtPrice = BigInt("79228162514264337593543950336"); // Default: tick 0 = price 1.0
              let tick = 0;
              
              // Try to read from StateView if poolId is configured
              if (!isZeroAddress(ADDR.stateView) && ADDR.poolId !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
                try {
                  const stateView = new Contract(ADDR.stateView, StateViewABI, provider);
                  const slot0 = await stateView.getSlot0(ADDR.poolId);
                  sqrtPrice = BigInt(slot0.sqrtPriceX96.toString());
                  tick = Number(slot0.tick);
                  console.log("StateView slot0:", {
                    sqrtPriceX96: sqrtPrice.toString(),
                    tick: tick,
                  });
                  
                  // Update global state
                  setCurrentTick(tick);
                  setSqrtPriceX96(sqrtPrice.toString());
                } catch (e) {
                  console.warn("Could not read from StateView, using default sqrtPriceX96:", e);
                }
              }
              
              // Calculate amounts
              const sqrtPriceAX96 = getSqrtPriceAtTick(decoded.tickLower);
              const sqrtPriceBX96 = getSqrtPriceAtTick(decoded.tickUpper);
              const amounts = getAmountsForLiquidity(
                sqrtPrice,
                sqrtPriceAX96,
                sqrtPriceBX96,
                BigInt(liquidity.toString())
              );
              amount0 = amounts.amount0;
              amount1 = amounts.amount1;
              
              console.log("Token amounts calculated:", {
                sqrtPriceX96: sqrtPriceX96.toString(),
                amount0: amount0.toString(),
                amount1: amount1.toString(),
              });
            } catch (e) {
              console.warn("Could not calculate amounts:", e);
            }
            
            setLpPosition({
              tokenId: Number(tokenId),
              owner: owner,
              tickLower: decoded.tickLower,
              tickUpper: decoded.tickUpper,
              liquidity: liquidity.toString(),
              amount0: amount0.toString(),
              amount1: amount1.toString(),
              poolKey: {
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                fee: Number(poolKey.fee),
                tickSpacing: Number(poolKey.tickSpacing),
                hooks: poolKey.hooks,
              },
            });
            
            console.log("LP Position loaded:", {
              tokenId: Number(tokenId),
              tickLower: decoded.tickLower,
              tickUpper: decoded.tickUpper,
              liquidity: liquidity.toString(),
              amount0: amount0.toString(),
              amount1: amount1.toString(),
            });
          } catch (e) {
            console.warn("LP position not available:", e);
          }
        }
      }

      // Load hook data & fee previews
      if (!isZeroAddress(ADDR.hook)) {
        const hook = new Contract(ADDR.hook, HookABI, provider);

        const [t0Addr, t1Addr] = await Promise.all([hook.token0(), hook.token1()]);

        // Get token symbols
        const token0Contract = new Contract(t0Addr, ERC20ABI, provider);
        const token1Contract = new Contract(t1Addr, ERC20ABI, provider);

        const [sym0, sym1, dec0, dec1] = await Promise.all([
          token0Contract.symbol(),
          token1Contract.symbol(),
          token0Contract.decimals(),
          token1Contract.decimals(),
        ]);

        setSymbol0(sym0);
        setSymbol1(sym1);
        setDecimals0(Number(dec0));
        setDecimals1(Number(dec1));
        setToken0Address(t0Addr);
        setToken1Address(t1Addr);

        // Build pool key for previewFee (order must match Uniswap V4 PoolKey struct)
        const poolKey = {
          currency0: t0Addr,
          currency1: t1Addr,
          fee: 0x800000, // DYNAMIC_FEE_FLAG
          tickSpacing: 60,
          hooks: ADDR.hook,
        };

        try {
          const [preview0to1, preview1to0] = await Promise.all([
            hook.previewFee(poolKey, true),
            hook.previewFee(poolKey, false),
          ]);

          setFee0to1({
            fee: Number(preview0to1.fee),
            toward: preview0to1.dbg.toward,
            devBps: Number(preview0to1.dbg.devBps),
          });

          setFee1to0({
            fee: Number(preview1to0.fee),
            toward: preview1to0.dbg.toward,
            devBps: Number(preview1to0.dbg.devBps),
          });
        } catch (e) {
          console.warn("previewFee not available:", e);
        }
      }

      setError(null);
    } catch (e: any) {
      console.error("Load error:", e);
      setError(e?.message || String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadData();
    const interval = setInterval(loadData, 15000);
    return () => clearInterval(interval);
  }, [loadData]);

  // Check if wallet is connected on mount
  useEffect(() => {
    const checkWallet = async () => {
      if (typeof window !== "undefined" && (window as any).ethereum) {
        try {
          const accounts = await (window as any).ethereum.request({ method: "eth_accounts" });
          if (accounts.length > 0) {
            setWalletConnected(true);
            setWalletAddress(accounts[0]);
          }
        } catch (e) {
          console.warn("Could not check wallet:", e);
        }
      }
    };
    checkWallet();
  }, []);

  // Connect wallet
  const connectWallet = async () => {
    if (typeof window !== "undefined" && (window as any).ethereum) {
      try {
        const accounts = await (window as any).ethereum.request({ method: "eth_requestAccounts" });
        if (accounts.length > 0) {
          setWalletConnected(true);
          setWalletAddress(accounts[0]);
        }
      } catch (e) {
        console.error("Could not connect wallet:", e);
      }
    } else {
      alert("Please install MetaMask!");
    }
  };

  // Execute swap
  const executeSwap = async () => {
    if (!walletConnected || !token0Address || !token1Address) {
      alert("Please connect wallet first");
      return;
    }

    if (!swapAmount || parseFloat(swapAmount) <= 0) {
      alert("Please enter a valid amount");
      return;
    }

    setSwapLoading(true);
    setSwapTxHash(null);

    try {
      const { BrowserProvider, Contract: EthersContract, parseUnits } = await import("ethers");
      const provider = new BrowserProvider((window as any).ethereum);
      const signer = await provider.getSigner();
      const signerAddress = await signer.getAddress();

      const inputToken = swapDirection === "0to1" ? token0Address : token1Address;
      const inputDecimals = swapDirection === "0to1" ? decimals0 : decimals1;
      const amountIn = parseUnits(swapAmount, inputDecimals);

      console.log("Swap details:", {
        inputToken,
        inputDecimals,
        amountIn: amountIn.toString(),
        signerAddress,
        swapRouter: ADDR.swapRouter,
      });

      // First approve tokens to SwapRouter
      const tokenContract = new EthersContract(inputToken, ERC20ABI, signer);
      
      // Try to check allowance, but if it fails just approve anyway
      let needsApproval = true;
      try {
        const allowance = await tokenContract.allowance(signerAddress, ADDR.swapRouter);
        console.log("Current allowance:", allowance.toString());
        needsApproval = allowance < amountIn;
      } catch (e) {
        console.warn("Could not check allowance, will approve anyway:", e);
      }
      
      if (needsApproval) {
        console.log("Approving tokens...");
        const approveTx = await tokenContract.approve(ADDR.swapRouter, amountIn * BigInt(2));
        await approveTx.wait();
        console.log("Approval confirmed");
      }

      // Build pool key (must match your pool exactly)
      const poolKey = {
        currency0: token0Address,
        currency1: token1Address,
        fee: 0x800000, // DYNAMIC_FEE_FLAG
        tickSpacing: 60,
        hooks: ADDR.hook,
      };

      const zeroForOne = swapDirection === "0to1";
      const hookData = "0x";
      const deadline = Math.floor(Date.now() / 1000) + 300; // 5 minutes

      // Execute swap using your custom router
      const router = new EthersContract(ADDR.swapRouter, SwapRouterABI, signer);
      console.log("Executing swap...", { 
        amountIn: amountIn.toString(), 
        zeroForOne, 
        poolKey,
        hookAddress: ADDR.hook,
        receiver: signerAddress,
        deadline 
      });
      
      const tx = await router.swapExactTokensForTokens(
        amountIn,
        0, // amountOutMin - allowing unlimited slippage for testing
        zeroForOne,
        poolKey,
        hookData,
        signerAddress, // receiver
        deadline,
        { gasLimit: 500000 } // Manual gas limit to bypass estimateGas
      );
      
      console.log("Swap tx:", tx.hash);
      setSwapTxHash(tx.hash);
      
      await tx.wait();
      console.log("Swap confirmed!");
      
      // Reload data
      setSwapAmount("");
      loadData();
    } catch (e: any) {
      console.error("Swap error:", e);
      alert(`Swap failed: ${e?.message || e}`);
    } finally {
      setSwapLoading(false);
    }
  };

  // Execute rebalance - simplified version that just updates the regime
  // A full implementation would call vault.rebalance() with proper calldata
  const executeRebalance = async () => {
    if (!walletConnected) {
      alert("Please connect wallet first");
      return;
    }

    if (!needsRebalance) {
      alert("No rebalance needed - position is optimal");
      return;
    }

    setRebalanceLoading(true);
    setRebalanceTxHash(null);

    try {
      const { BrowserProvider, Contract: EthersContract } = await import("ethers");
      const provider = new BrowserProvider((window as any).ethereum);
      const signer = await provider.getSigner();

      const vault = new EthersContract(ADDR.vault, VaultABI, signer);

      console.log("Rebalancing...", {
        currentTick,
        deviationBps,
        currentRegime: regime,
        targetRegime,
        targetRange,
      });

      // Update the active regime to target
      if (targetRegime !== regime) {
        const tx = await vault.setActiveRegime(targetRegime, { gasLimit: 100000 });
        console.log("Regime update tx:", tx.hash);
        setRebalanceTxHash(tx.hash);
        
        await tx.wait();
        console.log("Regime updated to:", targetRegime);
      } else {
        alert("Regime is already at target. Run keeper script to move liquidity.");
      }

      // Reload data
      loadData();
    } catch (e: any) {
      console.error("Rebalance error:", e);
      alert(`Rebalance failed: ${e?.message || e}`);
    } finally {
      setRebalanceLoading(false);
    }
  };

  return (
    <main className="min-h-screen bg-gray-50 text-gray-900">
      {/* Background gradient */}
      <div className="fixed inset-0 bg-gradient-to-br from-white via-gray-50 to-emerald-50/30 -z-10" />

      <div className="max-w-6xl mx-auto px-6 py-8">
        {/* Header */}
        <header className="flex items-center justify-between mb-8">
          <div>
            <h1 className="text-3xl font-bold tracking-tight">
              Peg<span className="text-emerald-600">Sentinel</span>
            </h1>
            <p className="text-sm text-gray-500 mt-1">
              Dynamic fee & liquidity management for stablecoin pegs
            </p>
          </div>
          <div className="flex items-center gap-4">
            <StatusBadge regime={regimeName} status={regimeStatus} />
            <div className="text-xs text-gray-400">
              {loading ? "Syncing..." : "Live"}
            </div>
          </div>
        </header>

        {/* Error display */}
        {error && (
          <div className="mb-6 p-4 rounded-xl bg-red-50 border border-red-200 text-red-700">
            <div className="font-medium">Connection Error</div>
            <div className="text-sm mt-1 text-red-600">{error}</div>
          </div>
        )}

        {/* Main grid */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {/* Peg Status */}
          <Card title="Peg Status" accent="text-emerald-600">
            <PegGauge deviation={deviationBps} price={currentPrice} />
            <div className="pt-4 border-t border-gray-100 mt-4">
              <DataRow label="Current Tick" value={currentTick.toString()} />
              <DataRow label="Deviation" value={formatBps(deviationBps)} highlight />
              <DataRow 
                label="Active Regime (Contract)" 
                value={
                  <span className={`font-medium ${
                    regime === 0 ? "text-emerald-600" : 
                    regime === 1 ? "text-amber-600" : 
                    regime === 2 ? "text-red-600" : "text-gray-600"
                  }`}>
                    {regimeName} ({regime})
                  </span>
                } 
              />
            </div>
          </Card>

          {/* Layer 1: Dynamic Fees */}
          <Card title="Layer 1: Dynamic Fees" accent="text-blue-600">
            {fee0to1 && fee1to0 ? (
              <div className="space-y-3">
                <FeeDisplay
                  label="Swap"
                  fee={fee0to1.fee}
                  toward={fee0to1.toward}
                  symbol0={symbol0}
                  symbol1={symbol1}
                  zeroForOne={true}
                />
                <FeeDisplay
                  label="Swap"
                  fee={fee1to0.fee}
                  toward={fee1to0.toward}
                  symbol0={symbol0}
                  symbol1={symbol1}
                  zeroForOne={false}
                />
              </div>
            ) : (
              <div className="text-gray-400 text-sm">Fee preview not available</div>
            )}
            <p className="text-xs text-gray-400 mt-4">
              Lower fees encourage swaps toward $1.00 peg, higher fees discourage swaps away
            </p>
          </Card>

          {/* Layer 2: Liquidity Management */}
          <Card title="Layer 2: Liquidity Management" accent="text-purple-600">
            {position ? (
              <>
                <LiquidityRangeViz
                  currentTick={currentTick}
                  tickLower={position.tickLower}
                  tickUpper={position.tickUpper}
                  regime={regimeName}
                />
                <div className="pt-4 border-t border-gray-100 mt-4">
                  <DataRow label="Active Position" value={position.label} highlight />
                  <DataRow label="Token ID" value={`#${position.tokenId}`} />
                  <DataRow
                    label="Tick Range"
                    value={`${position.tickLower} → ${position.tickUpper}`}
                  />
                </div>
              </>
            ) : (
              <div className="text-gray-400 text-sm">No active position</div>
            )}
          </Card>

          {/* Vault Status */}
          <Card title="Vault Reserves" accent="text-amber-600">
            {balances ? (
              <div className="space-y-4">
                <div className="flex items-center justify-between p-3 bg-gray-50 rounded-lg border border-gray-100">
                  <span className="text-gray-500">{symbol0}</span>
                  <span className="text-xl font-mono text-gray-900">
                    {formatBalance(balances.bal0, decimals0)}
                  </span>
                </div>
                <div className="flex items-center justify-between p-3 bg-gray-50 rounded-lg border border-gray-100">
                  <span className="text-gray-500">{symbol1}</span>
                  <span className="text-xl font-mono text-gray-900">
                    {formatBalance(balances.bal1, decimals1)}
                  </span>
                </div>
              </div>
            ) : (
              <div className="text-gray-400 text-sm">Vault not configured</div>
            )}
            <div className="pt-4 border-t border-gray-100 mt-4 text-xs text-gray-400">
              Protocol-owned liquidity ready to defend the peg
            </div>
          </Card>
        </div>

        {/* Current LP Overview - Full Width */}
        <div className="mt-6">
          <Card title="Current LP Overview" accent="text-indigo-600">
            {lpPosition ? (
              <div className="space-y-4">
                <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                  <div className="bg-indigo-50 rounded-lg p-4 border border-indigo-100">
                    <div className="text-xs text-indigo-600 uppercase tracking-wide mb-1">Token ID</div>
                    <div className="text-2xl font-mono text-gray-900">#{lpPosition.tokenId}</div>
                  </div>
                  <div className="bg-gray-50 rounded-lg p-4 border border-gray-100">
                    <div className="text-xs text-gray-500 uppercase tracking-wide mb-1">Liquidity</div>
                    <div className="text-xl font-mono text-gray-900">{BigInt(lpPosition.liquidity).toLocaleString()}</div>
                  </div>
                  <div className="bg-gray-50 rounded-lg p-4 border border-gray-100">
                    <div className="text-xs text-gray-500 uppercase tracking-wide mb-1">Tick Lower</div>
                    <div className="text-xl font-mono text-gray-900">{lpPosition.tickLower}</div>
                  </div>
                  <div className="bg-gray-50 rounded-lg p-4 border border-gray-100">
                    <div className="text-xs text-gray-500 uppercase tracking-wide mb-1">Tick Upper</div>
                    <div className="text-xl font-mono text-gray-900">{lpPosition.tickUpper}</div>
                  </div>
                </div>

                {/* Token Amounts */}
                <div className="grid grid-cols-2 gap-4">
                  <div className="bg-emerald-50 rounded-lg p-4 border border-emerald-100">
                    <div className="text-xs text-emerald-600 uppercase tracking-wide mb-1">{symbol0} Amount</div>
                    <div className="text-xl font-mono text-gray-900">
                      {formatBalance(BigInt(lpPosition.amount0), decimals0)}
                    </div>
                  </div>
                  <div className="bg-emerald-50 rounded-lg p-4 border border-emerald-100">
                    <div className="text-xs text-emerald-600 uppercase tracking-wide mb-1">{symbol1} Amount</div>
                    <div className="text-xl font-mono text-gray-900">
                      {formatBalance(BigInt(lpPosition.amount1), decimals1)}
                    </div>
                  </div>
                </div>
                
                <div className="pt-4 border-t border-gray-100">
                  <div className="flex justify-between items-center">
                    <span className="text-sm text-gray-500">Price Range</span>
                    <span className="text-sm font-mono text-gray-700">
                      ${tickToPrice(lpPosition.tickLower).toFixed(4)} — ${tickToPrice(lpPosition.tickUpper).toFixed(4)}
                    </span>
                  </div>
                  <div className="flex justify-between items-center mt-2">
                    <span className="text-sm text-gray-500">Owner</span>
                    <span className="text-sm font-mono text-gray-700">
                      {lpPosition.owner.slice(0, 6)}...{lpPosition.owner.slice(-4)}
                    </span>
                  </div>
                  <div className="flex justify-between items-center mt-2">
                    <span className="text-sm text-gray-500">Hook</span>
                    <span className="text-sm font-mono text-gray-700">
                      {lpPosition.poolKey.hooks.slice(0, 6)}...{lpPosition.poolKey.hooks.slice(-4)}
                    </span>
                  </div>
                  <div className="flex justify-between items-center mt-2">
                    <span className="text-sm text-gray-500">Status</span>
                    <span className={`text-sm font-medium ${
                      currentTick >= lpPosition.tickLower && currentTick <= lpPosition.tickUpper 
                        ? "text-emerald-600" 
                        : "text-red-600"
                    }`}>
                      {currentTick >= lpPosition.tickLower && currentTick <= lpPosition.tickUpper 
                        ? "● In Range" 
                        : "○ Out of Range"}
                    </span>
                  </div>
                </div>
              </div>
            ) : (
              <div className="text-sm text-gray-400">
                {position?.tokenId 
                  ? "Loading LP position from PositionManager..." 
                  : "No LP position configured. Set position in vault first."}
              </div>
            )}
          </Card>
        </div>

        {/* Swap Test Card */}
        <div className="mt-6">
          <Card title="Test Swap" accent="text-blue-600">
            <div className="space-y-4">
              {/* Wallet Connection */}
              {!walletConnected ? (
                <button
                  onClick={connectWallet}
                  className="w-full py-3 px-4 bg-blue-600 text-white rounded-lg font-medium hover:bg-blue-700 transition-colors"
                >
                  Connect Wallet
                </button>
              ) : (
                <div className="text-sm text-gray-500">
                  Connected: {walletAddress?.slice(0, 6)}...{walletAddress?.slice(-4)}
                </div>
              )}

              {walletConnected && (
                <>
                  {/* Direction Toggle */}
                  <div className="flex gap-2">
                    <button
                      onClick={() => setSwapDirection("0to1")}
                      className={`flex-1 py-2 px-4 rounded-lg font-medium transition-colors ${
                        swapDirection === "0to1"
                          ? "bg-blue-600 text-white"
                          : "bg-gray-100 text-gray-600 hover:bg-gray-200"
                      }`}
                    >
                      {symbol0} → {symbol1}
                    </button>
                    <button
                      onClick={() => setSwapDirection("1to0")}
                      className={`flex-1 py-2 px-4 rounded-lg font-medium transition-colors ${
                        swapDirection === "1to0"
                          ? "bg-blue-600 text-white"
                          : "bg-gray-100 text-gray-600 hover:bg-gray-200"
                      }`}
                    >
                      {symbol1} → {symbol0}
                    </button>
                  </div>

                  {/* Amount Input */}
                  <div>
                    <label className="block text-sm text-gray-500 mb-1">
                      Amount ({swapDirection === "0to1" ? symbol0 : symbol1})
                    </label>
                    <input
                      type="number"
                      value={swapAmount}
                      onChange={(e) => setSwapAmount(e.target.value)}
                      placeholder="0.0"
                      className="w-full px-4 py-3 border border-gray-200 rounded-lg text-lg font-mono focus:outline-none focus:ring-2 focus:ring-blue-500"
                    />
                  </div>

                  {/* Fee Preview */}
                  <div className="bg-gray-50 rounded-lg p-3 border border-gray-100">
                    <div className="flex justify-between text-sm">
                      <span className="text-gray-500">Expected Fee</span>
                      <span className="font-medium text-gray-700">
                        {swapDirection === "0to1" 
                          ? (fee0to1 ? formatFee(fee0to1.fee) : "—")
                          : (fee1to0 ? formatFee(fee1to0.fee) : "—")}
                      </span>
                    </div>
                    <div className="flex justify-between text-sm mt-1">
                      <span className="text-gray-500">Direction</span>
                      <span className={`font-medium ${
                        (swapDirection === "0to1" ? fee0to1?.toward : fee1to0?.toward)
                          ? "text-emerald-600"
                          : "text-amber-600"
                      }`}>
                        {(swapDirection === "0to1" ? fee0to1?.toward : fee1to0?.toward)
                          ? "TOWARD PEG"
                          : "AWAY FROM PEG"}
                      </span>
                    </div>
                  </div>

                  {/* Swap Button */}
                  <button
                    onClick={executeSwap}
                    disabled={swapLoading || !swapAmount}
                    className={`w-full py-3 px-4 rounded-lg font-medium transition-colors ${
                      swapLoading || !swapAmount
                        ? "bg-gray-200 text-gray-400 cursor-not-allowed"
                        : "bg-blue-600 text-white hover:bg-blue-700"
                    }`}
                  >
                    {swapLoading ? "Swapping..." : "Execute Swap"}
                  </button>

                  {/* Tx Hash */}
                  {swapTxHash && (
                    <div className="text-sm text-center">
                      <a
                        href={`https://sepolia.arbiscan.io/tx/${swapTxHash}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-blue-600 hover:underline"
                      >
                        View on Arbiscan →
                      </a>
                    </div>
                  )}
                </>
              )}
            </div>
          </Card>
        </div>

        {/* Rebalance Card */}
        <div className="mt-6">
          <Card 
            title="Layer 2: Rebalance Control" 
            accent={needsRebalance ? "text-red-600" : "text-purple-600"}
          >
            <div className="space-y-4">
              {/* Status Banner */}
              <div className={`p-4 rounded-lg border ${
                needsRebalance 
                  ? "bg-red-50 border-red-200" 
                  : "bg-emerald-50 border-emerald-200"
              }`}>
                <div className="flex items-center justify-between">
                  <div>
                    <div className={`text-sm font-medium ${
                      needsRebalance ? "text-red-700" : "text-emerald-700"
                    }`}>
                      {needsRebalance 
                        ? "⚠️ Rebalance Needed" 
                        : "✓ Position Optimally Placed"}
                    </div>
                    <div className="text-xs text-gray-500 mt-1">
                      Current Tick: {currentTick} | Position Range: {position?.tickLower ?? "—"} to {position?.tickUpper ?? "—"}
                    </div>
                  </div>
                  <div className={`text-2xl font-mono ${
                    Math.abs(deviationBps) > 100 ? "text-red-600" : 
                    Math.abs(deviationBps) > 50 ? "text-amber-600" : "text-emerald-600"
                  }`}>
                    {deviationBps >= 0 ? "+" : ""}{(deviationBps / 100).toFixed(2)}%
                  </div>
                </div>
              </div>

              {/* Current vs Target Regime */}
              <div className="grid grid-cols-2 gap-4">
                {/* Current State */}
                <div className="p-4 rounded-lg border border-gray-200 bg-gray-50">
                  <div className="text-xs text-gray-500 uppercase tracking-wide mb-2">Current State</div>
                  <div className={`text-lg font-semibold ${
                    regime === 0 ? "text-emerald-600" : 
                    regime === 1 ? "text-amber-600" : "text-red-600"
                  }`}>
                    {regimeName} Regime
                  </div>
                  {position && (
                    <div className="text-xs text-gray-500 mt-1">
                      Range: {position.tickLower} → {position.tickUpper}
                      <br />
                      Price: ${tickToPrice(position.tickLower).toFixed(4)} – ${tickToPrice(position.tickUpper).toFixed(4)}
                    </div>
                  )}
                </div>

                {/* Target State */}
                <div className={`p-4 rounded-lg border ${
                  needsRebalance 
                    ? "border-amber-300 bg-amber-50" 
                    : "border-emerald-200 bg-emerald-50"
                }`}>
                  <div className="text-xs text-gray-500 uppercase tracking-wide mb-2">
                    {needsRebalance ? "Should Move To" : "Target (Current)"}
                  </div>
                  <div className={`text-lg font-semibold ${
                    targetRegime === 0 ? "text-emerald-600" : 
                    targetRegime === 1 ? "text-amber-600" : "text-red-600"
                  }`}>
                    {targetRegime === 0 ? "Normal" : targetRegime === 1 ? "Mild" : "Severe"} Regime
                  </div>
                  {targetRange && (
                    <div className="text-xs text-gray-500 mt-1">
                      Range: {targetRange.tickLower} → {targetRange.tickUpper}
                      <br />
                      Price: ${tickToPrice(targetRange.tickLower).toFixed(4)} – ${tickToPrice(targetRange.tickUpper).toFixed(4)}
                    </div>
                  )}
                </div>
              </div>

              {/* Range Configs from Contract */}
              {rangeConfigs && (
                <div className="p-3 rounded-lg border border-gray-200 bg-gray-50">
                  <div className="text-xs text-gray-500 uppercase tracking-wide mb-2">Configured Ranges (from Vault)</div>
                  <div className="grid grid-cols-3 gap-2 text-xs">
                    <div className={`p-2 rounded ${regime === 0 ? "bg-emerald-100" : "bg-white"} border`}>
                      <div className="font-medium text-emerald-700">Normal</div>
                      <div className="text-gray-500">
                        {rangeConfigs.normal.tickLower} → {rangeConfigs.normal.tickUpper}
                      </div>
                      <div className="text-gray-400">
                        ${tickToPrice(rangeConfigs.normal.tickLower).toFixed(4)} – ${tickToPrice(rangeConfigs.normal.tickUpper).toFixed(4)}
                      </div>
                    </div>
                    <div className={`p-2 rounded ${regime === 1 ? "bg-amber-100" : "bg-white"} border`}>
                      <div className="font-medium text-amber-700">Mild</div>
                      <div className="text-gray-500">
                        {rangeConfigs.mild.tickLower} → {rangeConfigs.mild.tickUpper}
                      </div>
                      <div className="text-gray-400">
                        ${tickToPrice(rangeConfigs.mild.tickLower).toFixed(4)} – ${tickToPrice(rangeConfigs.mild.tickUpper).toFixed(4)}
                      </div>
                    </div>
                    <div className={`p-2 rounded ${regime === 2 ? "bg-red-100" : "bg-white"} border`}>
                      <div className="font-medium text-red-700">Severe</div>
                      <div className="text-gray-500">
                        {rangeConfigs.severe.tickLower} → {rangeConfigs.severe.tickUpper}
                      </div>
                      <div className="text-gray-400">
                        ${tickToPrice(rangeConfigs.severe.tickLower).toFixed(4)} – ${tickToPrice(rangeConfigs.severe.tickUpper).toFixed(4)}
                      </div>
                    </div>
                  </div>
                </div>
              )}

              {/* Rebalance Action */}
              {needsRebalance && (
                <div className="p-3 rounded-lg border border-amber-200 bg-amber-50">
                  <div className="text-sm font-medium text-amber-800 mb-1">📋 Rebalance Action Required</div>
                  <div className="text-xs text-amber-700">
                    {regime !== targetRegime && (
                      <div>• Change regime: {regimeName} → {targetRegime === 0 ? "Normal" : targetRegime === 1 ? "Mild" : "Severe"}</div>
                    )}
                    {isOutOfRange && targetRange && (
                      <div>• Move liquidity to: {targetRange.tickLower} → {targetRange.tickUpper}</div>
                    )}
                    <div className="mt-2 text-amber-600">
                      Run keeper script: <code className="bg-amber-100 px-1 rounded text-xs">forge script script/06_AdjustLiquidity.s.sol</code>
                    </div>
                  </div>
                </div>
              )}

              {/* Rebalance Button */}
              {walletConnected ? (
                <button
                  onClick={executeRebalance}
                  disabled={rebalanceLoading || !needsRebalance}
                  className={`w-full py-3 px-4 rounded-lg font-medium transition-colors ${
                    rebalanceLoading || !needsRebalance
                      ? "bg-gray-200 text-gray-400 cursor-not-allowed"
                      : "bg-red-600 text-white hover:bg-red-700"
                  }`}
                >
                  {rebalanceLoading 
                    ? "Updating..." 
                    : needsRebalance 
                      ? `🔄 Update Regime to ${targetRegime === 0 ? "Normal" : targetRegime === 1 ? "Mild" : "Severe"}` 
                      : "✓ No Rebalance Needed"}
                </button>
              ) : (
                <button
                  onClick={connectWallet}
                  className="w-full py-3 px-4 bg-purple-600 text-white rounded-lg font-medium hover:bg-purple-700 transition-colors"
                >
                  Connect Wallet to Rebalance
                </button>
              )}

              {/* Tx Hash */}
              {rebalanceTxHash && (
                <div className="text-sm text-center">
                  <a
                    href={`https://sepolia.arbiscan.io/tx/${rebalanceTxHash}`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="text-purple-600 hover:underline"
                  >
                    View on Arbiscan →
                  </a>
                </div>
              )}

              <div className="text-xs text-gray-400 pt-2 border-t border-gray-100">
                Regime updates are done via UI. Full liquidity repositioning requires the keeper script.
              </div>
            </div>
          </Card>
        </div>

        {/* Activity Feed (placeholder - would need event listening) */}
        <div className="mt-6">
          <Card title="Recent Activity" accent="text-gray-500">
            <div className="text-sm text-gray-400">
              Activity feed coming soon — connect to contract events for live updates
            </div>
            {/* Example items for UI preview:
            <ActivityItem
              time="12:04"
              action="Swap executed"
              detail="1,000 USDC → USDT at 0.15% fee (toward peg)"
              type="swap"
            />
            <ActivityItem
              time="12:01"
              action="Regime changed"
              detail="Normal → Mild (price deviation exceeded threshold)"
              type="regime"
            />
            <ActivityItem
              time="11:58"
              action="Liquidity rebalanced"
              detail="Moved to support range: $0.95 – $1.00"
              type="rebalance"
            />
            */}
          </Card>
        </div>

        {/* Footer */}
        <footer className="mt-8 pt-6 border-t border-gray-200 text-center text-xs text-gray-400">
          <p>PegSentinel • Uniswap V4 Hook • Built for UHI8 Hackathon</p>
          <p className="mt-1">
            RPC: {process.env.NEXT_PUBLIC_RPC_URL || "not configured"}
          </p>
        </footer>
      </div>
    </main>
  );
}
