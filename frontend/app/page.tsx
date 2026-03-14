"use client";

import { usePegSentinel, PegHero, Card, SectionLabel, RegimeBadge, DataRow, formatBalance, tickToPrice } from "./lib/shared";
import { Shell } from "./lib/Shell";

export default function OverviewPage() {
  const ps = usePegSentinel();

  const inRange = ps.position
    ? ps.currentTick >= ps.position.tickLower && ps.currentTick <= ps.position.tickUpper
    : false;

  return (
    <Shell loading={ps.loading} error={ps.error}>

      {/* Price banner — full width */}
      <div className="bg-[var(--card)] rounded-2xl border border-[var(--border)] p-6 mb-4">
        <div className="flex items-center justify-between">
          <div>
            <div className="flex items-center gap-3 mb-1">
              <span className="text-sm text-zinc-500">USDC / USDT</span>
              <RegimeBadge regime={ps.regimeName} status={ps.regimeStatus} />
            </div>
            <div className="text-5xl font-mono font-extralight text-zinc-50 tracking-tighter">
              ${ps.currentPrice > 0 ? ps.currentPrice.toFixed(3) : "—"}
            </div>
          </div>
          <div className="text-right">
            <div className="text-xs text-zinc-500 mb-1">Deviation</div>
            <div className={`text-2xl font-mono font-light ${
              Math.abs(ps.deviationBps) < 25 ? "text-emerald-400" :
              Math.abs(ps.deviationBps) < 100 ? "text-amber-400" : "text-rose-400"
            }`}>
              {ps.deviationBps >= 0 ? "+" : ""}{(ps.deviationBps / 100).toFixed(2)}%
            </div>
            <div className="text-xs text-zinc-600 font-mono mt-1">Tick {ps.currentTick}</div>
          </div>
        </div>

        {/* Gauge */}
        <div className="mt-5">
          <div className="flex justify-between text-xs text-zinc-500 font-mono mb-1.5">
            <span>$0.95</span><span className="text-zinc-400">$1.00</span><span>$1.05</span>
          </div>
          <div className="relative h-1.5 bg-[var(--inner)] rounded-full">
            <div className="absolute inset-y-0 left-1/3 right-1/3 bg-emerald-500/20 rounded-full" />
            <div
              className="absolute top-1/2 -translate-y-1/2 w-3 h-3 rounded-full bg-amber-400 border-2 border-[var(--bg)] shadow transition-all"
              style={{ left: `${Math.min(Math.max(50 + (ps.deviationBps / 100) * 10, 2), 98)}%` }}
            />
          </div>
        </div>
      </div>

      {/* Rebalance alert */}
      {ps.needsRebalance && (
        <div className="mb-4 p-4 rounded-xl bg-amber-500/[0.06] border border-amber-500/20 flex items-center justify-between">
          <div>
            <div className="text-sm font-medium text-amber-400">⚠ Rebalance Action Required</div>
            <div className="text-xs text-zinc-500 mt-1">
              Peg deviation requires a regime change. Visit the{" "}
              <a href="/liquidity" className="text-violet-400 hover:text-violet-300 underline">Liquidity</a> page to execute.
            </div>
          </div>
          <div className={`text-2xl font-mono font-light ${
            Math.abs(ps.deviationBps) > 100 ? "text-rose-400" : "text-amber-400"
          }`}>
            {ps.deviationBps >= 0 ? "+" : ""}{(ps.deviationBps / 100).toFixed(2)}%
          </div>
        </div>
      )}

      {/* Main 2-column grid */}
      <div className="grid lg:grid-cols-2 gap-4 mb-4">

        {/* Left — Description */}
        <Card>
          <h2 className="text-base font-semibold text-zinc-100 mb-3" style={{ fontFamily: "'Outfit', sans-serif" }}>
            Autonomous Peg Defense
          </h2>
          <p className="text-sm text-zinc-400 leading-relaxed mb-5">
            PegSentinel is a Uniswap V4 Hook that actively defends stablecoin pegs through two coordinated layers of protection — keeping prices stable even during market stress.
          </p>
          <div className="space-y-4">
            <div className="flex items-start gap-3">
              <div className="w-9 h-9 rounded-lg bg-cyan-500/10 border border-cyan-500/20 flex items-center justify-center text-cyan-400 flex-shrink-0">⇄</div>
              <div>
                <div className="text-sm font-medium text-zinc-200 mb-1">Layer 1 · Dynamic Fees</div>
                <p className="text-sm text-zinc-500 leading-relaxed">
                  Swap fees adjust in real-time based on price deviation. Stabilising swaps pay less, destabilising swaps pay more — creating natural economic incentives.
                </p>
              </div>
            </div>
            <div className="flex items-start gap-3">
              <div className="w-9 h-9 rounded-lg bg-violet-500/10 border border-violet-500/20 flex items-center justify-center text-violet-400 flex-shrink-0">◈</div>
              <div>
                <div className="text-sm font-medium text-zinc-200 mb-1">Layer 2 · Active Liquidity</div>
                <p className="text-sm text-zinc-500 leading-relaxed">
                  When price deviates beyond thresholds, the vault automatically deploys buffer liquidity as a buy wall — defending the peg with protocol-owned reserves.
                </p>
              </div>
            </div>
          </div>
        </Card>

        {/* Right — Live system status */}
        <Card>
          <SectionLabel color="text-emerald-400">System Status</SectionLabel>
          <div className="space-y-2 mb-4">
            <div className="flex items-center justify-between p-3.5 bg-[var(--inner)] rounded-xl border border-[var(--border)]">
              <span className="text-sm text-zinc-400">Active Regime</span>
              <RegimeBadge regime={ps.regimeName} status={ps.regimeStatus} />
            </div>
            <DataRow label="Current Tick" value={ps.currentTick.toString()} />
            <DataRow label="Deviation" value={`${ps.deviationBps >= 0 ? "+" : ""}${(ps.deviationBps / 100).toFixed(2)}%`} />
            {ps.fee0to1 && (
              <>
                <DataRow label={`Fee ${ps.symbol0}→${ps.symbol1}`} value={`${(ps.fee0to1.fee / 10000).toFixed(2)}%`} />
                <DataRow label={`Fee ${ps.symbol1}→${ps.symbol0}`} value={ps.fee1to0 ? `${(ps.fee1to0.fee / 10000).toFixed(2)}%` : "—"} />
              </>
            )}
            {ps.position && (
              <>
                <DataRow label="LP Range" value={`${ps.position.tickLower} → ${ps.position.tickUpper}`} />
                <DataRow
                  label="Position Status"
                  value={
                    <span className={inRange ? "text-emerald-400" : "text-red-400"}>
                      {inRange ? "● In Range" : "○ Out of Range"}
                    </span>
                  }
                />
              </>
            )}
            {ps.bufferActive && (
              <DataRow label="Buffer" value={<span className="text-amber-400">🛡 Active</span>} />
            )}
          </div>

          {/* Vault reserves */}
          {ps.balances && (
            <div className="pt-3 border-t border-[var(--border)]/60">
              <SectionLabel>Vault Reserves</SectionLabel>
              <div className="grid grid-cols-2 gap-2">
                <div className="p-3 bg-[var(--inner)] rounded-lg border border-[var(--border)] text-center">
                  <div className="text-xs text-zinc-500 mb-1">{ps.symbol0}</div>
                  <div className="text-sm font-mono text-zinc-100">{formatBalance(ps.balances.bal0, ps.decimals0)}</div>
                </div>
                <div className="p-3 bg-[var(--inner)] rounded-lg border border-[var(--border)] text-center">
                  <div className="text-xs text-zinc-500 mb-1">{ps.symbol1}</div>
                  <div className="text-sm font-mono text-zinc-100">{formatBalance(ps.balances.bal1, ps.decimals1)}</div>
                </div>
              </div>
            </div>
          )}
        </Card>
      </div>

      {/* Feature cards — 3 columns */}
      <div className="grid md:grid-cols-3 gap-4">
        <div className="bg-[var(--card)] rounded-xl border border-[var(--border)] p-5">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-9 h-9 rounded-lg bg-cyan-500/10 border border-cyan-500/20 flex items-center justify-center text-cyan-400">⇄</div>
            <h3 className="font-medium text-zinc-100">Dynamic Fees</h3>
          </div>
          <p className="text-sm text-zinc-500 leading-relaxed">
            Fee tier adjusts continuously from 0.05% to 10% based on real-time peg deviation — making arbitrage profitable in the right direction.
          </p>
        </div>
        <div className="bg-[var(--card)] rounded-xl border border-[var(--border)] p-5">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-9 h-9 rounded-lg bg-emerald-500/10 border border-emerald-500/20 flex items-center justify-center text-emerald-400">◈</div>
            <h3 className="font-medium text-zinc-100">Treasury Buffer</h3>
          </div>
          <p className="text-sm text-zinc-500 leading-relaxed">
            Protocol-owned USDT deploys as single-sided buffer liquidity during depeg events — creating a persistent buy wall that defends the $1.00 floor.
          </p>
        </div>
        <div className="bg-[var(--card)] rounded-xl border border-[var(--border)] p-5">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-9 h-9 rounded-lg bg-violet-500/10 border border-violet-500/20 flex items-center justify-center text-violet-400">◉</div>
            <h3 className="font-medium text-zinc-100">Autonomous Rebalancing</h3>
          </div>
          <p className="text-sm text-zinc-500 leading-relaxed">
            Regime transitions trigger automatically via keeper. Hysteresis prevents oscillation — the system only switches state when the signal is clear.
          </p>
        </div>
      </div>

    </Shell>
  );
}
