import { ponder } from "ponder:registry";
import { morphoMarketRef } from "ponder:schema";

import { isMarginAccount } from "./helpers";
import { recordFlow, recordLiquidation } from "./lendingFlows";

/**
 * Morpho Blue flows. Events are indexed for the whole singleton; only those
 * whose onBehalf/borrower is a known MarginAccount and whose market id was
 * ever registered on the adapter are attributed.
 */

async function resolveMarket(context: any, id: `0x${string}`) {
  return await context.db.find(morphoMarketRef, { id });
}

ponder.on("MorphoBlue:SupplyCollateral", async ({ event, context }) => {
  if (!(await isMarginAccount(context, event.args.onBehalf))) return;
  const market = await resolveMarket(context, event.args.id);
  if (!market) return;

  await recordFlow(context, {
    venue: "MORPHO",
    kind: "SUPPLY_COLLATERAL",
    account: event.args.onBehalf,
    collateral: market.collateral,
    debt: market.debt,
    morphoMarketId: event.args.id,
    assets: event.args.assets,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

ponder.on("MorphoBlue:WithdrawCollateral", async ({ event, context }) => {
  if (!(await isMarginAccount(context, event.args.onBehalf))) return;
  const market = await resolveMarket(context, event.args.id);
  if (!market) return;

  await recordFlow(context, {
    venue: "MORPHO",
    kind: "WITHDRAW_COLLATERAL",
    account: event.args.onBehalf,
    collateral: market.collateral,
    debt: market.debt,
    morphoMarketId: event.args.id,
    assets: event.args.assets,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

ponder.on("MorphoBlue:Borrow", async ({ event, context }) => {
  if (!(await isMarginAccount(context, event.args.onBehalf))) return;
  const market = await resolveMarket(context, event.args.id);
  if (!market) return;

  await recordFlow(context, {
    venue: "MORPHO",
    kind: "BORROW",
    account: event.args.onBehalf,
    collateral: market.collateral,
    debt: market.debt,
    morphoMarketId: event.args.id,
    assets: event.args.assets,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

ponder.on("MorphoBlue:Repay", async ({ event, context }) => {
  if (!(await isMarginAccount(context, event.args.onBehalf))) return;
  const market = await resolveMarket(context, event.args.id);
  if (!market) return;

  await recordFlow(context, {
    venue: "MORPHO",
    kind: "REPAY",
    account: event.args.onBehalf,
    collateral: market.collateral,
    debt: market.debt,
    morphoMarketId: event.args.id,
    assets: event.args.assets,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

ponder.on("MorphoBlue:Liquidate", async ({ event, context }) => {
  if (!(await isMarginAccount(context, event.args.borrower))) return;
  const market = await resolveMarket(context, event.args.id);
  if (!market) return;

  await recordLiquidation(context, {
    venue: "MORPHO",
    account: event.args.borrower,
    collateral: market.collateral,
    debt: market.debt,
    morphoMarketId: event.args.id,
    repaidDebt: event.args.repaidAssets,
    seizedCollateral: event.args.seizedAssets,
    badDebt: event.args.badDebtAssets,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});
