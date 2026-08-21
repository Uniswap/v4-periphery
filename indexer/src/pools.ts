import { ponder } from "ponder:registry";
import { pool, swapEvent } from "ponder:schema";

import { eventId } from "./helpers";

ponder.on("PoolManagerInit:Initialize", async ({ event, context }) => {
  await context.db
    .insert(pool)
    .values({
      poolId: event.args.id,
      currency0: event.args.currency0,
      currency1: event.args.currency1,
      fee: event.args.fee,
      tickSpacing: event.args.tickSpacing,
      hooks: event.args.hooks,
      createdAt: event.block.timestamp,
    })
    .onConflictDoNothing();
});

/**
 * Margin swaps (sender == MarginRouter, filtered in config). Staged so the
 * router lifecycle handlers, which fire later in the same transaction, can
 * attribute pool and execution context to the position action.
 */
ponder.on("PoolManagerSwaps:Swap", async ({ event, context }) => {
  await context.db.insert(swapEvent).values({
    id: eventId(event.transaction.hash, event.log.logIndex),
    txHash: event.transaction.hash,
    poolId: event.args.id,
    amount0: event.args.amount0,
    amount1: event.args.amount1,
    sqrtPriceX96: event.args.sqrtPriceX96,
    fee: event.args.fee,
    blockNumber: event.block.number,
    consumed: false,
  });
});
