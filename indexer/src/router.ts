import type { Context } from "ponder:registry";
import { ponder } from "ponder:registry";
import {
  account,
  activePosition,
  lendingEvent,
  morphoMarketRef,
  position,
  positionAction,
  swapEvent,
} from "ponder:schema";
import { and, eq } from "ponder";

import { clamp0, ensureToken, eventId, pairKey, positionId, txLendingEvents, WAD } from "./helpers";

/**
 * Router lifecycle handlers. Within a position transaction the protocol logs
 * (v4 Swap, lending supply/borrow/repay/withdraw) always precede the router's
 * lifecycle event, so these handlers read the rows staged earlier in the same
 * transaction to derive economics the router does not emit: equity, debt
 * drawn, execution price, venue, and pool.
 */

ponder.on("MarginRouter:AccountCreated", async ({ event, context }) => {
  await context.db
    .insert(account)
    .values({
      address: event.args.account,
      chainId: context.chain.id,
      owner: event.args.owner,
      subId: event.args.subId,
      createdAt: event.block.timestamp,
      createdAtBlock: event.block.number,
      createdTxHash: event.transaction.hash,
    })
    .onConflictDoNothing();
});

/** Consume this tx's staged margin swaps; returns the first pool touched. */
async function consumeSwaps(context: Context, txHash: `0x${string}`): Promise<`0x${string}` | null> {
  const swaps = await context.db.sql
    .select()
    .from(swapEvent)
    .where(and(eq(swapEvent.txHash, txHash), eq(swapEvent.consumed, false)))
    .orderBy(swapEvent.id);
  for (const swap of swaps) {
    await context.db.update(swapEvent, { id: swap.id }).set({ consumed: true });
  }
  return swaps[0]?.poolId ?? null;
}

/** Sum staged flows of a kind, attribute unattributed rows to the pair, mark applied. */
async function drainFlows(
  context: Context,
  txHash: `0x${string}`,
  accountAddr: `0x${string}`,
  collateral: `0x${string}`,
  debt: `0x${string}`
) {
  const rows = await txLendingEvents(context, txHash, accountAddr);
  const sums = { supplied: 0n, withdrawn: 0n, drawn: 0n, repaid: 0n };
  let venue: "MORPHO" | "AAVE_V3" | "AAVE_V4" | "UNKNOWN" = "UNKNOWN";
  let morphoMarketId: `0x${string}` | null = null;
  let appliedAll = true;

  for (const row of rows) {
    if (row.kind === "LIQUIDATE") continue;
    // rows either match the pair or are unattributed (Aave single-reserve events)
    const matches =
      (row.collateral === null && row.debt === null) || (row.collateral === collateral && row.debt === debt);
    if (!matches) continue;

    if (row.kind === "SUPPLY_COLLATERAL") sums.supplied += row.assets;
    if (row.kind === "WITHDRAW_COLLATERAL") sums.withdrawn += row.assets;
    if (row.kind === "BORROW") sums.drawn += row.assets;
    if (row.kind === "REPAY") sums.repaid += row.assets;
    if (row.venue !== "UNKNOWN") venue = row.venue;
    if (row.morphoMarketId) morphoMarketId = row.morphoMarketId;
    if (!row.applied) appliedAll = false;

    await context.db
      .update(lendingEvent, { id: row.id })
      .set({ collateral, debt, applied: true });
  }
  return { ...sums, venue, morphoMarketId, appliedAll };
}

