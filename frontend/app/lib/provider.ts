import { JsonRpcProvider } from "ethers";

export function getProvider() {
  const url = process.env.NEXT_PUBLIC_RPC_URL;
  if (!url) throw new Error("Missing NEXT_PUBLIC_RPC_URL in .env.local");
  return new JsonRpcProvider(url);
}
