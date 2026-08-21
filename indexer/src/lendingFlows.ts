import type { Context } from "ponder:registry";
import { account, activePosition, lendingEvent, position, positionAction } from "ponder:schema";

import { clamp0, eventId, findActivePosition, pairKey, positionId, WAD } from "./helpers";

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
 * Open a new position epoch from a lending flow, when no live epoch exists for the pair. This makes
 * the lending-protocol layer the source of truth for position existence and amounts, so positions
 * driven by an `execute` plan or an owner escape-hatch op (neither emits a router event) are
 * tracked. Economics (equity, leverage, pool, entry price, LTV) are left empty; a curated router
 * event later in the same tx adopts this epoch and fills them in (see router.ts). Amounts start at
 * zero and the caller applies the opening flow's delta, so there is no double count.
 */
async function openFlowPosition(context: Context, flow: FlowEvent): Promise<{ id: string }> {
  const acct = await context.db.find(account, { address: flow.account });
  // the account row is created by AccountCreated, which fires before any flow in the same tx
  // (SET_ACCOUNT / lazy deploy precede the supply/borrow); fall back defensively to the account.
  const owner = acct?.owner ?? flow.account;
  const id = positionId(flow.account, flow.collateral, flow.debt, flow.txHash);

  await context.db
    .insert(position)
    .values({
      id,
      chainId: context.chain.id,
      owner,
      account: flow.account,
      collateral: flow.collateral,
      debt: flow.debt,
      venue: flow.venue,
      status: "OPEN",
      openReported: false,
      collateralAmount: 0n,
      debtPrincipal: 0n,
      equity: 0n,
      totalCollateralBought: 0n,
      totalDebtDrawn: 0n,
      avgEntryPriceX18: null,
      leverageX18AtOpen: null,
      openTxHash: flow.txHash,
      openedAt: flow.timestamp,
      openBlock: flow.blockNumber,
      openPoolId: null,
      morphoMarketId: flow.morphoMarketId ?? null,
      lltv: null,
      liquidated: false,
      seizedCollateral: 0n,
      liquidationRepaidDebt: 0n,
      badDebt: 0n,
      lastLtvWad: null,
      lastHealthFactorWad: null,
      updatedAt: flow.timestamp,
    })
    .onConflictDoNothing();
  await context.db
    .insert(activePosition)
    .values({ id: pairKey(flow.account, flow.collateral, flow.debt), positionId: id })
    .onConflictDoUpdate({ positionId: id });
  return { id };
}

/**
 * Record a collateral/debt flow and apply it to the pair's live position, opening a new epoch when
 * an exposure-increasing flow arrives with none live. Amounts (and terminal status) are maintained
 * here from protocol events as the source of truth; a curated router event later in the same tx
 * adopts the epoch and adds economics. An epoch whose amounts both reach zero is terminated here so
 * router-less closes (execute / escape-hatch) do not leave it stuck OPEN; the activePosition pointer
 * is left for a curated close to enrich and is otherwise overwritten on the next open.
 */
export async function recordFlow(context: Context, flow: FlowEvent): Promise<void> {
  let live = await findActivePosition(context, flow.account, flow.collateral, flow.debt);

  const collateralDelta =
    flow.kind === "SUPPLY_COLLATERAL" ? flow.assets : flow.kind === "WITHDRAW_COLLATERAL" ? -flow.assets : 0n;
  const debtDelta = flow.kind === "BORROW" ? flow.assets : flow.kind === "REPAY" ? -flow.assets : 0n;

  if (!live && (flow.kind === "SUPPLY_COLLATERAL" || flow.kind === "BORROW")) {
    const opened = await openFlowPosition(context, flow);
    live = await context.db.find(position, { id: opened.id });
  }

  if (live) {
    const nextCollateral = clamp0(live.collateralAmount + collateralDelta);
    const nextDebt = clamp0(live.debtPrincipal + debtDelta);
    const terminal = nextCollateral === 0n && nextDebt === 0n;
    await context.db.update(position, { id: live.id }).set({
      collateralAmount: nextCollateral,
      debtPrincipal: nextDebt,
      ...(terminal ? { status: "CLOSED" as const } : {}),
      updatedAt: flow.timestamp,
    });
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
    applied: live !== null, // a flow with no live epoch to apply to remains staged as raw history
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