ponder.on("MarginRouter:PositionOpened", async ({ event, context }) => {
  const { owner, account: accountAddr, collateral, debt, collateralBought } = event.args;
  await ensureToken(context, collateral);
  await ensureToken(context, debt);

  const flows = await drainFlows(context, event.transaction.hash, accountAddr, collateral, debt);
  const openPoolId = await consumeSwaps(context, event.transaction.hash);

  const equityDelta = clamp0(flows.supplied - collateralBought);
  const priceX18 = collateralBought > 0n ? (flows.drawn * WAD) / collateralBought : null;

  const key = pairKey(accountAddr, collateral, debt);
  const pointer = await context.db.find(activePosition, { id: key });

  if (pointer) {
    // increase: lending flows already applied to running amounts; accumulate economics
    const updated = await context.db.update(position, { id: pointer.positionId }).set((row) => {
      const totalBought = row.totalCollateralBought + collateralBought;
      const totalDrawn = row.totalDebtDrawn + flows.drawn;
      return {
        equity: row.equity + equityDelta,
        totalCollateralBought: totalBought,
        totalDebtDrawn: totalDrawn,
        avgEntryPriceX18: totalBought > 0n ? (totalDrawn * WAD) / totalBought : row.avgEntryPriceX18,
        collateralAmount: flows.appliedAll ? row.collateralAmount : row.collateralAmount + flows.supplied,
        debtPrincipal: flows.appliedAll ? row.debtPrincipal : row.debtPrincipal + flows.drawn,
        updatedAt: event.block.timestamp,
      };
    });

    await context.db.insert(positionAction).values({
      id: eventId(event.transaction.hash, event.log.logIndex),
      positionId: updated.id,
      type: "INCREASE",
      txHash: event.transaction.hash,
      logIndex: event.log.logIndex,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      collateralDelta: flows.supplied,
      debtDelta: flows.drawn,
      equityDelta,
      priceX18,
      poolId: openPoolId,
    });
    return;
  }

  // first open of this epoch
  const id = positionId(accountAddr, collateral, debt, event.transaction.hash);
  const marketRef = flows.morphoMarketId
    ? await context.db.find(morphoMarketRef, { id: flows.morphoMarketId })
    : null;

  await context.db.insert(position).values({
    id,
    chainId: context.chain.id,
    owner,
    account: accountAddr,
    collateral,
    debt,
    venue: flows.venue,
    status: "OPEN",
    collateralAmount: flows.supplied,
    debtPrincipal: flows.drawn,
    equity: equityDelta,
    totalCollateralBought: collateralBought,
    totalDebtDrawn: flows.drawn,
    avgEntryPriceX18: priceX18,
    leverageX18AtOpen: equityDelta > 0n ? (flows.supplied * WAD) / equityDelta : null,
    openTxHash: event.transaction.hash,
    openedAt: event.block.timestamp,
    openBlock: event.block.number,
    openPoolId,
    morphoMarketId: flows.morphoMarketId,
    lltv: marketRef?.lltv ?? null,
    liquidated: false,
    seizedCollateral: 0n,
    liquidationRepaidDebt: 0n,
    badDebt: 0n,
    updatedAt: event.block.timestamp,
  });
  await context.db.insert(activePosition).values({ id: key, positionId: id }).onConflictDoUpdate({ positionId: id });

  await context.db.insert(positionAction).values({
    id: eventId(event.transaction.hash, event.log.logIndex),
    positionId: id,
    type: "OPEN",
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    collateralDelta: flows.supplied,
    debtDelta: flows.drawn,
    equityDelta,
    priceX18,
    poolId: openPoolId,
  });
});

ponder.on("MarginRouter:PositionDecreased", async ({ event, context }) => {
  const { account: accountAddr, collateral, debt, debtRepaid } = event.args;

  const flows = await drainFlows(context, event.transaction.hash, accountAddr, collateral, debt);
  const poolId = await consumeSwaps(context, event.transaction.hash);

  const pointer = await context.db.find(activePosition, { id: pairKey(accountAddr, collateral, debt) });
  if (!pointer) return;

  // the decrease swap sells exactly the withdrawn collateral for the repaid debt
  const priceX18 = flows.withdrawn > 0n ? (debtRepaid * WAD) / flows.withdrawn : null;

  await context.db.update(position, { id: pointer.positionId }).set((row) => ({
    collateralAmount: flows.appliedAll ? row.collateralAmount : clamp0(row.collateralAmount - flows.withdrawn),
    debtPrincipal: flows.appliedAll ? row.debtPrincipal : clamp0(row.debtPrincipal - flows.repaid),
    updatedAt: event.block.timestamp,
  }));

  await context.db.insert(positionAction).values({
    id: eventId(event.transaction.hash, event.log.logIndex),
    positionId: pointer.positionId,
    type: "DECREASE",
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    collateralDelta: -flows.withdrawn,
    debtDelta: -debtRepaid,
    equityDelta: 0n,
    priceX18,
    poolId,
  });
});

