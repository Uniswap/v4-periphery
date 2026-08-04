#!/usr/bin/env node

/**
 * Dependency-free offchain reference for ReservesLens core amounts.
 *
 * Usage:
 *   node scripts/reserves-lens-reference.ts \
 *     <rpc-url> <state-view> <pool-id> <tick-spacing> [block-tag]
 *
 * Node 22+ runs this TypeScript directly. Reads go through the canonical StateView
 * ABI, deliberately independent of ReservesLens' raw-storage implementation.
 */

const [, , rpcUrl, stateView, poolId, spacingArg, blockTagArg = "latest"] = process.argv;
if (!rpcUrl || !stateView || !poolId || !spacingArg) {
  throw new Error("expected: <rpc-url> <state-view> <pool-id> <tick-spacing> [block-tag]");
}

const spacing = BigInt(spacingArg);
if (spacing < 1n || spacing > 32767n) throw new Error("invalid tick spacing");
if (!/^0x[0-9a-fA-F]{40}$/.test(stateView)) throw new Error("invalid StateView address");
if (!/^0x[0-9a-fA-F]{64}$/.test(poolId)) throw new Error("invalid pool id");

async function rpcRequest(method: string, params: unknown[]): Promise<unknown> {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json", "user-agent": "v4-reserves-lens-reference/1.0" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 0, method, params }),
  });
  if (!response.ok) throw new Error(`RPC HTTP ${response.status}`);
  const value = (await response.json()) as { result?: unknown; error?: { message: string } };
  if (value.result === undefined || value.result === null) throw new Error(value.error?.message ?? `${method} failed`);
  return value.result;
}

// Pin floating tags ("latest", "safe", "finalized") to one concrete block. The reads below span thousands of
// sequential eth_call batches; a new block arriving mid-run would tear the snapshot across blocks, producing
// either spurious invariant failures or a silently inconsistent reference value.
const blockTag = /^0x[0-9a-fA-F]+$/.test(blockTagArg)
  ? blockTagArg
  : ((await rpcRequest("eth_getBlockByNumber", [blockTagArg, false])) as { number: string }).number;

// A valid eth_call result is one or more 32-byte words; bare "0x" means no contract code at the target.
const isCallResult = (value: unknown): value is string =>
  typeof value === "string" && value.startsWith("0x") && value.length > 2 && (value.length - 2) % 64 === 0;

const MIN_TICK = -887272n;
const MAX_TICK = 887272n;
const Q96 = 1n << 96n;
const MAX_UINT256 = (1n << 256n) - 1n;
const GET_SLOT0 = "c815641c";
const GET_TICK_BITMAP = "1c7ccb4c";
const GET_TICK_LIQUIDITY = "caedab54";
const GET_LIQUIDITY = "fa6793d5";

const word = (value: bigint) => (value < 0n ? (1n << 256n) + value : value).toString(16).padStart(64, "0");
const callData = (selector: string, ...args: Array<bigint | string>) =>
  `0x${selector}${args.map((arg) => (typeof arg === "string" ? arg.slice(2) : word(arg))).join("")}`;

const delay = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function rpcSingle(calldata: string, id: number): Promise<{ id: number; result: string }> {
  let lastError = "RPC call failed";
  for (let attempt = 0; attempt < 8; attempt++) {
    const response = await fetch(rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json", "user-agent": "v4-reserves-lens-reference/1.0" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id,
        method: "eth_call",
        params: [{ to: stateView, data: calldata }, blockTag],
      }),
    });
    if (response.ok) {
      const value = (await response.json()) as { id: number; result?: string; error?: { message: string } };
      if (isCallResult(value.result)) return { id, result: value.result };
      if (value.result === "0x") {
        throw new Error(`eth_call returned no data — is a StateView contract deployed at ${stateView}?`);
      }
      lastError = value.error?.message ?? lastError;
    } else lastError = `RPC HTTP ${response.status}`;
    await delay(250 * (attempt + 1));
  }
  throw new Error(lastError);
}

async function rpcBatch(data: string[]): Promise<string[]> {
  const output: string[] = [];
  for (let start = 0; start < data.length; start += 10) {
    const chunk = data.slice(start, start + 10);
    const response = await fetch(rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json", "user-agent": "v4-reserves-lens-reference/1.0" },
      body: JSON.stringify(
        chunk.map((calldata, index) => ({
          jsonrpc: "2.0",
          id: start + index,
          method: "eth_call",
          params: [{ to: stateView, data: calldata }, blockTag],
        })),
      ),
    });
    const byId = new Map<number, string>();
    if (response.ok) {
      const payload = await response.json();
      if (Array.isArray(payload)) {
        for (const entry of payload as Array<{ id?: number; result?: string }>) {
          if (typeof entry?.id === "number" && isCallResult(entry.result)) byId.set(entry.id, entry.result);
        }
      }
    }
    for (let index = 0; index < chunk.length; index++) {
      const id = start + index;
      output.push(byId.get(id) ?? (await rpcSingle(chunk[index], id)).result);
    }
  }
  return output;
}

const signed = (value: bigint, bits: bigint) => {
  const sign = 1n << (bits - 1n);
  return value & sign ? value - (1n << bits) : value;
};
const outputWord = (data: string, index: number) => BigInt(`0x${data.slice(2 + index * 64, 2 + (index + 1) * 64)}`);

