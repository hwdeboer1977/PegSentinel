"use client";

import { useEffect, useMemo, useState } from "react";
import { Contract } from "ethers";
import { getProvider } from "./lib/provider";
import { ADDR, isZeroAddress } from "./lib/addresses";
import { formatBps } from "./lib/format";

// Minimal ABIs (adjust later to match your contracts)
const VaultABI = [
  "function currentRegime() view returns (uint8)",
  "function tokenId() view returns (uint256)",
  "function tickLower() view returns (int24)",
  "function tickUpper() view returns (int24)",
];

const PoolABI = [
  // Uniswap v3-like pool
  "function slot0() view returns (uint160 sqrtPriceX96,int24 tick,uint16,uint16,uint16,uint8,bool)",
];

type Status = "ok" | "warn" | "bad" | "na";

function regimeMeta(regime: number): { label: string; status: Status } {
  if (regime === 0) return { label: "Normal", status: "ok" };
  if (regime === 1) return { label: "Mild", status: "warn" };
  if (regime === 2) return { label: "Severe", status: "bad" };
  return { label: `Unknown (${regime})`, status: "na" };
}

function badgeClass(status: Status) {
  switch (status) {
    case "ok":
      return "bg-green-100 text-green-800 border-green-200";
    case "warn":
      return "bg-yellow-100 text-yellow-800 border-yellow-200";
    case "bad":
      return "bg-red-100 text-red-800 border-red-200";
    default:
      return "bg-gray-100 text-gray-700 border-gray-200";
  }
}

export default function Page() {
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  const [regime, setRegime] = useState<number | null>(null);
  const [tokenId, setTokenId] = useState<string | null>(null);
  const [tickLower, setTickLower] = useState<number | null>(null);
  const [tickUpper, setTickUpper] = useState<number | null>(null);

  const [poolTick, setPoolTick] = useState<number | null>(null);

  // TEMP signal: tick=0 ~ peg; shows direction/magnitude roughly.
  const deviationBps = useMemo(() => {
    if (poolTick === null) return null;
    return poolTick * 1.0;
  }, [poolTick]);

  const meta = useMemo(() => (regime === null ? null : regimeMeta(regime)), [regime]);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setLoading(true);
      setErr(null);

      try {
        const provider = getProvider();

        // VAULT
        if (!isZeroAddress(ADDR.vault)) {
          const vault = new Contract(ADDR.vault, VaultABI, provider);
          const [r, id, lo, hi] = await Promise.all([
            vault.currentRegime(),
            vault.tokenId(),
            vault.tickLower(),
            vault.tickUpper(),
          ]);

          if (!cancelled) {
            setRegime(Number(r));
            setTokenId(id.toString());
            setTickLower(Number(lo));
            setTickUpper(Number(hi));
          }
        } else if (!cancelled) {
          setRegime(null);
          setTokenId(null);
          setTickLower(null);
          setTickUpper(null);
        }

        // POOL
        if (!isZeroAddress(ADDR.pool)) {
          const pool = new Contract(ADDR.pool, PoolABI, provider);
          const slot0 = await pool.slot0();
          if (!cancelled) setPoolTick(Number(slot0[1]));
        } else if (!cancelled) {
          setPoolTick(null);
        }
      } catch (e: any) {
        if (!cancelled) setErr(e?.message || String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    load();
    const t = setInterval(load, 30_000);
    return () => {
      cancelled = true;
      clearInterval(t);
    };
  }, []);

  return (
    <main className="min-h-screen p-6 bg-white">
      <div className="max-w-5xl mx-auto space-y-6">
        <header className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-semibold">PegSentinel Dashboard</h1>
            <p className="text-sm text-gray-600">
              RPC: {process.env.NEXT_PUBLIC_RPC_URL || "not set"}
            </p>
          </div>

          {meta ? (
            <span className={`px-3 py-1 rounded-full border text-sm ${badgeClass(meta.status)}`}>
              Regime: {meta.label}
            </span>
          ) : (
            <span className="px-3 py-1 rounded-full border text-sm bg-gray-50 text-gray-600">
              Regime: not configured
            </span>
          )}
        </header>

        {err && (
          <div className="border border-red-200 bg-red-50 text-red-800 rounded-xl p-4">
            <div className="font-medium">Error</div>
            <div className="text-sm mt-1 whitespace-pre-wrap">{err}</div>
          </div>
        )}

        <section className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <Card title="Peg status">
            <Row label="Pool address" value={isZeroAddress(ADDR.pool) ? "not set" : ADDR.pool} />
            <Row label="Pool tick" value={poolTick === null ? "not configured" : String(poolTick)} />
            <Row
              label="Deviation (signal)"
              value={deviationBps === null ? "not configured" : formatBps(deviationBps)}
            />
            <p className="text-xs text-gray-500 mt-3">
              This deviation is a temporary signal derived from tick. Next step: compute real price
              from sqrtPriceX96 + token decimals.
            </p>
          </Card>

          <Card title="Vault status">
            <Row label="Vault address" value={isZeroAddress(ADDR.vault) ? "not set" : ADDR.vault} />
            <Row label="TokenId" value={tokenId ?? "not configured"} />
            <Row
              label="Tick range"
              value={
                tickLower === null || tickUpper === null ? "not configured" : `${tickLower} … ${tickUpper}`
              }
            />
          </Card>
        </section>

        <footer className="text-xs text-gray-500">
          {loading ? "Loading…" : "Updated."}
        </footer>
      </div>
    </main>
  );
}

function Card(props: { title: string; children: React.ReactNode }) {
  return (
    <div className="border rounded-2xl p-5 shadow-sm">
      <h2 className="font-semibold mb-3">{props.title}</h2>
      <div className="space-y-2">{props.children}</div>
    </div>
  );
}

function Row(props: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-4">
      <div className="text-sm text-gray-600">{props.label}</div>
      <div className="text-sm font-medium text-gray-900 truncate max-w-[60%] text-right">
        {props.value}
      </div>
    </div>
  );
}