ponder.on("MarginRouter:CollateralAdded", async ({ event, context }) => {
  const { account: accountAddr, collateral, amount } = event.args;

  // resolve the pair from this tx's staged supply flow (carries it for Morpho;
  // Aave rows may be unattributed, in which case fall back to the account's
  // single open position with this collateral)
  const rows = await txLendingEvents(context, event.transaction.hash, accountAddr);
  const supplyRow = rows.find((r) => r.kind === "SUPPLY_COLLATERAL");
  let debt = supplyRow?.debt ?? null;
  if (!debt) {
    const candidates = await context.db.sql
      .select()
      .from(position)
      .where(
        and(eq(position.account, accountAddr), eq(position.collateral, collateral), eq(position.status, "OPEN"))
      );
    if (candidates.length !== 1) return; // ambiguous or none; raw lendingEvent row remains
    debt = candidates[0]!.debt;
  }

  const flows = await drainFlows(context, event.transaction.hash, accountAddr, collateral, debt);
  const pointer = await context.db.find(activePosition, { id: pairKey(accountAddr, collateral, debt) });
  if (!pointer) return;

  await context.db.update(position, { id: pointer.positionId }).set((row) => ({
    equity: row.equity + amount,
    collateralAmount: flows.appliedAll ? row.collateralAmount : row.collateralAmount + flows.supplied,
    updatedAt: event.block.timestamp,
  }));

  await context.db.insert(positionAction).values({
    id: eventId(event.transaction.hash, event.log.logIndex),
    positionId: pointer.positionId,
    type: "ADD_COLLATERAL",
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    collateralDelta: amount,
    debtDelta: 0n,
    equityDelta: amount,
    priceX18: null,
    poolId: null,
  });
});

ponder.on("MarginRouter:PositionClosed", async ({ event, context }) => {
  const { account: accountAddr, collateral, debt, collateralReturned } = event.args;

  const flows = await drainFlows(context, event.transaction.hash, accountAddr, collateral, debt);
  const poolId = await consumeSwaps(context, event.transaction.hash);

  const key = pairKey(accountAddr, collateral, debt);
  const pointer = await context.db.find(activePosition, { id: key });
  if (!pointer) return;
  const row = await context.db.find(position, { id: pointer.positionId });
  if (!row) return;

  // collateral sold into the closing swap = withdrawn minus residual returned
  const collateralSold = clamp0(flows.withdrawn - collateralReturned);
  const exitPriceX18 = collateralSold > 0n ? (flows.repaid * WAD) / collateralSold : null;

  await context.db.update(position, { id: row.id }).set({
    status: "CLOSED",
    collateralAmount: 0n,
    debtPrincipal: 0n,
    closeTxHash: event.transaction.hash,
    closedAt: event.block.timestamp,
    collateralReturned,
    exitPriceX18,
    realizedPnl: collateralReturned - row.equity,
    updatedAt: event.block.timestamp,
  });
  await context.db.delete(activePosition, { id: key });

  await context.db.insert(positionAction).values({
    id: eventId(event.transaction.hash, event.log.logIndex),
    positionId: row.id,
    type: "CLOSE",
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    collateralDelta: -flows.withdrawn,
    debtDelta: -flows.repaid,
    equityDelta: -row.equity,
    priceX18: exitPriceX18,
    poolId,
  });
});
