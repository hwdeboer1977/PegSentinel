"use client";

import { usePegSentinel, Card, SectionLabel, FeeCard, PegHero, formatFee } from "../lib/shared";
import { Shell } from "../lib/Shell";

export default function SwapPage() {
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
        <div className="text-xs text-zinc-500 font-mono">Tick {ps.currentTick}</div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-5">
        {/* Left: Swap Interface */}
        <Card>
          <SectionLabel color="text-cyan-400/70">Swap</SectionLabel>
          <div className="space-y-4">
            {!ps.walletConnected ? (
              <button onClick={ps.connectWallet}
                className="w-full py-3.5 rounded-xl font-semibold text-sm bg-gradient-to-r from-cyan-500 to-emerald-500 text-[var(--bg)] hover:from-cyan-400 hover:to-emerald-400 transition-all shadow-lg shadow-cyan-500/10">
                Connect Wallet
              </button>
            ) : (
              <div className="text-xs text-zinc-500 font-mono bg-[var(--inner)] rounded-lg px-3 py-2 border border-[var(--border)]">
                Connected: {ps.walletAddress?.slice(0, 6)}…{ps.walletAddress?.slice(-4)}
              </div>
            )}

            {ps.walletConnected && (
              <>
                {/* Direction toggle */}
                <div className="grid grid-cols-2 gap-2">
                  {(["0to1", "1to0"] as const).map((dir) => (
                    <button key={dir} onClick={() => ps.setSwapDirection(dir)}
                      className={`py-2.5 rounded-xl text-xs font-semibold transition-all border ${
                        ps.swapDirection === dir
                          ? "bg-cyan-500/10 border-cyan-500/30 text-cyan-400"
                          : "bg-[var(--inner)] border-[var(--border)] text-zinc-500 hover:border-zinc-600"
                      }`}>
                      {dir === "0to1" ? `${ps.symbol0} → ${ps.symbol1}` : `${ps.symbol1} → ${ps.symbol0}`}
                    </button>
                  ))}
                </div>

                {/* Amount input */}
                <div>
                  <label className="text-[11px] text-zinc-500 mb-1.5 block">
                    Amount ({ps.swapDirection === "0to1" ? ps.symbol0 : ps.symbol1})
                  </label>
                  <input
                    type="number"
                    value={ps.swapAmount}
                    onChange={(e) => ps.setSwapAmount(e.target.value)}
                    placeholder="0.0"
                    className="w-full px-4 py-3.5 bg-[var(--inner)] border border-[var(--border)] rounded-xl text-lg font-mono text-zinc-100 placeholder-zinc-700 focus:outline-none focus:border-cyan-500/40 focus:ring-1 focus:ring-cyan-500/20 transition-all"
                  />
                </div>

                {/* Fee preview */}
                <div className="bg-[var(--inner)] rounded-xl p-3.5 border border-[var(--border)] space-y-2">
                  <div className="flex justify-between text-xs">
                    <span className="text-zinc-500">Expected Fee</span>
                    <span className="font-mono text-zinc-200">
                      {ps.swapDirection === "0to1"
                        ? (ps.fee0to1 ? formatFee(ps.fee0to1.fee) : "—")
                        : (ps.fee1to0 ? formatFee(ps.fee1to0.fee) : "—")}
                    </span>
                  </div>
                  <div className="flex justify-between text-xs">
                    <span className="text-zinc-500">Direction</span>
                    <span className={`font-medium ${
                      (ps.swapDirection === "0to1" ? ps.fee0to1?.toward : ps.fee1to0?.toward)
                        ? "text-emerald-400" : "text-amber-400"
                    }`}>
                      {(ps.swapDirection === "0to1" ? ps.fee0to1?.toward : ps.fee1to0?.toward)
                        ? "TOWARD PEG" : "AWAY FROM PEG"}
                    </span>
                  </div>
                </div>

                {/* Swap button */}
                <button
                  onClick={ps.executeSwap}
                  disabled={ps.swapLoading || !ps.swapAmount}
                  className={`w-full py-3.5 rounded-xl font-semibold text-sm transition-all ${
                    ps.swapLoading || !ps.swapAmount
                      ? "bg-[var(--card)] text-zinc-500 cursor-not-allowed border border-[var(--border)]"
                      : "bg-gradient-to-r from-cyan-500 to-emerald-500 text-[var(--bg)] hover:from-cyan-400 hover:to-emerald-400 shadow-lg shadow-cyan-500/10"
                  }`}
                >
                  {ps.swapLoading ? "Swapping..." : "Execute Swap"}
                </button>

                {ps.swapTxHash && (
                  <div className="text-center">
                    <a
                      href={`https://sepolia.arbiscan.io/tx/${ps.swapTxHash}`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-xs text-cyan-400 hover:text-cyan-300 transition-colors"
                    >
                      View on Arbiscan →
                    </a>
                  </div>
                )}
              </>
            )}
          </div>
        </Card>

        {/* Right: Dynamic Fee Overview */}
        <div className="space-y-5">
          <Card>
            <SectionLabel color="text-cyan-400/70">Layer 1 · Dynamic Fees</SectionLabel>
            {ps.fee0to1 && ps.fee1to0 ? (
              <div className="space-y-3">
                <FeeCard fee={ps.fee0to1.fee} toward={ps.fee0to1.toward} symbol0={ps.symbol0} symbol1={ps.symbol1} zeroForOne={true} />
                <FeeCard fee={ps.fee1to0.fee} toward={ps.fee1to0.toward} symbol0={ps.symbol0} symbol1={ps.symbol1} zeroForOne={false} />
              </div>
            ) : (
              <div className="text-zinc-500 text-sm">Fee preview not available</div>
            )}
            <p className="text-[11px] text-zinc-500 mt-4">
              Lower fees encourage swaps toward $1.00 peg, higher fees discourage swaps away
            </p>
          </Card>

          {/* How it works */}
          <Card>
            <SectionLabel color="text-zinc-500">How Dynamic Fees Work</SectionLabel>
            <div className="space-y-3 text-xs text-zinc-400 leading-relaxed">
              <p>
                The PegSentinel hook intercepts every swap and adjusts the fee in real-time based on the current price deviation from the $1.00 peg.
              </p>
              <div className="grid grid-cols-2 gap-3 py-1">
                <div className="p-3 rounded-lg bg-emerald-500/[0.04] border border-emerald-500/15">
                  <div className="text-[10px] text-emerald-400/70 uppercase tracking-wider mb-1">Toward Peg</div>
                  <div className="text-zinc-300">Lower fees incentivize arbitrageurs to restore the peg</div>
                </div>
                <div className="p-3 rounded-lg bg-rose-500/[0.04] border border-rose-500/15">
                  <div className="text-[10px] text-rose-400/70 uppercase tracking-wider mb-1">Away from Peg</div>
                  <div className="text-zinc-300">Higher fees penalize trades that push the price further off-peg</div>
                </div>
              </div>
              <p className="text-zinc-500">
                This asymmetric fee model creates a self-correcting mechanism — the greater the deviation, the stronger the incentive to restore equilibrium.
              </p>
            </div>
          </Card>
        </div>
      </div>
    </Shell>
  );
}
