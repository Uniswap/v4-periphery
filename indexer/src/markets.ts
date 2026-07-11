import { ponder } from "ponder:registry";
import { adapter, lendingMarket, morphoMarketRef } from "ponder:schema";

import { deployments } from "../addresses";
import { ensureToken, lower } from "./helpers";

const VENUE_BY_ADAPTER: Record<string, "MORPHO" | "AAVE_V3" | "AAVE_V4"> = {
  [lower(deployments.mainnet.morphoAdapter)]: "MORPHO",
  [lower(deployments.mainnet.aaveAdapter)]: "AAVE_V3",
  [lower(deployments.mainnet.aaveV4Adapter)]: "AAVE_V4",
};


ponder.on("MarginRouter:AdapterAllowed", async ({ event, context }) => {
  await context.db
    .insert(adapter)
    .values({
      address: event.args.adapter,
      venue: VENUE_BY_ADAPTER[lower(event.args.adapter)] ?? "UNKNOWN",
      allowed: event.args.allowed,
      updatedAt: event.block.timestamp,
    })
    .onConflictDoUpdate({ allowed: event.args.allowed, updatedAt: event.block.timestamp });
});

ponder.on("MorphoAdapter:MarketSet", async ({ event, context }) => {
  const { id, collateral, debt, oracle, irm, lltv } = event.args;
  await ensureToken(context, collateral);
  await ensureToken(context, debt);

  // append-only reference so historical events on replaced markets still resolve
  await context.db
    .insert(morphoMarketRef)
    .values({ id, collateral, debt, oracle, lltv })
    .onConflictDoNothing();

  const values = {
    venue: "MORPHO" as const,
    adapter: event.log.address,
    collateral,
    debt,
    allowed: true,
    morphoMarketId: id,
    oracle,
    irm,
    lltv,
    updatedAt: event.block.timestamp,
  };
  await context.db
    .insert(lendingMarket)
    .values({ id: `morpho-${lower(collateral)}-${lower(debt)}`, ...values })
    .onConflictDoUpdate(values);
});

ponder.on("AaveAdapter:MarketSet", async ({ event, context }) => {
  const { collateral, debt, allowed } = event.args;
  await ensureToken(context, collateral);
  await ensureToken(context, debt);

  const values = {
    venue: "AAVE_V3" as const,
    adapter: event.log.address,
    collateral,
    debt,
    allowed,
    updatedAt: event.block.timestamp,
  };
  await context.db
    .insert(lendingMarket)
    .values({ id: `aave_v3-${lower(collateral)}-${lower(debt)}`, ...values })
    .onConflictDoUpdate(values);
});

ponder.on("AaveV4Adapter:MarketSet", async ({ event, context }) => {
  const { collateral, debt, collateralReserveId, debtReserveId, allowed } = event.args;
  await ensureToken(context, collateral);
  await ensureToken(context, debt);

  const values = {
    venue: "AAVE_V4" as const,
    adapter: event.log.address,
    collateral,
    debt,
    allowed,
    collateralReserveId,
    debtReserveId,
    updatedAt: event.block.timestamp,
  };
  await context.db
    .insert(lendingMarket)
    .values({ id: `aave_v4-${lower(collateral)}-${lower(debt)}`, ...values })
    .onConflictDoUpdate(values);
});
