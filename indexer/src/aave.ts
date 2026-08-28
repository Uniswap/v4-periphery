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

/** The slice of a ponder event these handlers read. */
interface FlowEventSource {
  transaction: { hash: `0x${string}` };
  log: { logIndex: number };
  block: { number: bigint; timestamp: bigint };
}

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
  event: FlowEventSource,
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
 * The pair behind an Aave v4 reserveId, plus the reserve's own asset address. Both come from one
 * registry read: every market sharing that reserveId in that role names the same asset — that shared
 * asset is what makes them candidates — so `reserveAsset` is available even when the pair is not, and
 * a staged flow needs it because v4 events identify reserves numerically rather than by address.
 */
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
}): Promise<{ pair: { collateral: `0x${string}`; debt: `0x${string}` } | null; reserveAsset: `0x${string}` | null }> {
  const column = role === "collateral" ? lendingMarket.collateralReserveId : lendingMarket.debtReserveId;
  const candidates = await context.db.sql
    .select()
    .from(lendingMarket)
    .where(and(eq(lendingMarket.venue, "AAVE_V4"), eq(column, reserveId)));

  const first = candidates[0];
  if (!first) return { pair: null, reserveAsset: null };
  const reserveAsset = role === "collateral" ? first.collateral : first.debt;

  if (candidates.length === 1) {
    return { pair: { collateral: first.collateral, debt: first.debt }, reserveAsset };
  }
  // several registered pairs share this reserveId in this role: disambiguate by live position
  const liveMatches = [];
  for (const candidate of candidates) {
    const live = await findActivePosition(context, accountAddr, candidate.collateral, candidate.debt);
    if (live) liveMatches.push(candidate);
  }
  if (liveMatches.length === 1) {
    return { pair: { collateral: liveMatches[0]!.collateral, debt: liveMatches[0]!.debt }, reserveAsset };
  }
  return { pair: null, reserveAsset };
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
  event: FlowEventSource;
  kind: FlowKind;
  accountAddr: `0x${string}`;
  reserveId: bigint;
  amount: bigint;
}): Promise<void> {
  if (!(await isMarginAccount(context, accountAddr))) return;

  const role = kind === "SUPPLY_COLLATERAL" || kind === "WITHDRAW_COLLATERAL" ? "collateral" : "debt";
  const { pair, reserveAsset } = await resolvePairByReserveId({ context, accountAddr, reserveId, role });

  const base = {
    venue: "AAVE_V4" as const,
    kind,
    account: accountAddr,
    assets: amount,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  };

  if (pair) {
    await recordFlow(context, { ...base, ...pair });
  } else if (reserveAsset) {
    await stageUnattributedFlow(context, { ...base, reserve: reserveAsset });
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

// TODO: Compound v3 has no flow-truth layer. Its markets and router-driven lifecycle are indexed, but
// Comet's two-event `absorb` does not map onto the single-event recordLiquidation above, so its
// out-of-band flows and liquidations are invisible.
