import { ponder } from "ponder:registry";
import { pool } from "ponder:schema";

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
