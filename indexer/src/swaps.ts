import type { Context } from "ponder:registry";
import { swapEvent } from "ponder:schema";
import { decodeEventLog } from "viem";

import { poolManagerSwapAbi } from "../abis";
import { deployments } from "../addresses";
import { eventId, lower } from "./helpers";

const poolManagerAddr = lower(deployments.mainnet.poolManager);

/**
 * Persist this transaction's v4 swaps, parsed from the margin event's own receipt. The swap caller
 * is whatever Universal Router the route named (any address, per call), so PoolManager Swap logs
 * cannot be pre-filtered by sender; the receipt attributes exactly the swaps that share a
 * transaction with a margin event, on every execution path (curated route, execute-plan native
 * swap, any UR deployment).
 *
 * Called by BOTH the router lifecycle handlers and the venue flow layer, because neither alone
 * covers every path: an owner escape-hatch operation emits no router event at all, and within an
 * `execute` plan each venue event precedes the `PositionUpdated` that follows its action, so a
 * flow-derived price would read an empty swap table if only the router recorded them. The receipt
 * fetch is a cached, retryable client action and the insert is idempotent per swap log, so the
 * several handlers that fire for one transaction fetch once and insert each swap once.
 */
export async function recordTxSwaps(context: Context, txHash: `0x${string}`, blockNumber: bigint): Promise<void> {
  let receipt;
  try {
    receipt = await context.client.getTransactionReceipt({ hash: txHash });
  } catch {
    return; // receipt unavailable; pool attribution degrades to null, nothing else depends on it
  }
  for (const log of receipt.logs) {
    if (lower(log.address) !== poolManagerAddr) continue;
    let decoded;
    try {
      decoded = decodeEventLog({ abi: poolManagerSwapAbi, topics: log.topics, data: log.data });
    } catch {
      continue; // a PoolManager log that is not a Swap (Initialize, ModifyLiquidity, Donate)
    }
    await context.db
      .insert(swapEvent)
      .values({
        id: eventId(txHash, log.logIndex),
        txHash,
        poolId: decoded.args.id,
        amount0: decoded.args.amount0,
        amount1: decoded.args.amount1,
        sqrtPriceX96: decoded.args.sqrtPriceX96,
        fee: decoded.args.fee,
        blockNumber,
        consumed: false,
      })
      .onConflictDoNothing();
  }
}
