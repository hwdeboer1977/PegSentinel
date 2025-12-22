export function formatBps(x: number) {
  const sign = x >= 0 ? "+" : "";
  return `${sign}${x.toFixed(2)} bps`;
}