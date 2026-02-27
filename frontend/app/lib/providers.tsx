"use client";

import { PegSentinelProvider } from "./shared";

export function Providers({ children }: { children: React.ReactNode }) {
  return <PegSentinelProvider>{children}</PegSentinelProvider>;
}
