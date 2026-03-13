"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const NAV_ITEMS = [
  { href: "/", label: "Overview", icon: "◎" },
  { href: "/swap", label: "Swap", icon: "⇄" },
  { href: "/liquidity", label: "Liquidity", icon: "◈" },
];

export function Shell({
  children,
  loading = false,
  error,
}: {
  children: React.ReactNode;
  loading?: boolean;
  error?: string | null;
}) {
  const pathname = usePathname();

  return (
    <main className="min-h-screen bg-[var(--bg)] text-zinc-100 selection:bg-emerald-500/20">
      {/* Background */}
      <div className="fixed inset-0 -z-10 pointer-events-none">
        <div className="absolute top-0 left-1/3 w-[600px] h-[600px] bg-emerald-500/[0.03] rounded-full blur-[150px]" />
        <div className="absolute bottom-0 right-1/4 w-[500px] h-[500px] bg-cyan-500/[0.02] rounded-full blur-[130px]" />
        <div className="absolute inset-0 bg-[linear-gradient(rgba(255,255,255,.008)_1px,transparent_1px),linear-gradient(90deg,rgba(255,255,255,.008)_1px,transparent_1px)] bg-[size:72px_72px]" />
      </div>

      {/* Top header — logo + live indicator */}
      <header className="border-b border-[var(--border)] bg-[var(--card)]/60 backdrop-blur-sm">
        <div className="max-w-[1280px] mx-auto px-6 h-14 flex items-center justify-between">
          <Link href="/" className="flex items-center gap-3 group">
            <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-emerald-500/20 to-cyan-500/10 border border-emerald-500/20 flex items-center justify-center group-hover:border-emerald-500/40 transition-colors">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="text-emerald-400">
                <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />
              </svg>
            </div>
            <div>
              <h1 className="text-base font-semibold tracking-tight leading-none" style={{ fontFamily: "'Outfit', sans-serif" }}>
                Peg<span className="text-emerald-400">Sentinel</span>
              </h1>
              <p className="text-xs text-zinc-500 tracking-wide mt-0.5">
                Uniswap V4 Hook · Stablecoin Peg Defense
              </p>
            </div>
          </Link>

          {/* Live status */}
          <div className="flex items-center gap-2 px-3 py-1.5 bg-[var(--inner)] rounded-full border border-[var(--border)]">
            <div className={`w-1.5 h-1.5 rounded-full ${loading ? "bg-amber-400" : "bg-emerald-400"} animate-pulse`} />
            <span className="text-xs text-zinc-400">{loading ? "Syncing..." : "Live"}</span>
            <span className="text-xs text-zinc-600">·</span>
            <span className="text-xs text-zinc-500 font-mono">Arbitrum Sepolia</span>
          </div>
        </div>
      </header>

      {/* Nav row — full width tabs below header */}
      <nav className="border-b border-[var(--border)] bg-[var(--card)]/40">
        <div className="max-w-[1280px] mx-auto px-6 flex gap-0">
          {NAV_ITEMS.map((item) => {
            const active = pathname === item.href;
            return (
              <Link
                key={item.href}
                href={item.href}
                className={`flex items-center gap-2 px-5 py-3.5 text-sm font-medium border-b-2 transition-all ${
                  active
                    ? "border-emerald-400 text-emerald-400"
                    : "border-transparent text-zinc-500 hover:text-zinc-200 hover:border-zinc-600"
                }`}
              >
                <span>{item.icon}</span>
                {item.label}
              </Link>
            );
          })}
        </div>
      </nav>

      {/* Page content */}
      <div className="max-w-[1280px] mx-auto px-6 py-6">
        {/* Error */}
        {error && (
          <div className="mb-6 p-4 rounded-xl bg-red-500/[0.06] border border-red-500/20">
            <div className="text-sm font-medium text-red-400">Connection Error</div>
            <div className="text-xs text-red-400/60 mt-1">{error}</div>
          </div>
        )}

        {children}

        {/* Footer */}
        <footer className="mt-10 pt-6 border-t border-[var(--border)]/40 flex items-center justify-between text-xs text-zinc-600">
          <span>PegSentinel · Uniswap V4 Hook · Built for UHI8 Hackathon</span>
          <span className="font-mono">Arbitrum Sepolia</span>
        </footer>
      </div>
    </main>
  );
}
