export const ADDR = {
  vault: (process.env.NEXT_PUBLIC_VAULT_ADDRESS || "").toLowerCase(),
  pool: (process.env.NEXT_PUBLIC_POOL_ADDRESS || "").toLowerCase(),
};

export function isZeroAddress(a: string) {
  return !a || a === "0x0000000000000000000000000000000000000000";
}
