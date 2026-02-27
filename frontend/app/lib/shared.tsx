"use client";

import { createContext, useContext, useEffect, useMemo, useState, useCallback, type ReactNode } from "react";
import { Contract } from "ethers";
import { getProvider } from "./provider";
import { ADDR, isZeroAddress } from "./addresses";

// ============================================================================
// ABIs
// ============================================================================

const VaultABI = [
  "function activeRegime() view returns (uint8)",
  "function lpRange() view returns (int24 tickLower, int24 tickUpper)",
  "function bufferRange() view returns (int24 tickLower, int24 tickUpper)",
  "function lpPosition() view returns (uint256 tokenId, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liquidity, bool active)",
  "function bufferPosition() view returns (uint256 tokenId, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 liquidity, bool active)",
  "function balances() view returns (uint256 bal0, uint256 bal1)",
  "function treasuryBalances() view returns (uint256 treasury0, uint256 treasury1)",
  "function defendThreshold() view returns (int24)",
  "function recoverThreshold() view returns (int24)",
  "function needsRebalance() view returns (bool needed, uint8 currentRegime, uint8 targetRegime, int24 currentTick)",
  "function getBufferLiquidity() view returns (uint128)",
  "function totalFeesCollected0() view returns (uint256)",
  "function totalFeesCollected1() view returns (uint256)",
  "function autoRebalance() external",
  "function collectFees() external",
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

export type Regime = "Normal" | "Defend" | "Unknown";
export type RegimeStatus = "ok" | "warn" | "bad" | "na";

export interface FeePreview {
  fee: number;
  toward: boolean;
  devBps: number;
}

export interface PositionData {
  tokenId: string;
  tickLower: number;
  tickUpper: number;
  active: boolean;
  label: string;
}

export interface VaultBalances {
  bal0: bigint;
  bal1: bigint;
}

export interface LPPositionDetails {
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
  if (n === 1) return { regime: "Defend", status: "warn" };
  return { regime: "Unknown", status: "na" };
}

export function formatFee(feeBps: number): string {
  return `${(feeBps / 10000).toFixed(2)}%`;
}

export function formatBps(bps: number): string {
  const sign = bps >= 0 ? "+" : "";
  return `${sign}${(bps / 100).toFixed(2)}%`;
}

export function tickToPrice(tick: number): number {
  return Math.pow(1.0001, tick);
}

export function formatPrice(price: number): string {
  return price.toFixed(4);
}

export function formatBalance(bal: bigint, decimals: number): string {
  const divisor = BigInt(10 ** decimals);
  const whole = bal / divisor;
  const frac = bal % divisor;
  const fracStr = frac.toString().padStart(decimals, "0").slice(0, 2);
  return `${whole.toLocaleString()}.${fracStr}`;
}


// ============================================================================
// UI Components
// ============================================================================

export function StatusDot({ status }: { status: "ok" | "warn" | "bad" | "na" }) {
  const c = {
    ok: "bg-emerald-400 shadow-emerald-400/50",
    warn: "bg-amber-400 shadow-amber-400/50",
    bad: "bg-red-400 shadow-red-400/50",
    na: "bg-zinc-500 shadow-zinc-500/30",
  };
  return <span className={`inline-block w-2 h-2 rounded-full shadow-[0_0_6px] ${c[status]} animate-pulse`} />;
}

export function RegimeBadge({ regime, status }: { regime: Regime; status: RegimeStatus }) {
  const c = {
    ok: "border-emerald-500/30 text-emerald-400 bg-emerald-500/8",
    warn: "border-amber-500/30 text-amber-400 bg-amber-500/8",
    bad: "border-red-500/30 text-red-400 bg-red-500/8",
    na: "border-zinc-600 text-zinc-400 bg-zinc-500/8",
  };
  return (
    <span className={`inline-flex items-center gap-2 px-3 py-1.5 rounded-full border text-xs font-medium tracking-wider uppercase ${c[status]}`}>
      <StatusDot status={status} />
      {regime}
    </span>
  );
}

export function Card({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <div className={`bg-[var(--card)] border border-[var(--border)] rounded-2xl p-6 ${className}`}>
      {children}
    </div>
  );
}

export function SectionLabel({ children, color = "text-zinc-500" }: { children: ReactNode; color?: string }) {
  return (
    <div className={`text-[11px] font-semibold uppercase tracking-[0.14em] mb-4 ${color}`}>
      {children}
    </div>
  );
}

export function DataRow({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex items-center justify-between py-1.5">
      <span className="text-xs text-zinc-500">{label}</span>
      <span className="text-xs font-mono text-zinc-200">{value}</span>
    </div>
  );
}

export function PegHero({
  price, deviation, regime, regimeStatus, currentTick,
}: {
  price: number; deviation: number; regime: Regime; regimeStatus: RegimeStatus; currentTick: number;
}) {
  const clampedDev = Math.max(-500, Math.min(500, deviation));
  const gaugePos = ((clampedDev + 500) / 1000) * 100;
  const absDev = Math.abs(deviation);
  const devColor = absDev < 25 ? "text-emerald-400" : absDev < 100 ? "text-amber-400" : "text-red-400";
  const dotColor = absDev < 25 ? "bg-emerald-400 shadow-emerald-400/60" : absDev < 100 ? "bg-amber-400 shadow-amber-400/60" : "bg-red-400 shadow-red-400/60";

  return (
    <div className="text-center py-8">
      <div className="mb-6"><RegimeBadge regime={regime} status={regimeStatus} /></div>
      <div className="text-6xl font-mono font-extralight text-zinc-50 tracking-tighter mb-1">
        ${formatPrice(price)}
      </div>
      <div className={`text-lg font-mono ${devColor} mb-8`}>{formatBps(deviation)}</div>
      <div className="max-w-md mx-auto">
        <div className="flex justify-between text-[10px] text-zinc-500 font-mono mb-2">
          <span>$0.95</span><span className="text-zinc-500">$1.00</span><span>$1.05</span>
        </div>
        <div className="relative h-1.5 bg-[var(--card)] rounded-full">
          <div className="absolute left-1/2 -translate-x-1/2 -top-1 w-px h-3.5 bg-zinc-600" />
          <div className={`absolute top-1/2 -translate-y-1/2 w-3.5 h-3.5 rounded-full ${dotColor} shadow-[0_0_10px] transition-all duration-700`}
            style={{ left: `calc(${gaugePos}% - 7px)` }} />
        </div>
        <div className="mt-4 text-xs text-zinc-500 font-mono">Tick {currentTick}</div>
      </div>
    </div>
  );
}

export function FeeCard({ fee, toward, symbol0, symbol1, zeroForOne }: {
  fee: number; toward: boolean; symbol0: string; symbol1: string; zeroForOne: boolean;
}) {
  const dir = zeroForOne ? `${symbol0} → ${symbol1}` : `${symbol1} → ${symbol0}`;
  return (
    <div className={`p-4 rounded-xl border ${toward ? "bg-emerald-500/[0.04] border-emerald-500/20" : "bg-rose-500/[0.04] border-rose-500/20"}`}>
      <div className="flex items-center justify-between mb-3">
        <span className="text-xs text-zinc-400 font-mono">{dir}</span>
        <span className={`text-[10px] font-semibold uppercase tracking-wider ${toward ? "text-emerald-400" : "text-rose-400"}`}>
          {toward ? "TOWARD PEG" : "AWAY FROM PEG"}
        </span>
      </div>
      <span className="text-3xl font-mono font-light text-zinc-100">{formatFee(fee)}</span>
      <span className="text-[11px] text-zinc-500 ml-2">swap fee</span>
    </div>
  );
}

export function RangeViz({ currentTick, tickLower, tickUpper, regime }: {
  currentTick: number; tickLower: number; tickUpper: number; regime: Regime;
}) {
  const minTick = -1054, maxTick = 953, range = maxTick - minTick;
  const lowerPos = ((tickLower - minTick) / range) * 100;
  const upperPos = ((tickUpper - minTick) / range) * 100;
  const currentPos = ((currentTick - minTick) / range) * 100;
  const rangeWidth = upperPos - lowerPos;
  const inRange = currentTick >= tickLower && currentTick <= tickUpper;
  const rc = { Normal: "bg-emerald-500/15 border-emerald-500/40", Defend: "bg-amber-500/15 border-amber-500/40", Unknown: "bg-zinc-500/15 border-zinc-600/40" };

  return (
    <div>
      <div className="flex justify-between text-[10px] text-zinc-500 font-mono mb-2">
        {["$0.90", "$0.95", "$1.00", "$1.05", "$1.10"].map((p) => (
          <span key={p} className={p === "$1.00" ? "text-zinc-400" : ""}>{p}</span>
        ))}
      </div>
      <div className="relative h-10 bg-[var(--inner)] rounded-lg overflow-hidden">
        <div className="absolute left-1/2 top-0 bottom-0 w-px bg-zinc-600/50 -translate-x-1/2 z-10" />
        <div className={`absolute top-1.5 bottom-1.5 rounded-md border ${rc[regime]} transition-all duration-500`}
          style={{ left: `${lowerPos}%`, width: `${rangeWidth}%` }} />
        <div className={`absolute top-0 bottom-0 w-0.5 ${inRange ? "bg-zinc-200" : "bg-red-400"} transition-all duration-500 z-20`}
          style={{ left: `${Math.max(0, Math.min(100, currentPos))}%` }} />
      </div>
      <div className="flex justify-between items-center mt-2">
        <span className="text-xs text-zinc-500">
          Range: <span className="text-zinc-200 font-mono">${formatPrice(tickToPrice(tickLower))} – ${formatPrice(tickToPrice(tickUpper))}</span>
        </span>
        <span className={`text-xs font-medium ${inRange ? "text-emerald-400" : "text-red-400"}`}>
          {inRange ? "● In Range" : "○ Out of Range"}
        </span>
      </div>
    </div>
  );
}

// ============================================================================
// Context — single data source shared across all pages
// ============================================================================

interface PegSentinelState {
  loading: boolean;
  error: string | null;
  regime: number;
  regimeName: Regime;
  regimeStatus: RegimeStatus;
  position: PositionData | null;
  balances: VaultBalances | null;
  fee0to1: FeePreview | null;
  fee1to0: FeePreview | null;
  symbol0: string;
  symbol1: string;
  decimals0: number;
  decimals1: number;
  lpPosition: LPPositionDetails | null;
  bufferPosition: LPPositionDetails | null;
  currentTick: number;
  currentPrice: number;
  deviationBps: number;
  rangeConfigs: { lp: { tickLower: number; tickUpper: number }; buffer: { tickLower: number; tickUpper: number }; defendThreshold: number; recoverThreshold: number } | null;
  bufferActive: boolean;
  bufferLiquidity: string;
  totalFees: { fees0: string; fees1: string };
  targetRegime: number;
  targetRange: { tickLower: number; tickUpper: number } | null;
  needsRebalance: boolean;
  isOutOfRange: boolean;
  sqrtPriceX96: string;
  swapDirection: "0to1" | "1to0";
  setSwapDirection: (d: "0to1" | "1to0") => void;
  swapAmount: string;
  setSwapAmount: (a: string) => void;
  swapLoading: boolean;
  swapTxHash: string | null;
  executeSwap: () => Promise<void>;
  walletConnected: boolean;
  walletAddress: string | null;
  connectWallet: () => Promise<void>;
  rebalanceLoading: boolean;
  rebalanceTxHash: string | null;
  executeRebalance: () => Promise<void>;
  advancedOpen: boolean;
  setAdvancedOpen: (o: boolean) => void;
}

const PegSentinelContext = createContext<PegSentinelState | null>(null);

export function usePegSentinel(): PegSentinelState {
  const ctx = useContext(PegSentinelContext);
  if (!ctx) throw new Error("usePegSentinel must be used inside PegSentinelProvider");
  return ctx;
}

export function PegSentinelProvider({ children }: { children: ReactNode }) {
  // ── State ────────────────────────────────────────────────────────────────
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [regime, setRegime] = useState<number>(0);
  const [position, setPosition] = useState<PositionData | null>(null);
  const [balances, setBalances] = useState<VaultBalances | null>(null);
  const [fee0to1, setFee0to1] = useState<FeePreview | null>(null);
  const [fee1to0, setFee1to0] = useState<FeePreview | null>(null);
  const [symbol0, setSymbol0] = useState("TOKEN0");
  const [symbol1, setSymbol1] = useState("TOKEN1");
  const [decimals0, setDecimals0] = useState(6);
  const [decimals1, setDecimals1] = useState(6);
  const [lpPosition, setLpPosition] = useState<LPPositionDetails | null>(null);
  const [bufferPosition, setBufferPosition] = useState<LPPositionDetails | null>(null);
  const [swapDirection, setSwapDirection] = useState<"0to1" | "1to0">("0to1");
  const [swapAmount, setSwapAmount] = useState("");
  const [swapLoading, setSwapLoading] = useState(false);
  const [swapTxHash, setSwapTxHash] = useState<string | null>(null);
  const [walletConnected, setWalletConnected] = useState(false);
  const [walletAddress, setWalletAddress] = useState<string | null>(null);
  const [token0Address, setToken0Address] = useState<string | null>(null);
  const [token1Address, setToken1Address] = useState<string | null>(null);
  const [rebalanceLoading, setRebalanceLoading] = useState(false);
  const [rebalanceTxHash, setRebalanceTxHash] = useState<string | null>(null);
  const [currentTick, setCurrentTick] = useState(0);
  const [sqrtPriceX96, setSqrtPriceX96] = useState<string>("79228162514264337593543950336");
  const [rangeConfigs, setRangeConfigs] = useState<{
    lp: { tickLower: number; tickUpper: number };
    buffer: { tickLower: number; tickUpper: number };
    defendThreshold: number;
    recoverThreshold: number;
  } | null>(null);
  const [bufferActive, setBufferActive] = useState(false);
  const [bufferLiquidity, setBufferLiquidity] = useState<string>("0");
  const [totalFees, setTotalFees] = useState<{ fees0: string; fees1: string }>({ fees0: "0", fees1: "0" });
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [staticLoaded, setStaticLoaded] = useState(false);

  // ── Derived ──────────────────────────────────────────────────────────────
  const { regime: regimeName, status: regimeStatus } = useMemo(() => regimeFromNumber(regime), [regime]);
  const currentPrice = useMemo(() => tickToPrice(currentTick), [currentTick]);
  const deviationBps = useMemo(() => Math.round((currentPrice - 1.0) * 10000), [currentPrice]);
  const isOutOfRange = useMemo(() => {
    if (!position) return false;
    return currentTick < position.tickLower || currentTick > position.tickUpper;
  }, [currentTick, position]);
  const targetRegime = useMemo(() => {
    if (!rangeConfigs) return 0;
    return regime === 0
      ? (currentTick <= rangeConfigs.defendThreshold ? 1 : 0)
      : (currentTick >= rangeConfigs.recoverThreshold ? 0 : 1);
  }, [currentTick, rangeConfigs, regime]);
  const targetRange = useMemo(() => {
    if (!rangeConfigs) return null;
    return targetRegime === 0 ? rangeConfigs.lp : rangeConfigs.buffer;
  }, [targetRegime, rangeConfigs]);
  const needsRebalance = useMemo(() => targetRegime !== regime || isOutOfRange, [targetRegime, regime, isOutOfRange]);

  // ── Static data (symbols, decimals, addresses) — loaded ONCE ─────────
  const loadStaticData = useCallback(async () => {
    if (staticLoaded) return;
    try {
      const provider = getProvider();
      if (!isZeroAddress(ADDR.hook)) {
        const hook = new Contract(ADDR.hook, HookABI, provider);
        const [t0Addr, t1Addr] = await Promise.all([hook.token0(), hook.token1()]);
        const token0Contract = new Contract(t0Addr, ERC20ABI, provider);
        const token1Contract = new Contract(t1Addr, ERC20ABI, provider);
        const [sym0, sym1, dec0, dec1] = await Promise.all([
          token0Contract.symbol(), token1Contract.symbol(),
          token0Contract.decimals(), token1Contract.decimals(),
        ]);
        setSymbol0(sym0); setSymbol1(sym1);
        setDecimals0(Number(dec0)); setDecimals1(Number(dec1));
        setToken0Address(t0Addr); setToken1Address(t1Addr);
      }
      setStaticLoaded(true);
    } catch (e: any) {
      console.warn("Static data load failed:", e);
    }
  }, [staticLoaded]);

  // ── Dynamic data (prices, fees, positions) — polled every 15s ─────────
  const loadDynamicData = useCallback(async () => {
    try {
      const provider = getProvider();
      let tick = currentTick;
      let sqrtPrice = BigInt(sqrtPriceX96);

      // ① Pool state (single call)
      if (!isZeroAddress(ADDR.stateView) && ADDR.poolId !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
        try {
          const stateView = new Contract(ADDR.stateView, StateViewABI, provider);
          const slot0 = await stateView.getSlot0(ADDR.poolId);
          tick = Number(slot0.tick);
          sqrtPrice = BigInt(slot0.sqrtPriceX96.toString());
          setCurrentTick(tick);
          setSqrtPriceX96(sqrtPrice.toString());
        } catch (e) {
          console.warn("Could not load pool state:", e);
        }
      }

      // ② Vault data (batched Promise.all)
      if (!isZeroAddress(ADDR.vault)) {
        const vault = new Contract(ADDR.vault, VaultABI, provider);
        const [regimeVal, lpPos, bufPos, bals, lpRng, bufRng, defendTh, recoverTh, fees0, fees1] = await Promise.all([
          vault.activeRegime(), vault.lpPosition(), vault.bufferPosition(),
          vault.balances(), vault.lpRange(), vault.bufferRange(),
          vault.defendThreshold(), vault.recoverThreshold(),
          vault.totalFeesCollected0(), vault.totalFeesCollected1(),
        ]);

        setRegime(Number(regimeVal));
        setBalances({ bal0: bals.bal0, bal1: bals.bal1 });
        setTotalFees({ fees0: fees0.toString(), fees1: fees1.toString() });
        setRangeConfigs({
          lp: { tickLower: Number(lpRng[0]), tickUpper: Number(lpRng[1]) },
          buffer: { tickLower: Number(bufRng[0]), tickUpper: Number(bufRng[1]) },
          defendThreshold: Number(defendTh), recoverThreshold: Number(recoverTh),
        });
        setBufferActive(bufPos[5]);
        setBufferLiquidity(bufPos[4].toString());

        let activeTokenId: string | null = null;
        if (lpPos[5]) {
          activeTokenId = lpPos[0].toString();
          setPosition({ tokenId: activeTokenId, tickLower: Number(lpPos[1]), tickUpper: Number(lpPos[2]), active: true, label: "LP" });
        } else {
          setPosition(null);
        }

        // ③ LP position details (uses sqrtPrice from step ①, no duplicate call)
        if (!isZeroAddress(ADDR.positionManager) && activeTokenId && activeTokenId !== "0") {
          try {
            const tokenId = BigInt(activeTokenId);
            const posManager = new Contract(ADDR.positionManager, PositionManagerABI, provider);
            const [result, liquidity, owner] = await Promise.all([
              posManager.getPoolAndPositionInfo(tokenId),
              posManager.getPositionLiquidity(tokenId),
              posManager.ownerOf(tokenId),
            ]);
            const poolKey = result[0];
            const decoded = decodePositionInfo(BigInt(result[1].toString()));

            let amount0 = 0n, amount1 = 0n;
            try {
              const sqrtPriceAX96 = getSqrtPriceAtTick(decoded.tickLower);
              const sqrtPriceBX96 = getSqrtPriceAtTick(decoded.tickUpper);
              const amounts = getAmountsForLiquidity(sqrtPrice, sqrtPriceAX96, sqrtPriceBX96, BigInt(liquidity.toString()));
              amount0 = amounts.amount0;
              amount1 = amounts.amount1;
            } catch (e) { console.warn("Could not calculate amounts:", e); }

            setLpPosition({
              tokenId: Number(tokenId), owner, tickLower: decoded.tickLower, tickUpper: decoded.tickUpper,
              liquidity: liquidity.toString(), amount0: amount0.toString(), amount1: amount1.toString(),
              poolKey: { currency0: poolKey.currency0, currency1: poolKey.currency1, fee: Number(poolKey.fee), tickSpacing: Number(poolKey.tickSpacing), hooks: poolKey.hooks },
            });
          } catch (e) { console.warn("LP position not available:", e); }
        }

        // ③b Buffer position details
        const bufTokenId = bufPos[5] ? bufPos[0].toString() : null;
        if (!isZeroAddress(ADDR.positionManager) && bufTokenId && bufTokenId !== "0") {
          try {
            const tokenId = BigInt(bufTokenId);
            const posManager = new Contract(ADDR.positionManager, PositionManagerABI, provider);
            const [result, liquidity, owner] = await Promise.all([
              posManager.getPoolAndPositionInfo(tokenId),
              posManager.getPositionLiquidity(tokenId),
              posManager.ownerOf(tokenId),
            ]);
            const poolKey = result[0];
            const decoded = decodePositionInfo(BigInt(result[1].toString()));

            let amount0 = 0n, amount1 = 0n;
            try {
              const sqrtPriceAX96 = getSqrtPriceAtTick(decoded.tickLower);
              const sqrtPriceBX96 = getSqrtPriceAtTick(decoded.tickUpper);
              const amounts = getAmountsForLiquidity(sqrtPrice, sqrtPriceAX96, sqrtPriceBX96, BigInt(liquidity.toString()));
              amount0 = amounts.amount0;
              amount1 = amounts.amount1;
            } catch (e) { console.warn("Could not calculate buffer amounts:", e); }

            setBufferPosition({
              tokenId: Number(tokenId), owner, tickLower: decoded.tickLower, tickUpper: decoded.tickUpper,
              liquidity: liquidity.toString(), amount0: amount0.toString(), amount1: amount1.toString(),
              poolKey: { currency0: poolKey.currency0, currency1: poolKey.currency1, fee: Number(poolKey.fee), tickSpacing: Number(poolKey.tickSpacing), hooks: poolKey.hooks },
            });
          } catch (e) { console.warn("Buffer position not available:", e); }
        } else {
          setBufferPosition(null);
        }
      }

      // ④ Fee previews (uses cached token addresses)
      if (!isZeroAddress(ADDR.hook) && token0Address && token1Address) {
        try {
          const hook = new Contract(ADDR.hook, HookABI, provider);
          const poolKey = { currency0: token0Address, currency1: token1Address, fee: 0x800000, tickSpacing: 60, hooks: ADDR.hook };
          const [preview0to1, preview1to0] = await Promise.all([
            hook.previewFee(poolKey, true), hook.previewFee(poolKey, false),
          ]);
          // Determine toward-peg from tick + direction:
          // zeroForOne (0→1) pushes price DOWN. If price is ABOVE peg (tick>0), that's toward peg.
          // oneForZero (1→0) pushes price UP. If price is BELOW peg (tick<0), that's toward peg.
          const tick = currentTick;
          setFee0to1({ fee: Number(preview0to1.fee), toward: tick > 0, devBps: Number(preview0to1.dbg.devBps) });
          setFee1to0({ fee: Number(preview1to0.fee), toward: tick < 0, devBps: Number(preview1to0.dbg.devBps) });
        } catch (e) { console.warn("previewFee not available:", e); }
      }

      setError(null);
    } catch (e: any) {
      console.error("Load error:", e);
      setError(e?.message || String(e));
    } finally {
      setLoading(false);
    }
  }, [token0Address, token1Address, currentTick, sqrtPriceX96]);

  // ── Boot: static once, then dynamic on interval ─────────────────────────
  useEffect(() => { loadStaticData(); }, [loadStaticData]);
  useEffect(() => {
    if (!staticLoaded) return;
    loadDynamicData();
    const interval = setInterval(loadDynamicData, 15000);
    return () => clearInterval(interval);
  }, [staticLoaded, loadDynamicData]);

  // ── Wallet ───────────────────────────────────────────────────────────────
  useEffect(() => {
    const checkWallet = async () => {
      if (typeof window !== "undefined" && (window as any).ethereum) {
        try {
          const accounts = await (window as any).ethereum.request({ method: "eth_accounts" });
          if (accounts.length > 0) { setWalletConnected(true); setWalletAddress(accounts[0]); }
        } catch (e) { console.warn("Could not check wallet:", e); }
      }
    };
    checkWallet();
  }, []);

  const connectWallet = useCallback(async () => {
    if (typeof window !== "undefined" && (window as any).ethereum) {
      try {
        const accounts = await (window as any).ethereum.request({ method: "eth_requestAccounts" });
        if (accounts.length > 0) { setWalletConnected(true); setWalletAddress(accounts[0]); }
      } catch (e) { console.error("Could not connect wallet:", e); }
    } else { alert("Please install MetaMask!"); }
  }, []);

  // ── Swap ─────────────────────────────────────────────────────────────────
  const executeSwap = useCallback(async () => {
    if (!walletConnected || !token0Address || !token1Address) { alert("Please connect wallet first"); return; }
    if (!swapAmount || parseFloat(swapAmount) <= 0) { alert("Please enter a valid amount"); return; }
    setSwapLoading(true); setSwapTxHash(null);
    try {
      const { BrowserProvider, Contract: EthersContract, parseUnits } = await import("ethers");
      const provider = new BrowserProvider((window as any).ethereum);
      const signer = await provider.getSigner();
      const signerAddress = await signer.getAddress();
      const inputToken = swapDirection === "0to1" ? token0Address : token1Address;
      const inputDecimals = swapDirection === "0to1" ? decimals0 : decimals1;
      const amountIn = parseUnits(swapAmount, inputDecimals);

      const tokenContract = new EthersContract(inputToken, ERC20ABI, signer);
      let needsApproval = true;
      try { const allowance = await tokenContract.allowance(signerAddress, ADDR.swapRouter); needsApproval = allowance < amountIn; } catch { /* approve anyway */ }
      if (needsApproval) { const approveTx = await tokenContract.approve(ADDR.swapRouter, amountIn * BigInt(2)); await approveTx.wait(); }

      const poolKey = { currency0: token0Address, currency1: token1Address, fee: 0x800000, tickSpacing: 60, hooks: ADDR.hook };
      const router = new EthersContract(ADDR.swapRouter, SwapRouterABI, signer);
      const tx = await router.swapExactTokensForTokens(amountIn, 0, swapDirection === "0to1", poolKey, "0x", signerAddress, Math.floor(Date.now() / 1000) + 300, { gasLimit: 500000 });
      setSwapTxHash(tx.hash);
      await tx.wait();
      setSwapAmount("");
      loadDynamicData();
    } catch (e: any) { console.error("Swap error:", e); alert(`Swap failed: ${e?.message || e}`); }
    finally { setSwapLoading(false); }
  }, [walletConnected, token0Address, token1Address, swapAmount, swapDirection, decimals0, decimals1, loadDynamicData]);

  // ── Rebalance ────────────────────────────────────────────────────────────
  const executeRebalance = useCallback(async () => {
    if (!walletConnected) { alert("Please connect wallet first"); return; }
    if (!needsRebalance) { alert("No rebalance needed"); return; }
    setRebalanceLoading(true); setRebalanceTxHash(null);
    try {
      const { BrowserProvider, Contract: EthersContract } = await import("ethers");
      const provider = new BrowserProvider((window as any).ethereum);
      const signer = await provider.getSigner();
      const vault = new EthersContract(ADDR.vault, VaultABI, signer);
      if (targetRegime !== regime) {
        const tx = await vault.autoRebalance({ gasLimit: 500000 });
        setRebalanceTxHash(tx.hash);
        await tx.wait();
      } else { alert("No regime change needed."); }
      loadDynamicData();
    } catch (e: any) { console.error("Rebalance error:", e); alert(`Rebalance failed: ${e?.message || e}`); }
    finally { setRebalanceLoading(false); }
  }, [walletConnected, needsRebalance, targetRegime, regime, loadDynamicData]);

  // ── Context value ────────────────────────────────────────────────────────
  const value = useMemo<PegSentinelState>(() => ({
    loading, error, regime, regimeName, regimeStatus, position, balances,
    fee0to1, fee1to0, symbol0, symbol1, decimals0, decimals1,
    lpPosition, bufferPosition, currentTick, currentPrice, deviationBps,
    rangeConfigs, bufferActive, bufferLiquidity, totalFees,
    targetRegime, targetRange, needsRebalance, isOutOfRange, sqrtPriceX96,
    swapDirection, setSwapDirection, swapAmount, setSwapAmount,
    swapLoading, swapTxHash, executeSwap,
    walletConnected, walletAddress, connectWallet,
    rebalanceLoading, rebalanceTxHash, executeRebalance,
    advancedOpen, setAdvancedOpen,
  }), [
    loading, error, regime, regimeName, regimeStatus, position, balances,
    fee0to1, fee1to0, symbol0, symbol1, decimals0, decimals1,
    lpPosition, bufferPosition, currentTick, currentPrice, deviationBps,
    rangeConfigs, bufferActive, bufferLiquidity, totalFees,
    targetRegime, targetRange, needsRebalance, isOutOfRange, sqrtPriceX96,
    swapDirection, swapAmount, swapLoading, swapTxHash, executeSwap,
    walletConnected, walletAddress, connectWallet,
    rebalanceLoading, rebalanceTxHash, executeRebalance,
    advancedOpen,
  ]);

  return (
    <PegSentinelContext.Provider value={value}>
      {children}
    </PegSentinelContext.Provider>
  );
}
