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
    <main className="min-h-screen bg-[#13141a] text-zinc-100 selection:bg-emerald-500/20">
      {/* Background */}
      <div className="fixed inset-0 -z-10 pointer-events-none">
        <div className="absolute top-0 left-1/3 w-[600px] h-[600px] bg-emerald-500/[0.03] rounded-full blur-[150px]" />
        <div className="absolute bottom-0 right-1/4 w-[500px] h-[500px] bg-cyan-500/[0.02] rounded-full blur-[130px]" />
        <div className="absolute inset-0 bg-[linear-gradient(rgba(255,255,255,.008)_1px,transparent_1px),linear-gradient(90deg,rgba(255,255,255,.008)_1px,transparent_1px)] bg-[size:72px_72px]" />
      </div>

      <div className="max-w-6xl mx-auto px-6 py-6">
        {/* Header */}
        <header className="flex items-center justify-between mb-6">
          <Link href="/" className="flex items-center gap-3 group">
            <div className="w-9 h-9 rounded-xl bg-gradient-to-br from-emerald-500/20 to-cyan-500/10 border border-emerald-500/20 flex items-center justify-center group-hover:border-emerald-500/40 transition-colors">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="text-emerald-400">
                <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />
              </svg>
            </div>
            <div>
              <h1 className="text-xl font-semibold tracking-tight" style={{ fontFamily: "'Outfit', sans-serif" }}>
                Peg<span className="text-emerald-400">Sentinel</span>
              </h1>
              <p className="text-[10px] text-zinc-500 tracking-wide">
                Uniswap V4 Hook · Stablecoin Peg Defense
              </p>
            </div>
          </Link>

          <div className="flex items-center gap-4">
            {/* Nav tabs */}
            <nav className="flex items-center bg-[#1e2028] rounded-xl border border-[#333444] p-1">
              {NAV_ITEMS.map((item) => {
                const active = pathname === item.href;
                return (
                  <Link
                    key={item.href}
                    href={item.href}
                    className={`flex items-center gap-1.5 px-4 py-2 rounded-lg text-xs font-medium transition-all ${
                      active
                        ? "bg-emerald-500/10 text-emerald-400 border border-emerald-500/20"
                        : "text-zinc-500 hover:text-zinc-300 border border-transparent"
                    }`}
                  >
                    <span className="text-sm">{item.icon}</span>
                    {item.label}
                  </Link>
                );
              })}
            </nav>

            {/* Status */}
            <div className="flex items-center gap-2">
              <div className={`w-1.5 h-1.5 rounded-full ${loading ? "bg-amber-400" : "bg-emerald-400"} animate-pulse`} />
              <span className="text-[11px] text-zinc-500">{loading ? "Syncing..." : "Live"}</span>
            </div>
          </div>
        </header>

        {/* Error */}
        {error && (
          <div className="mb-6 p-4 rounded-xl bg-red-500/[0.06] border border-red-500/20">
            <div className="text-sm font-medium text-red-400">Connection Error</div>
            <div className="text-xs text-red-400/60 mt-1">{error}</div>
          </div>
        )}

        {/* Page content */}
        {children}

        {/* Footer */}
        <footer className="mt-10 pt-6 border-t border-[#333444]/40 flex items-center justify-between text-[11px] text-zinc-500">
          <span>PegSentinel · Uniswap V4 Hook · Built for UHI8 Hackathon</span>
        </footer>
      </div>
    </main>
  );
}
