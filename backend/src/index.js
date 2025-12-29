// src/index.js
import "dotenv/config";
import { ethers } from "ethers";
import { tickToPrice, deviationBpsFromPeg } from "./math.js";
import { getVault, toRangeStruct } from "./vault.js";
import { computeTargetRegime } from "./decision.js";

/**
 * ENV REQUIRED
 * RPC_URL=
 * PRIVATE_KEY=
 * POOL_ID=                         (bytes32 hex string)
 * STATE_VIEW_ADDRESS=
 * VAULT_ADDRESS=
 * POOL_MANAGER=
 * POSITION_MANAGER=
 * TOKEN0_ADDRESS=                  (ERC20 address OR 0x000..000 for native)
 * TOKEN1_ADDRESS=                  (ERC20 address OR 0x000..000 for native)
 *
 * OPTIONAL
 * POLL_SECONDS=15
 * AMOUNT0_MIN=0
 * AMOUNT1_MIN=0
 * DEADLINE_SECONDS=300
 * DRY_RUN=0                        (set to 1 to never send tx)
 */

const StateViewABI = [
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
];

const PoolManagerABI = [
  "function getPositionInfo(bytes32,address,int24,int24,bytes32) view returns (uint128,uint256,uint256)",
];

const PositionManagerABI = [
  "function modifyLiquidities(bytes calldata data, uint256 deadline) payable",
];

const VaultABI = [
  "function activeRegime() view returns (uint8)",
  "function normalRange() view returns (int24,int24,bool)",
  "function mildRange() view returns (int24,int24,bool)",
  "function severeRange() view returns (int24,int24,bool)",
  "function normalPosition() view returns (uint256,int24,int24,bytes32,bool)",
  "function supportPosition() view returns (uint256,int24,int24,bytes32,bool)",
  "function execute(address target,uint256 value,bytes calldata data) returns (bytes)",
];

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;

const POOL_ID = process.env.POOL_ID;
const STATE_VIEW = process.env.STATE_VIEW_ADDRESS;
const VAULT_ADDRESS = process.env.VAULT_ADDRESS;

const POOL_MANAGER = process.env.POOL_MANAGER_ADDRESS;
const POSITION_MANAGER = process.env.POSITION_MANAGER_ADDRESS;

const TOKEN0_ADDRESS = process.env.TOKEN0_ADDRESS;
const TOKEN1_ADDRESS = process.env.TOKEN1_ADDRESS;

const POLL_SECONDS = Number(process.env.POLL_SECONDS || 15);
const DEADLINE_SECONDS = Number(process.env.DEADLINE_SECONDS || 300);

const AMOUNT0_MIN = BigInt(process.env.AMOUNT0_MIN || "0");
const AMOUNT1_MIN = BigInt(process.env.AMOUNT1_MIN || "0");

const DRY_RUN = (process.env.DRY_RUN || "0") === "1";

if (!RPC_URL) throw new Error("Missing RPC_URL");
if (!PRIVATE_KEY) throw new Error("Missing PRIVATE_KEY");

if (!POOL_ID) throw new Error("Missing POOL_ID");
if (!STATE_VIEW) throw new Error("Missing STATE_VIEW_ADDRESS");
if (!VAULT_ADDRESS) throw new Error("Missing VAULT_ADDRESS");

if (!POOL_MANAGER) throw new Error("Missing POOL_MANAGER");
if (!POSITION_MANAGER) throw new Error("Missing POSITION_MANAGER");

if (!TOKEN0_ADDRESS) throw new Error("Missing TOKEN0_ADDRESS");
if (!TOKEN1_ADDRESS) throw new Error("Missing TOKEN1_ADDRESS");

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function regimeName(n) {
  if (n === 0) return "Normal";
  if (n === 1) return "Mild";
  if (n === 2) return "Severe";
  return `Unknown(${n})`;
}

function boolStr(b) {
  return b ? "yes" : "no";
}

/**
 * Port of your Solidity helper:
 *
 * actions = abi.encodePacked(
 *   uint8(Actions.DECREASE_LIQUIDITY),
 *   uint8(Actions.TAKE_PAIR)
 * );
 *
 * params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, hookData);
 * params[1] = abi.encode(currency0, currency1, recipient);
 *
 * NOTE: In v4, Currency encodes as address; native is address(0).
 */
function buildDecreaseLiquidityBundle({
  tokenId,
  liquidity,
  amount0Min,
  amount1Min,
  recipient,
  hookData,
}) {
const ACTION_DECREASE_LIQUIDITY = 1;
const ACTION_TAKE_PAIR = 6;

const actions = ethers.concat([
  ethers.toBeHex(ACTION_DECREASE_LIQUIDITY, 1),
  ethers.toBeHex(ACTION_TAKE_PAIR, 1),
]);

  const abiCoder = ethers.AbiCoder.defaultAbiCoder();

  const p0 = abiCoder.encode(
    ["uint256", "uint256", "uint256", "uint256", "bytes"],
    [tokenId, liquidity, amount0Min, amount1Min, hookData]
  );

  const p1 = abiCoder.encode(
    ["address", "address", "address"],
    [TOKEN0_ADDRESS, TOKEN1_ADDRESS, recipient]
  );

  return { actions, params: [p0, p1] };
}

