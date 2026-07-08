import type { Context } from "ponder:registry";
import { activePosition, lendingEvent, position, positionAction } from "ponder:schema";

import { clamp0, eventId, findActivePosition, pairKey, WAD } from "./helpers";

type Venue = "MORPHO" | "AAVE_V3" | "AAVE_V4";
type FlowKind = "SUPPLY_COLLATERAL" | "WITHDRAW_COLLATERAL" | "BORROW" | "REPAY";

interface FlowEvent {
  venue: Venue;
  kind: FlowKind;
  account: `0x${string}`;
  collateral: `0x${string}`;
  debt: `0x${string}`;
  morphoMarketId?: `0x${string}`;
  assets: bigint;
  txHash: `0x${string}`;
  logIndex: number;
  blockNumber: bigint;
  timestamp: bigint;
}

/**
 * Stage a collateral/debt flow and, when a live position exists for the pair,
 * apply it to the running amounts immediately. Flows with no live position
 * (the legs of a first open, or owner escape-hatch operations after a terminal
 * state) stay staged; the router lifecycle handler that fires later in the
 * same transaction consumes them, and never-consumed rows remain queryable as
 * the raw account history.
 */
export async function recordFlow(context: Context, flow: FlowEvent): Promise<void> {
  const live = await findActivePosition(context, flow.account, flow.collateral, flow.debt);

  const collateralDelta =
    flow.kind === "SUPPLY_COLLATERAL" ? flow.assets : flow.kind === "WITHDRAW_COLLATERAL" ? -flow.assets : 0n;
  const debtDelta = flow.kind === "BORROW" ? flow.assets : flow.kind === "REPAY" ? -flow.assets : 0n;

  if (live) {
    await context.db.update(position, { id: live.id }).set((row) => ({
      collateralAmount: clamp0(row.collateralAmount + collateralDelta),
      debtPrincipal: clamp0(row.debtPrincipal + debtDelta),
      updatedAt: flow.timestamp,
    }));
  }

  await context.db.insert(lendingEvent).values({
    id: eventId(flow.txHash, flow.logIndex),
    txHash: flow.txHash,
    venue: flow.venue,
    kind: flow.kind,
    account: flow.account,
    collateral: flow.collateral,
    debt: flow.debt,
    morphoMarketId: flow.morphoMarketId,
    assets: flow.assets,
    blockNumber: flow.blockNumber,
    timestamp: flow.timestamp,
    applied: live !== null, // unapplied flows are picked up by the router handler in the same tx
  });
}

/**
 * Stage a flow whose (collateral, debt) pair could not be resolved from the
 * event alone (possible for Aave, whose events carry a single reserve). The
 * router lifecycle handler completes attribution in the same transaction.
 */
export async function stageUnattributedFlow(
  context: Context,
  flow: Omit<FlowEvent, "collateral" | "debt">
): Promise<void> {
  await context.db.insert(lendingEvent).values({
    id: eventId(flow.txHash, flow.logIndex),
    txHash: flow.txHash,
    venue: flow.venue,
    kind: flow.kind,
    account: flow.account,
    collateral: null,
    debt: null,
    morphoMarketId: flow.morphoMarketId,
    assets: flow.assets,
    blockNumber: flow.blockNumber,
    timestamp: flow.timestamp,
    applied: false,
  });
}

interface LiquidationEvent {
  venue: Venue;
  account: `0x${string}`;
  collateral: `0x${string}`;
  debt: `0x${string}`;
  morphoMarketId?: `0x${string}`;
  repaidDebt: bigint;
  seizedCollateral: bigint;
  badDebt: bigint;
  txHash: `0x${string}`;
  logIndex: number;
  blockNumber: bigint;
  timestamp: bigint;
}

/**
 * Liquidations never emit a router event, so this applies terminally here:
 * amounts, accumulators, and (when the debt is fully cleared) the LIQUIDATED
 * status. Partial liquidations leave the position OPEN with `liquidated` set.
 */
export async function recordLiquidation(context: Context, liq: LiquidationEvent): Promise<void> {
  await context.db.insert(lendingEvent).values({
    id: eventId(liq.txHash, liq.logIndex),
    txHash: liq.txHash,
    venue: liq.venue,
    kind: "LIQUIDATE",
    account: liq.account,
    collateral: liq.collateral,
    debt: liq.debt,
    morphoMarketId: liq.morphoMarketId,
    assets: liq.repaidDebt,
    seizedAssets: liq.seizedCollateral,
    badDebtAssets: liq.badDebt,
    blockNumber: liq.blockNumber,
    timestamp: liq.timestamp,
    applied: true,
  });

  const live = await findActivePosition(context, liq.account, liq.collateral, liq.debt);
  if (!live) return;

  const debtCleared = liq.repaidDebt + liq.badDebt;
  const remainingDebt = clamp0(live.debtPrincipal - debtCleared);
  const fullyLiquidated = remainingDebt === 0n;

  await context.db.update(position, { id: live.id }).set((row) => ({
    collateralAmount: clamp0(row.collateralAmount - liq.seizedCollateral),
    debtPrincipal: remainingDebt,
    liquidated: true,
    liquidatedAt: liq.timestamp,
    liquidationTxHash: liq.txHash,
    seizedCollateral: row.seizedCollateral + liq.seizedCollateral,
    liquidationRepaidDebt: row.liquidationRepaidDebt + liq.repaidDebt,
    badDebt: row.badDebt + liq.badDebt,
    status: fullyLiquidated ? "LIQUIDATED" : row.status,
    updatedAt: liq.timestamp,
  }));

  await context.db.insert(positionAction).values({
    id: eventId(liq.txHash, liq.logIndex),
    positionId: live.id,
    type: "LIQUIDATION",
    txHash: liq.txHash,
    logIndex: liq.logIndex,
    blockNumber: liq.blockNumber,
    timestamp: liq.timestamp,
    collateralDelta: -liq.seizedCollateral,
    debtDelta: -debtCleared,
    equityDelta: 0n,
    // liquidation execution price: debt cleared per collateral seized
    priceX18: liq.seizedCollateral > 0n ? (liq.repaidDebt * WAD) / liq.seizedCollateral : null,
    poolId: null,
  });

  if (fullyLiquidated) {
    await context.db.delete(activePosition, { id: pairKey(liq.account, liq.collateral, liq.debt) });
  }
}
