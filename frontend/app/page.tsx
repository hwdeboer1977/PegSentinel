"use client";

import { usePegSentinel, PegHero, Card, SectionLabel, RegimeBadge, DataRow, formatBalance, tickToPrice } from "./lib/shared";
import { Shell } from "./lib/Shell";

export default function OverviewPage() {
  const ps = usePegSentinel();

  return (
    <Shell loading={ps.loading} error={ps.error}>
      {/* Hero: Peg Price */}
      <PegHero
        price={ps.currentPrice}
        deviation={ps.deviationBps}
        regime={ps.regimeName}
        regimeStatus={ps.regimeStatus}
        currentTick={ps.currentTick}
      />

      {/* Introduction */}
      <Card className="mt-2">
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
          {/* Left: What is PegSentinel */}
          <div className="space-y-4">
            <h2 className="text-lg font-semibold text-zinc-100" style={{ fontFamily: "'Outfit', sans-serif" }}>
              Autonomous Peg Defense
            </h2>
            <p className="text-sm text-zinc-400 leading-relaxed">
              PegSentinel is a Uniswap V4 Hook that actively defends stablecoin pegs through two coordinated layers of protection — keeping prices stable even during market stress.
            </p>
            <div className="space-y-3 pt-2">
              <div className="flex items-start gap-3">
                <div className="w-8 h-8 rounded-lg bg-cyan-500/10 border border-cyan-500/20 flex items-center justify-center text-cyan-400 text-sm flex-shrink-0 mt-0.5">
                  ⇄
                </div>
                <div>
                  <div className="text-sm font-medium text-zinc-200">Layer 1 · Dynamic Fees</div>
                  <p className="text-xs text-zinc-500 mt-0.5">
                    Swap fees adjust in real-time based on price deviation. Swaps that restore the peg pay less, swaps that push away pay more — creating natural economic incentives to maintain stability.
                  </p>
                </div>
              </div>
              <div className="flex items-start gap-3">
                <div className="w-8 h-8 rounded-lg bg-violet-500/10 border border-violet-500/20 flex items-center justify-center text-violet-400 text-sm flex-shrink-0 mt-0.5">
                  ◈
                </div>
                <div>
                  <div className="text-sm font-medium text-zinc-200">Layer 2 · Active Liquidity</div>
                  <p className="text-xs text-zinc-500 mt-0.5">
                    When price deviates beyond thresholds, the vault automatically deploys buffer liquidity to create a buy wall — actively defending the peg with protocol-owned reserves.
                  </p>
                </div>
              </div>
            </div>
          </div>

          {/* Right: Live system status */}
          <div className="space-y-4">
            <SectionLabel color="text-emerald-400/70">System Status</SectionLabel>

            <div className="space-y-2">
              <div className="flex items-center justify-between p-3.5 bg-[var(--inner)] rounded-xl border border-[var(--border)]">
                <span className="text-xs text-zinc-500">Active Regime</span>
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
                      <span className={
                        ps.currentTick >= ps.position.tickLower && ps.currentTick <= ps.position.tickUpper
                          ? "text-emerald-400" : "text-red-400"
                      }>
                        {ps.currentTick >= ps.position.tickLower && ps.currentTick <= ps.position.tickUpper
                          ? "● In Range" : "○ Out of Range"}
                      </span>
                    }
                  />
                </>
              )}

              {ps.bufferActive && (
                <DataRow label="Buffer" value={<span className="text-amber-400">🛡 Active</span>} />
              )}
            </div>

            {/* Vault summary */}
            {ps.balances && (
              <div className="pt-3 border-t border-[var(--border)]/60">
                <div className="text-[10px] text-zinc-500 uppercase tracking-wider mb-2">Vault Reserves</div>
                <div className="grid grid-cols-2 gap-2">
                  <div className="p-3 bg-[var(--inner)] rounded-lg border border-[var(--border)] text-center">
                    <div className="text-[10px] text-zinc-500 mb-1">{ps.symbol0}</div>
                    <div className="text-sm font-mono text-zinc-100">{formatBalance(ps.balances.bal0, ps.decimals0)}</div>
                  </div>
                  <div className="p-3 bg-[var(--inner)] rounded-lg border border-[var(--border)] text-center">
                    <div className="text-[10px] text-zinc-500 mb-1">{ps.symbol1}</div>
                    <div className="text-sm font-mono text-zinc-100">{formatBalance(ps.balances.bal1, ps.decimals1)}</div>
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>
      </Card>

      {/* Defense status banner */}
      {ps.needsRebalance && (
        <div className="mt-5 p-4 rounded-xl bg-amber-500/[0.06] border border-amber-500/20 flex items-center justify-between">
          <div>
            <div className="text-sm font-medium text-amber-400">⚠ Rebalance Action Required</div>
            <div className="text-xs text-zinc-500 mt-1">
              The system has detected a peg deviation that requires a regime change.
              Visit the <a href="/liquidity" className="text-violet-400 hover:text-violet-300 underline">Liquidity</a> page to execute.
            </div>
          </div>
          <div className={`text-2xl font-mono font-light ${
            Math.abs(ps.deviationBps) > 100 ? "text-rose-400" : "text-amber-400"
          }`}>
            {ps.deviationBps >= 0 ? "+" : ""}{(ps.deviationBps / 100).toFixed(2)}%
          </div>
        </div>
      )}
    </Shell>
  );
}
