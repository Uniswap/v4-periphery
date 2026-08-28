/**
 * Real mainnet receipts (fetched via `cast receipt --json`), decoded against
 * abis.ts with viem — mechanically re-proving the event signatures the
 * handlers rely on.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { decodeEventLog } from "viem";

import { aaveV3PoolAbi, aaveV4SpokeAbi } from "../../abis";
import type { HarnessEvent } from "./harness";

type Hex = `0x${string}`;

interface ReceiptLog {
  address: Hex;
  topics: [Hex, ...Hex[]];
  data: Hex;
  logIndex: Hex;
}

interface Receipt {
  transactionHash: Hex;
  blockNumber: Hex;
  logs: ReceiptLog[];
}

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "..", "fixtures");

export function loadReceipt(name: string): Receipt {
  return JSON.parse(readFileSync(join(fixturesDir, name), "utf8")) as Receipt;
}

const abiByContract = {
  AaveV3Pool: aaveV3PoolAbi,
  AaveV4Spoke: aaveV4SpokeAbi,
} as const;

/**
 * Decode every log of `receipt` emitted by `address` that matches an event in
 * the contract's ABI, as dispatchable harness events (`${contract}:${event}`).
 */
export function decodeReceiptEvents({
  receipt,
  contract,
  address,
}: {
  receipt: Receipt;
  contract: keyof typeof abiByContract;
  address: Hex;
}): HarnessEvent[] {
  const events: HarnessEvent[] = [];
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== address.toLowerCase()) continue;
    let decoded: { eventName: string; args: unknown };
    try {
      decoded = decodeEventLog({ abi: abiByContract[contract], topics: log.topics, data: log.data });
    } catch {
      continue; // log from this contract but not an event the indexer consumes
    }
    events.push({
      name: `${contract}:${decoded.eventName}`,
      args: decoded.args as Record<string, unknown>,
      txHash: receipt.transactionHash,
      logIndex: Number(BigInt(log.logIndex)),
      blockNumber: BigInt(receipt.blockNumber),
      timestamp: BigInt(receipt.blockNumber), // receipts carry no timestamp; any monotonic bigint works
      logAddress: log.address,
    });
  }
  return events;
}
