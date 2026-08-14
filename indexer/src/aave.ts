import type { Context } from "ponder:registry";
import { ponder } from "ponder:registry";
import { lendingMarket } from "ponder:schema";
import { and, eq } from "ponder";

import { aaveV4HubFunctionsAbi, aaveV4SpokeFunctionsAbi } from "../abis";
import { findActivePosition, isMarginAccount } from "./helpers";
import { recordDeficit, recordFlow, recordLiquidation, stageUnattributedFlow } from "./lendingFlows";

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
    txTo: event.transaction.to ?? null,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  };

  if (pair) {
    await recordFlow(context, { ...base, ...pair });
  } else {
    await stageUnattributedFlow(context, { ...base, reserve });
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

// v3 deficits fire BEFORE the same-tx LiquidationCall: the position is still
// live, so the pair resolves like any debt-role flow. Bookkeeping only — the
// terminal transition happens in the LiquidationCall handler's chain check.
ponder.on("AaveV3Pool:DeficitCreated", async ({ event, context }) => {
  if (!(await isMarginAccount(context, event.args.user))) return;

  const pair = await resolvePair(context, event.args.user, event.args.debtAsset, "debt");
  await recordDeficit(context, {
    venue: "AAVE_V3",
    account: event.args.user,
    collateral: pair?.collateral ?? null,
    debt: event.args.debtAsset,
    assets: event.args.amountCreated,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

/**
 * Aave v4 (Spoke) flows. Aave v4 is hub-and-spoke: events are keyed by a
 * per-Spoke `reserveId` (uint256), not a reserve address, so the address-based
 * `resolvePair` above does not apply. The event kind fixes the reserve's role
 * (supply/withdraw => collateral, borrow/repay => debt) and the reserveId is
 * matched against the adapter's registered markets (`collateralReserveId` /
 * `debtReserveId`, set by AaveV4Adapter:MarketSet) to recover the pair.
 * Unresolvable flows are staged; the router handler completes attribution.
 */

/**
 * The asset address behind an Aave v4 reserveId, for the role given. Every registered market sharing that
 * reserveId in that role names the same asset — that shared asset is what makes them candidates — so any
 * candidate answers it. Needed because a staged flow must record the reserve it named as an ADDRESS, and
 * v4 events identify reserves numerically.
 */
async function reserveAssetForId({
  context,
  reserveId,
  role,
}: {
  context: Context;
  reserveId: bigint;
  role: "collateral" | "debt";
}): Promise<`0x${string}` | null> {
  const column = role === "collateral" ? lendingMarket.collateralReserveId : lendingMarket.debtReserveId;
  const candidates = await context.db.sql
    .select()
    .from(lendingMarket)
    .where(and(eq(lendingMarket.venue, "AAVE_V4"), eq(column, reserveId)));
  const first = candidates[0];
  if (!first) {
    return null;
  }
  return role === "collateral" ? first.collateral : first.debt;
}

async function resolvePairByReserveId({
  context,
  accountAddr,
  reserveId,
  role,
}: {
  context: Context;
  accountAddr: `0x${string}`;
  reserveId: bigint;
  role: "collateral" | "debt";
}): Promise<{ collateral: `0x${string}`; debt: `0x${string}` } | null> {
  const column = role === "collateral" ? lendingMarket.collateralReserveId : lendingMarket.debtReserveId;
  const candidates = await context.db.sql
    .select()
    .from(lendingMarket)
    .where(and(eq(lendingMarket.venue, "AAVE_V4"), eq(column, reserveId)));

  if (candidates.length === 1) {
    return { collateral: candidates[0]!.collateral, debt: candidates[0]!.debt };
  }
  // several registered pairs share this reserveId in this role: disambiguate by live position
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

async function handleAaveV4Flow({
  context,
  event,
  kind,
  accountAddr,
  reserveId,
  amount,
}: {
  context: Context;
  event: any;
  kind: FlowKind;
  accountAddr: `0x${string}`;
  reserveId: bigint;
  amount: bigint;
}): Promise<void> {
  if (!(await isMarginAccount(context, accountAddr))) return;

  const role = kind === "SUPPLY_COLLATERAL" || kind === "WITHDRAW_COLLATERAL" ? "collateral" : "debt";
  const pair = await resolvePairByReserveId({ context, accountAddr, reserveId, role });

  const base = {
    venue: "AAVE_V4" as const,
    kind,
    account: accountAddr,
    assets: amount,
    txHash: event.transaction.hash,
    txTo: event.transaction.to ?? null,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  };

  if (pair) {
    await recordFlow(context, { ...base, ...pair });
  } else {
    const reserve = await reserveAssetForId({ context, reserveId, role });
    if (reserve) {
      await stageUnattributedFlow(context, { ...base, reserve });
    }
  }
}

// Both caller and onBehalfOf equal the MarginAccount for margin flows; filter on
// onBehalfOf (the position owner) so a third-party action on behalf of a margin
// account still attributes correctly.
ponder.on("AaveV4Spoke:Supply", async ({ event, context }) => {
  await handleAaveV4Flow({
    context,
    event,
    kind: "SUPPLY_COLLATERAL",
    accountAddr: event.args.onBehalfOf,
    reserveId: event.args.reserveId,
    amount: event.args.amount,
  });
});

ponder.on("AaveV4Spoke:Withdraw", async ({ event, context }) => {
  await handleAaveV4Flow({
    context,
    event,
    kind: "WITHDRAW_COLLATERAL",
    accountAddr: event.args.onBehalfOf,
    reserveId: event.args.reserveId,
    amount: event.args.amount,
  });
});

ponder.on("AaveV4Spoke:Borrow", async ({ event, context }) => {
  await handleAaveV4Flow({
    context,
    event,
    kind: "BORROW",
    accountAddr: event.args.onBehalfOf,
    reserveId: event.args.reserveId,
    amount: event.args.amount,
  });
});

ponder.on("AaveV4Spoke:Repay", async ({ event, context }) => {
  await handleAaveV4Flow({
    context,
    event,
    kind: "REPAY",
    accountAddr: event.args.onBehalfOf,
    reserveId: event.args.reserveId,
    amount: event.args.amount,
  });
});

// LiquidationCall carries both reserveIds, so the pair resolves directly from the
// registry — no role-based disambiguation. `collateralAmountRemoved` is the total
// collateral seized (liquidator portion + treasury fee).
ponder.on("AaveV4Spoke:LiquidationCall", async ({ event, context }) => {
  if (!(await isMarginAccount(context, event.args.user))) return;

  const candidates = await context.db.sql
    .select()
    .from(lendingMarket)
    .where(
      and(
        eq(lendingMarket.venue, "AAVE_V4"),
        eq(lendingMarket.collateralReserveId, event.args.collateralReserveId),
        eq(lendingMarket.debtReserveId, event.args.debtReserveId)
      )
    );
  const market = candidates[0];
  if (!market) return; // liquidated pair is not a registered margin market

  await recordLiquidation(context, {
    venue: "AAVE_V4",
    account: event.args.user,
    collateral: market.collateral,
    debt: market.debt,
    debtReserveId: event.args.debtReserveId,
    repaidDebt: event.args.debtAmountRestored,
    seizedCollateral: event.args.collateralAmountRemoved,
    badDebt: 0n,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

// v4 deficits fire AFTER the same-tx LiquidationCall: the epoch is already
// closed, so recordDeficit resolves the pair from this tx's LIQUIDATE row.
// `drawnShares` are hub shares — converted to assets with block-pinned reads.
ponder.on("AaveV4Spoke:ReportDeficit", async ({ event, context }) => {
  if (!(await isMarginAccount(context, event.args.user))) return;

  const reserve = await context.client.readContract({
    abi: aaveV4SpokeFunctionsAbi,
    address: event.log.address,
    functionName: "getReserve",
    args: [event.args.reserveId],
    blockNumber: event.block.number,
  });
  const assets = await context.client.readContract({
    abi: aaveV4HubFunctionsAbi,
    address: reserve.hub,
    functionName: "previewRestoreByShares",
    args: [BigInt(reserve.assetId), event.args.drawnShares],
    blockNumber: event.block.number,
  });

  await recordDeficit(context, {
    venue: "AAVE_V4",
    account: event.args.user,
    collateral: null,
    debt: reserve.underlying,
    assets,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

/*
 * Compound v3 (Comet) flows: the Compound adapter's markets and router-driven lifecycle ARE indexed
 * (venue COMPOUND_V3, CompoundAdapter:MarketSet in markets.ts, and MarginRouter Position* events),
 * at parity with Aave v4. The Comet truth layer (out-of-band flows + liquidations) is deferred:
 * Comet models a liquidation as a two-event `absorb` (AbsorbDebt clears the base borrow; one
 * AbsorbCollateral per seized asset), which does not map onto the single-event `recordLiquidation`
 * used above and needs confirmation against live Comet events first. Base Supply/Withdraw also double
 * as repay/borrow (single-base market), so flow attribution mirrors the Aave single-reserve
 * resolution. Add the Comet contract (address in addresses.compoundComet) + a `cometAbi` and mirror
 * the handlers here once the event surface is validated on a fork.
 */
