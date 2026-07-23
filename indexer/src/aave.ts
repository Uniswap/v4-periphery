import type { Context } from "ponder:registry";
import { ponder } from "ponder:registry";
import { lendingMarket } from "ponder:schema";
import { and, eq } from "ponder";

import { findActivePosition, isMarginAccount } from "./helpers";
import { recordFlow, recordLiquidation, stageUnattributedFlow } from "./lendingFlows";

/**
 * Aave v3 flows. Aave events carry a single reserve, so the (collateral, debt)
 * pair is resolved from the adapter's market registry: the event kind fixes the
 * reserve's role (supply/withdraw => collateral, borrow/repay => debt), and the
 * registry (falling back to the account's live positions) fixes the other side.
 * Unresolvable flows are staged; the router handler completes attribution.
 */

type FlowKind = "SUPPLY_COLLATERAL" | "WITHDRAW_COLLATERAL" | "BORROW" | "REPAY";

async function resolvePair(
  context: Context,
  accountAddr: `0x${string}`,
  reserve: `0x${string}`,
  role: "collateral" | "debt"
): Promise<{ collateral: `0x${string}`; debt: `0x${string}` } | null> {
  const column = role === "collateral" ? lendingMarket.collateral : lendingMarket.debt;
  const candidates = await context.db.sql
    .select()
    .from(lendingMarket)
    .where(and(eq(lendingMarket.venue, "AAVE_V3"), eq(column, reserve)));

  if (candidates.length === 1) {
    return { collateral: candidates[0]!.collateral, debt: candidates[0]!.debt };
  }
  // several registered pairs share this reserve: disambiguate by live position
  const liveMatches = [];
  for (const candidate of candidates) {
    const live = await findActivePosition(context, accountAddr, candidate.collateral, candidate.debt);
    if (live) liveMatches.push(candidate);
  }
  if (liveMatches.length === 1) {
    return { collateral: liveMatches[0]!.collateral, debt: liveMatches[0]!.debt };
  }
  return null;
}

async function handleAaveFlow(
  context: Context,
  event: any,
  kind: FlowKind,
  accountAddr: `0x${string}`,
  reserve: `0x${string}`,
  assets: bigint
): Promise<void> {
  if (!(await isMarginAccount(context, accountAddr))) return;

  const role = kind === "SUPPLY_COLLATERAL" || kind === "WITHDRAW_COLLATERAL" ? "collateral" : "debt";
  const pair = await resolvePair(context, accountAddr, reserve, role);

  const base = {
    venue: "AAVE_V3" as const,
    kind,
    account: accountAddr,
    assets,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  };

  if (pair) {
    await recordFlow(context, { ...base, ...pair });
  } else {
    await stageUnattributedFlow(context, base);
  }
}

ponder.on("AaveV3Pool:Supply", async ({ event, context }) => {
  await handleAaveFlow(context, event, "SUPPLY_COLLATERAL", event.args.onBehalfOf, event.args.reserve, event.args.amount);
});

ponder.on("AaveV3Pool:Withdraw", async ({ event, context }) => {
  await handleAaveFlow(context, event, "WITHDRAW_COLLATERAL", event.args.user, event.args.reserve, event.args.amount);
});

ponder.on("AaveV3Pool:Borrow", async ({ event, context }) => {
  await handleAaveFlow(context, event, "BORROW", event.args.onBehalfOf, event.args.reserve, event.args.amount);
});

ponder.on("AaveV3Pool:Repay", async ({ event, context }) => {
  await handleAaveFlow(context, event, "REPAY", event.args.user, event.args.reserve, event.args.amount);
});

ponder.on("AaveV3Pool:LiquidationCall", async ({ event, context }) => {
  if (!(await isMarginAccount(context, event.args.user))) return;

  await recordLiquidation(context, {
    venue: "AAVE_V3",
    account: event.args.user,
    collateral: event.args.collateralAsset,
    debt: event.args.debtAsset,
    repaidDebt: event.args.debtToCover,
    seizedCollateral: event.args.liquidatedCollateralAmount,
    badDebt: 0n,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

/*
 * Aave v4 (Spoke) flows: the margin suite routes through the Aave v4 Main
 * Spoke, but the v4 event schema for supplies/borrows/liquidations is not yet
 * pinned in this repo. Positions opened through the Aave v4 adapter still get
 * lifecycle rows from the router events; only running amounts, equity
 * derivation, and liquidation detection are pending the Spoke ABI. Add a
 * contract entry in ponder.config.ts and mirror the handlers above once the
 * event surface is confirmed.
 */
