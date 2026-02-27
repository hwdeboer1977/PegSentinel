"use client";

import {
  usePegSentinel, Card, SectionLabel, DataRow, RangeViz,
  formatBalance, tickToPrice,
} from "../lib/shared";
import { Shell } from "../lib/Shell";

export default function LiquidityPage() {
  const ps = usePegSentinel();

  return (
    <Shell loading={ps.loading} error={ps.error}>
      {/* Compact peg status */}
      <div className="flex items-center justify-between mb-6 px-1">
        <div className="flex items-center gap-4">
          <div className="text-3xl font-mono font-extralight text-zinc-50 tracking-tighter">
            ${ps.currentPrice.toFixed(4)}
          </div>
          <span className={`text-sm font-mono ${
            Math.abs(ps.deviationBps) < 25 ? "text-emerald-400" : Math.abs(ps.deviationBps) < 100 ? "text-amber-400" : "text-red-400"
          }`}>
            {ps.deviationBps >= 0 ? "+" : ""}{(ps.deviationBps / 100).toFixed(2)}%
          </span>
        </div>
        <div className="text-xs text-zinc-500 font-mono">
          Regime: <span className={ps.regime === 0 ? "text-emerald-400" : "text-amber-400"}>{ps.regimeName}</span>
        </div>
      </div>

      {/* Vault Reserves */}
      <Card>
        <SectionLabel color="text-amber-400/70">Vault Reserves</SectionLabel>
        {ps.balances ? (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            {[
              { sym: ps.symbol0, bal: ps.balances.bal0, dec: ps.decimals0 },
              { sym: ps.symbol1, bal: ps.balances.bal1, dec: ps.decimals1 },
            ].map((t) => (
              <div key={t.sym} className="flex items-center justify-between p-4 bg-[var(--inner)] rounded-xl border border-[var(--border)]">
                <div className="flex items-center gap-3">
                  <div className="w-8 h-8 rounded-full bg-gradient-to-br from-zinc-600 to-zinc-700 flex items-center justify-center text-[10px] font-bold text-zinc-200 border border-zinc-600">
                    {t.sym.charAt(0)}
                  </div>
                  <span className="text-sm text-zinc-400">{t.sym}</span>
                </div>
                <span className="text-xl font-mono text-zinc-100 tabular-nums">{formatBalance(t.bal, t.dec)}</span>
              </div>
            ))}
          </div>
        ) : (
          <div className="text-zinc-500 text-sm">Vault not configured</div>
        )}
        <p className="text-[11px] text-zinc-500 mt-4">
          Protocol-owned liquidity ready to defend the peg
        </p>
      </Card>

      {/* LP Position */}
      <Card className="mt-5">
        <SectionLabel color="text-violet-400/70">Layer 2 · Liquidity Position</SectionLabel>
        {ps.position ? (
          <div className="space-y-5">
            {/* Range viz */}
            <RangeViz
              currentTick={ps.currentTick}
              tickLower={ps.position.tickLower}
              tickUpper={ps.position.tickUpper}
              regime={ps.regimeName}
            />

            {/* Stats grid */}
            {ps.lpPosition ? (
              <>
                <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                  <div className="p-4 rounded-xl bg-violet-500/[0.05] border border-violet-500/15">
                    <div className="text-[10px] text-violet-400/70 uppercase tracking-wider mb-1.5">Token ID</div>
                    <div className="text-lg font-mono text-zinc-100">#{ps.lpPosition.tokenId}</div>
                  </div>
                  <div className="p-4 rounded-xl bg-[var(--inner)] border border-[var(--border)]">
                    <div className="text-[10px] text-zinc-500 uppercase tracking-wider mb-1.5">Liquidity</div>
                    <div className="text-lg font-mono text-zinc-100">{BigInt(ps.lpPosition.liquidity).toLocaleString()}</div>
                  </div>
                  <div className="p-4 rounded-xl bg-emerald-500/[0.04] border border-emerald-500/15">
                    <div className="text-[10px] text-emerald-400/70 uppercase tracking-wider mb-1.5">{ps.symbol0}</div>
                    <div className="text-lg font-mono text-zinc-100">{formatBalance(BigInt(ps.lpPosition.amount0), ps.decimals0)}</div>
                  </div>
                  <div className="p-4 rounded-xl bg-emerald-500/[0.04] border border-emerald-500/15">
                    <div className="text-[10px] text-emerald-400/70 uppercase tracking-wider mb-1.5">{ps.symbol1}</div>
                    <div className="text-lg font-mono text-zinc-100">{formatBalance(BigInt(ps.lpPosition.amount1), ps.decimals1)}</div>
                  </div>
                </div>

                <div className="grid grid-cols-2 md:grid-cols-4 gap-x-6 gap-y-1 pt-3 border-t border-[var(--border)]/60">
                  <DataRow label="Tick Range" value={`${ps.lpPosition.tickLower} → ${ps.lpPosition.tickUpper}`} />
                  <DataRow label="Price Range" value={`$${tickToPrice(ps.lpPosition.tickLower).toFixed(4)} – $${tickToPrice(ps.lpPosition.tickUpper).toFixed(4)}`} />
                  <DataRow label="Owner" value={`${ps.lpPosition.owner.slice(0, 6)}…${ps.lpPosition.owner.slice(-4)}`} />
                  <DataRow label="Status" value={
                    <span className={ps.currentTick >= ps.lpPosition.tickLower && ps.currentTick <= ps.lpPosition.tickUpper ? "text-emerald-400" : "text-red-400"}>
                      {ps.currentTick >= ps.lpPosition.tickLower && ps.currentTick <= ps.lpPosition.tickUpper ? "● In Range" : "○ Out of Range"}
                    </span>
                  } />
                </div>
              </>
            ) : (
              <div className="text-sm text-zinc-500">
                {ps.position.tokenId ? "Loading LP details…" : "No LP position configured."}
              </div>
            )}
          </div>
        ) : (
          <div className="text-zinc-500 text-sm">No active position</div>
        )}
      </Card>

      {/* Buffer Position */}
      {ps.bufferActive && (
        <Card className="mt-5">
          <SectionLabel color="text-amber-400/70">🛡 Buffer Position</SectionLabel>
          {ps.bufferPosition ? (
            <div className="space-y-5">
              {/* Buffer range viz */}
              <RangeViz
                currentTick={ps.currentTick}
                tickLower={ps.bufferPosition.tickLower}
                tickUpper={ps.bufferPosition.tickUpper}
                regime={ps.regimeName}
              />

              {/* Stats grid */}
              <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                <div className="p-4 rounded-xl bg-amber-500/[0.05] border border-amber-500/15">
                  <div className="text-[10px] text-amber-400/70 uppercase tracking-wider mb-1.5">Token ID</div>
                  <div className="text-lg font-mono text-zinc-100">#{ps.bufferPosition.tokenId}</div>
                </div>
                <div className="p-4 rounded-xl bg-[var(--inner)] border border-[var(--border)]">
                  <div className="text-[10px] text-zinc-500 uppercase tracking-wider mb-1.5">Liquidity</div>
                  <div className="text-lg font-mono text-zinc-100">{BigInt(ps.bufferPosition.liquidity).toLocaleString()}</div>
                </div>
                <div className="p-4 rounded-xl bg-emerald-500/[0.04] border border-emerald-500/15">
                  <div className="text-[10px] text-emerald-400/70 uppercase tracking-wider mb-1.5">{ps.symbol0}</div>
                  <div className="text-lg font-mono text-zinc-100">{formatBalance(BigInt(ps.bufferPosition.amount0), ps.decimals0)}</div>
                </div>
                <div className="p-4 rounded-xl bg-emerald-500/[0.04] border border-emerald-500/15">
                  <div className="text-[10px] text-emerald-400/70 uppercase tracking-wider mb-1.5">{ps.symbol1}</div>
                  <div className="text-lg font-mono text-zinc-100">{formatBalance(BigInt(ps.bufferPosition.amount1), ps.decimals1)}</div>
                </div>
              </div>

              <div className="grid grid-cols-2 md:grid-cols-4 gap-x-6 gap-y-1 pt-3 border-t border-[var(--border)]/60">
                <DataRow label="Tick Range" value={`${ps.bufferPosition.tickLower} → ${ps.bufferPosition.tickUpper}`} />
                <DataRow label="Price Range" value={`$${tickToPrice(ps.bufferPosition.tickLower).toFixed(4)} – $${tickToPrice(ps.bufferPosition.tickUpper).toFixed(4)}`} />
                <DataRow label="Owner" value={`${ps.bufferPosition.owner.slice(0, 6)}…${ps.bufferPosition.owner.slice(-4)}`} />
                <DataRow label="Status" value={
                  <span className={ps.currentTick >= ps.bufferPosition.tickLower && ps.currentTick <= ps.bufferPosition.tickUpper ? "text-emerald-400" : "text-red-400"}>
                    {ps.currentTick >= ps.bufferPosition.tickLower && ps.currentTick <= ps.bufferPosition.tickUpper ? "● In Range" : "○ Out of Range"}
                  </span>
                } />
              </div>
            </div>
          ) : (
            <div className="text-sm text-zinc-500">Loading buffer details…</div>
          )}
        </Card>
      )}

      {/* Rebalance Control */}
      <Card className="mt-5">
        <SectionLabel color={ps.needsRebalance ? "text-rose-400/70" : "text-violet-400/70"}>
          Rebalance Control
        </SectionLabel>
        <div className="space-y-4">
          {/* Status banner */}
          <div className={`p-4 rounded-xl border ${
            ps.needsRebalance ? "bg-rose-500/[0.04] border-rose-500/15" : "bg-emerald-500/[0.04] border-emerald-500/15"
          }`}>
            <div className="flex items-center justify-between">
              <div>
                <div className={`text-sm font-medium ${ps.needsRebalance ? "text-rose-400" : "text-emerald-400"}`}>
                  {ps.needsRebalance ? "⚠ Rebalance Needed" : "✓ Position Optimal"}
                </div>
                <div className="text-[11px] text-zinc-500 mt-1 font-mono">
                  Tick {ps.currentTick} · Range {ps.position?.tickLower ?? "—"} to {ps.position?.tickUpper ?? "—"}
                </div>
              </div>
              <div className={`text-2xl font-mono font-light ${
                Math.abs(ps.deviationBps) > 100 ? "text-rose-400" : Math.abs(ps.deviationBps) > 50 ? "text-amber-400" : "text-emerald-400"
              }`}>
                {ps.deviationBps >= 0 ? "+" : ""}{(ps.deviationBps / 100).toFixed(2)}%
              </div>
            </div>
          </div>

          {/* Current vs Target */}
          <div className="grid grid-cols-2 gap-3">
            <div className="p-4 rounded-xl bg-[var(--inner)] border border-[var(--border)]">
              <div className="text-[10px] text-zinc-500 uppercase tracking-wider mb-2">Current</div>
              <div className={`text-base font-semibold ${ps.regime === 0 ? "text-emerald-400" : "text-amber-400"}`}>
                {ps.regimeName}
              </div>
              {ps.position && (
                <div className="text-[11px] text-zinc-500 mt-1 font-mono">
                  {ps.position.tickLower} → {ps.position.tickUpper}
                </div>
              )}
              {ps.bufferActive && (
                <div className="text-[11px] text-amber-400/70 mt-1">🛡 Buffer active</div>
              )}
            </div>
            <div className={`p-4 rounded-xl border ${
              ps.needsRebalance ? "bg-amber-500/[0.04] border-amber-500/15" : "bg-emerald-500/[0.04] border-emerald-500/15"
            }`}>
              <div className="text-[10px] text-zinc-500 uppercase tracking-wider mb-2">
                {ps.needsRebalance ? "Target" : "Target ✓"}
              </div>
              <div className={`text-base font-semibold ${ps.targetRegime === 0 ? "text-emerald-400" : "text-amber-400"}`}>
                {ps.targetRegime === 0 ? "Normal" : "Defend"}
              </div>
              {ps.targetRange && (
                <div className="text-[11px] text-zinc-500 mt-1 font-mono">
                  {ps.targetRange.tickLower} → {ps.targetRange.tickUpper}
                </div>
              )}
            </div>
          </div>

          {/* Advanced config (collapsible) */}
          {ps.rangeConfigs && (
            <div>
              <button
                onClick={() => ps.setAdvancedOpen(!ps.advancedOpen)}
                className="text-[11px] text-zinc-500 hover:text-zinc-400 transition-colors flex items-center gap-1"
              >
                <span className={`transition-transform duration-200 inline-block ${ps.advancedOpen ? "rotate-90" : ""}`}>▶</span>
                Advanced Configuration
              </button>
              {ps.advancedOpen && (
                <div className="mt-3 p-3.5 rounded-xl bg-[var(--inner)] border border-[var(--border)] space-y-3">
                  <div className="grid grid-cols-2 gap-2">
                    <div className={`p-2.5 rounded-lg border text-[11px] ${ps.regime === 0 ? "bg-emerald-500/[0.05] border-emerald-500/15" : "bg-[var(--card)] border-[var(--border)]"}`}>
                      <div className="font-medium text-emerald-400/70 mb-1">LP Range</div>
                      <div className="text-zinc-400 font-mono">{ps.rangeConfigs.lp.tickLower} → {ps.rangeConfigs.lp.tickUpper}</div>
                      <div className="text-zinc-500 font-mono">${tickToPrice(ps.rangeConfigs.lp.tickLower).toFixed(4)} – ${tickToPrice(ps.rangeConfigs.lp.tickUpper).toFixed(4)}</div>
                    </div>
                    <div className={`p-2.5 rounded-lg border text-[11px] ${ps.bufferActive ? "bg-amber-500/[0.05] border-amber-500/15" : "bg-[var(--card)] border-[var(--border)]"}`}>
                      <div className="font-medium text-amber-400/70 mb-1">Buffer Range</div>
                      <div className="text-zinc-400 font-mono">{ps.rangeConfigs.buffer.tickLower} → {ps.rangeConfigs.buffer.tickUpper}</div>
                      <div className="text-zinc-500 font-mono">${tickToPrice(ps.rangeConfigs.buffer.tickLower).toFixed(4)} – ${tickToPrice(ps.rangeConfigs.buffer.tickUpper).toFixed(4)}</div>
                    </div>
                  </div>
                  <div className="text-[11px] text-zinc-500 font-mono">
                    Thresholds: defend ≤ {ps.rangeConfigs.defendThreshold} · recover ≥ {ps.rangeConfigs.recoverThreshold}
                  </div>
                </div>
              )}
            </div>
          )}

          {/* Rebalance button */}
          {ps.walletConnected ? (
            <button
              onClick={ps.executeRebalance}
              disabled={ps.rebalanceLoading || !ps.needsRebalance}
              className={`w-full py-3.5 rounded-xl font-semibold text-sm transition-all ${
                ps.rebalanceLoading || !ps.needsRebalance
                  ? "bg-[var(--card)] text-zinc-500 cursor-not-allowed border border-[var(--border)]"
                  : "bg-gradient-to-r from-rose-500 to-amber-500 text-[var(--bg)] hover:from-rose-400 hover:to-amber-400 shadow-lg shadow-rose-500/10"
              }`}
            >
              {ps.rebalanceLoading ? "Updating…" : ps.needsRebalance
                ? `⟲ ${ps.targetRegime === 1 ? "Deploy Buffer (Defend)" : "Remove Buffer (Normal)"}`
                : "✓ No Rebalance Needed"}
            </button>
          ) : (
            <button onClick={ps.connectWallet}
              className="w-full py-3.5 rounded-xl font-semibold text-sm bg-gradient-to-r from-violet-500 to-cyan-500 text-[var(--bg)] hover:from-violet-400 hover:to-cyan-400 transition-all shadow-lg shadow-violet-500/10">
              Connect Wallet to Rebalance
            </button>
          )}

          {ps.rebalanceTxHash && (
            <div className="text-center">
              <a href={`https://sepolia.arbiscan.io/tx/${ps.rebalanceTxHash}`} target="_blank" rel="noopener noreferrer"
                className="text-xs text-violet-400 hover:text-violet-300 transition-colors">
                View on Arbiscan →
              </a>
            </div>
          )}

          <div className="text-[11px] text-zinc-500 pt-2 border-t border-[var(--border)]/60">
            Regime updates via UI · Full liquidity repositioning requires the keeper script
          </div>
        </div>
      </Card>
    </Shell>
  );
}