async function pullAllLiquidity({
  vaultWithSigner,
  vaultRead,
  poolManager,
  positionManagerIface,
  poolId,
  activeRegime,
}) {
  // Choose current position meta
  const pos =
    activeRegime === 0
      ? await vaultRead.normalPosition()
      : await vaultRead.supportPosition();

  const tokenId = BigInt(pos[0]);
  const tickLower = Number(pos[1]);
  const tickUpper = Number(pos[2]);
  const salt = pos[3];
  const isActive = Boolean(pos[4]);

  if (!isActive || tokenId === 0n) {
    console.log("No active position to pull from.");
    return;
  }

  // Read liquidity from PoolManager; position owner is the PositionManager contract
  const [liqOld] = await poolManager.getPositionInfo(
    poolId,
    POSITION_MANAGER,
    tickLower,
    tickUpper,
    salt
  );

  const liquidity = BigInt(liqOld);

  console.log("Pull liquidity from:");
  console.log("  tokenId:", tokenId.toString());
  console.log("  tickLower:", tickLower);
  console.log("  tickUpper:", tickUpper);
  console.log("  salt:", salt);
  console.log("  liquidity:", liquidity.toString());

  if (liquidity === 0n) {
    console.log("Position liquidity is 0; nothing to pull.");
    return;
  }

  const hookData = "0x";

  const { actions, params } = buildDecreaseLiquidityBundle({
    tokenId,
    liquidity,
    amount0Min: AMOUNT0_MIN,
    amount1Min: AMOUNT1_MIN,
    recipient: VAULT_ADDRESS,
    hookData,
  });

  // modifyLiquidities(bytes data, uint256 deadline) where data = abi.encode(actions, params)
  const abiCoder = ethers.AbiCoder.defaultAbiCoder();
  const data = abiCoder.encode(["bytes", "bytes[]"], [actions, params]);

  const deadline = Math.floor(Date.now() / 1000) + DEADLINE_SECONDS;
  const decCall = positionManagerIface.encodeFunctionData("modifyLiquidities", [
    data,
    deadline,
  ]);

  if (DRY_RUN) {
    console.log("[DRY_RUN] would call vault.execute(positionManager, 0, decCall)");
    return;
  }

  console.log("Calling vault.execute(positionManager, 0, decCall) ...");
  const tx = await vaultWithSigner.execute(POSITION_MANAGER, 0n, decCall);
  console.log("  tx:", tx.hash);
  const receipt = await tx.wait();
  console.log("  mined in block:", receipt.blockNumber);
  console.log("Pulled liquidity ✅");
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  const stateView = new ethers.Contract(STATE_VIEW, StateViewABI, provider);
  const poolManager = new ethers.Contract(POOL_MANAGER, PoolManagerABI, provider);

  // You already have helpers, keep them:
  const vaultRead = new ethers.Contract(
    VAULT_ADDRESS,
    VaultABI,
    provider
  );

  const vault = new ethers.Contract(
    VAULT_ADDRESS,
    VaultABI,
    signer
  );


  const positionManagerIface = new ethers.Interface(PositionManagerABI);

  console.log("V4 Keeper started (regimes + Step1 pull liquidity)");
  console.log("POOL_ID:", POOL_ID);
  console.log("STATE_VIEW:", STATE_VIEW);
  console.log("POOL_MANAGER:", POOL_MANAGER);
  console.log("POSITION_MANAGER:", POSITION_MANAGER);
  console.log("VAULT:", VAULT_ADDRESS);
  console.log("TOKEN0_ADDRESS:", TOKEN0_ADDRESS);
  console.log("TOKEN1_ADDRESS:", TOKEN1_ADDRESS);
  console.log("DRY_RUN:", DRY_RUN ? "yes" : "no");

  while (true) {
    try {
      // 1) Pool slot0 -> tick
      const slot0 = await stateView.getSlot0(POOL_ID);
      const tick = Number(slot0.tick);

      // 2) Price from tick
      const price = tickToPrice(tick);
      const devBps = deviationBpsFromPeg(price, 1.0);

      // 3) Vault regime + ranges
      const [activeRegimeRaw, normalRng, mildRng, severeRng] = await Promise.all([
        vaultRead.activeRegime(),
        vaultRead.normalRange(),
        vaultRead.mildRange(),
        vaultRead.severeRange(),
      ]);

      const activeRegime = Number(activeRegimeRaw);

      const ranges = {
        normal: toRangeStruct(normalRng),
        mild: toRangeStruct(mildRng),
        severe: toRangeStruct(severeRng),
      };

      // 4) Decide target regime
      const targetRegime = computeTargetRegime({ tick, ranges });

      // 5) needsRegimeUpdate
      const needsRegimeUpdate = targetRegime !== activeRegime;

      // 6) outOfRange based on current active position meta (same as your UI logic)
      const pos =
        activeRegime === 0
          ? await vaultRead.normalPosition()
          : await vaultRead.supportPosition();

      const posActive = Boolean(pos[4]);
      const posLo = Number(pos[1]);
      const posHi = Number(pos[2]);
      const outOfRange = posActive ? tick < posLo || tick > posHi : false;

      console.log(
        `[${new Date().toISOString()}] tick=${tick} price=${price.toFixed(6)} dev=${(devBps / 100).toFixed(2)}% ` +
          `active=${regimeName(activeRegime)} target=${regimeName(targetRegime)} ` +
          `needsUpdate=${boolStr(needsRegimeUpdate)} outOfRange=${boolStr(outOfRange)}`
      );

      // Step 1 trigger: pull all liquidity out of current active position
      if (needsRegimeUpdate || outOfRange) {
        console.log("Trigger detected → Step 1: pull all liquidity out");
        await pullAllLiquidity({
          vaultWithSigner: vault,
          vaultRead,
          poolManager,
          positionManagerIface,
          poolId: POOL_ID,
          activeRegime,
        });

        // Step 2 later:
        // - add liquidity into target regime ticks
        // - update vault meta
        // - vault.setActiveRegime(targetRegime)
      }
    } catch (err) {
      console.error("Loop error:", err?.reason || err?.message || err);
    }

    await sleep(POLL_SECONDS * 1000);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