function sqrtAtTick(tick: bigint): bigint {
  const absTick = tick < 0n ? -tick : tick;
  if (absTick > MAX_TICK) throw new Error(`tick out of range: ${tick}`);
  const constants = [
    0xfffcb933bd6fad37aa2d162d1a594001n, 0xfff97272373d413259a46990580e213an,
    0xfff2e50f5f656932ef12357cf3c7fdccn, 0xffe5caca7e10e4e61c3624eaa0941cd0n,
    0xffcb9843d60f6159c9db58835c926644n, 0xff973b41fa98c081472e6896dfb254c0n,
    0xff2ea16466c96a3843ec78b326b52861n, 0xfe5dee046a99a2a811c461f1969c3053n,
    0xfcbe86c7900a88aedcffc83b479aa3a4n, 0xf987a7253ac413176f2b074cf7815e54n,
    0xf3392b0822b70005940c7a398e4b70f3n, 0xe7159475a2c29b7443b29c7fa6e889d9n,
    0xd097f3bdfd2022b8845ad8f792aa5825n, 0xa9f746462d870fdf8a65dc1f90e061e5n,
    0x70d869a156d2a1b890bb3df62baf32f7n, 0x31be135f97d08fd981231505542fcfa6n,
    0x9aa508b5b7a84e1c677de54f3e99bc9n, 0x5d6af8dedb81196699c329225ee604n,
    0x2216e584f5fa1ea926041bedfe98n, 0x48a170391f7dc42444e8fa2n,
  ];
  let price = 1n << 128n;
  for (let bit = 0; bit < constants.length; bit++) {
    if ((absTick & (1n << BigInt(bit))) !== 0n) price = (price * constants[bit]) >> 128n;
  }
  if (tick > 0n) price = MAX_UINT256 / price;
  return (price + (1n << 32n) - 1n) >> 32n;
}

const amount0 = (sqrtA: bigint, sqrtB: bigint, liquidity: bigint) => {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  return (((liquidity << 96n) * (sqrtB - sqrtA)) / sqrtB) / sqrtA;
};
const amount1 = (sqrtA: bigint, sqrtB: bigint, liquidity: bigint) => {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  return (liquidity * (sqrtB - sqrtA)) / Q96;
};

const [slot0, liquidityOutput] = await rpcBatch([callData(GET_SLOT0, poolId), callData(GET_LIQUIDITY, poolId)]);
const sqrtPriceX96 = outputWord(slot0, 0);
const currentTick = signed(outputWord(slot0, 1) & ((1n << 24n) - 1n), 24n);
const storedActive = outputWord(liquidityOutput, 0);
if (sqrtPriceX96 === 0n) throw new Error("pool is not initialized");

const minUsable = (MIN_TICK / spacing) * spacing;
const maxUsable = (MAX_TICK / spacing) * spacing;
const minWord = (minUsable / spacing) >> 8n;
const maxWord = (maxUsable / spacing) >> 8n;
const bitmapCalls: string[] = [];
for (let position = minWord; position <= maxWord; position++) {
  bitmapCalls.push(callData(GET_TICK_BITMAP, poolId, position));
}
const bitmaps = await rpcBatch(bitmapCalls);

const ticks: bigint[] = [];
for (let index = 0; index < bitmaps.length; index++) {
  let bitmap = outputWord(bitmaps[index], 0);
  const position = minWord + BigInt(index);
  for (let bit = 0n; bitmap !== 0n; bit++) {
    if ((bitmap & 1n) !== 0n) ticks.push((position * 256n + bit) * spacing);
    bitmap >>= 1n;
  }
}
const tickWords = await rpcBatch(ticks.map((tick) => callData(GET_TICK_LIQUIDITY, poolId, tick)));

let running = 0n;
let previous: bigint | undefined;
let coreAmount0 = 0n;
let coreAmount1 = 0n;
let reconstructedActive = 0n;
for (let index = 0; index < ticks.length; index++) {
  const gross = outputWord(tickWords[index], 0) & ((1n << 128n) - 1n);
  const net = signed(outputWord(tickWords[index], 1) & ((1n << 128n) - 1n), 128n);
  if (gross === 0n) throw new Error(`bitmap/tick mismatch at ${ticks[index]}`);
  if (net === 0n) continue;
  const tick = ticks[index];
  if (previous !== undefined) {
    if (currentTick >= previous && currentTick < tick) reconstructedActive = running;
    if (running !== 0n) {
      const sqrtA = sqrtAtTick(previous);
      const sqrtB = sqrtAtTick(tick);
      if (currentTick < previous) coreAmount0 += amount0(sqrtA, sqrtB, running);
      else if (currentTick < tick) {
        coreAmount0 += amount0(sqrtPriceX96, sqrtB, running);
        coreAmount1 += amount1(sqrtA, sqrtPriceX96, running);
      } else coreAmount1 += amount1(sqrtA, sqrtB, running);
    }
  }
  running += net;
  if (running < 0n) throw new Error(`negative running liquidity at ${tick}`);
  previous = tick;
}
if (running !== 0n) throw new Error("final running liquidity is non-zero");
if (reconstructedActive !== storedActive) throw new Error("reconstructed active liquidity does not match StateView");

console.log(
  JSON.stringify(
    {
      blockTag,
      poolId,
      tickSpacing: spacing.toString(),
      sqrtPriceX96: sqrtPriceX96.toString(),
      tick: currentTick.toString(),
      activeLiquidity: reconstructedActive.toString(),
      coreAmount0: coreAmount0.toString(),
      coreAmount1: coreAmount1.toString(),
      initializedTicks: ticks.length,
    },
    null,
    2,
  ),
);
