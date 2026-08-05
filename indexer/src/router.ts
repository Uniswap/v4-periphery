import type { Context } from "ponder:registry";
import { ponder } from "ponder:registry";
import { account, activePosition, lendingEvent, position, positionAction, swapEvent } from "ponder:schema";
import { and, eq } from "ponder";

import { clamp0, ensureToken, eventId, findActivePosition, pairKey, positionId, txLendingEvents, WAD } from "./helpers";

/**
 * Router lifecycle handlers. The router events carry the full economics
 * (equity, debt drawn, resulting totals, LTV, health factor), so unlike the
 * lending-protocol layer nothing has to be derived by correlation. The staged
 * lending/swap rows from earlier in the same transaction are still consumed
 * for venue, Morpho market id, and pool attribution.
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

/** Attribute this tx's staged lending flows to the pair; returns venue context. */
async function drainFlows(
  context: Context,
  txHash: `0x${string}`,
  accountAddr: `0x${string}`,
  collateral: `0x${string}`,
  debt: `0x${string}`
) {
  const rows = await txLendingEvents(context, txHash, accountAddr);
  let venue: "MORPHO" | "AAVE_V3" | "AAVE_V4" | "COMPOUND_V3" | "UNKNOWN" = "UNKNOWN";
  let morphoMarketId: `0x${string}` | null = null;

  for (const row of rows) {
    if (row.kind === "LIQUIDATE") continue;
    const matches =
      (row.collateral === null && row.debt === null) || (row.collateral === collateral && row.debt === debt);
    if (!matches) continue;

    if (row.venue !== "UNKNOWN") venue = row.venue;
    if (row.morphoMarketId) morphoMarketId = row.morphoMarketId;
    await context.db.update(lendingEvent, { id: row.id }).set({ collateral, debt, applied: true });
  }
  return { venue, morphoMarketId };
}

ponder.on("MarginRouter:PositionIncreased", async ({ event, context }) => {
  const {
    owner,
    account: accountAddr,
    collateral,
    debt,
    equity,
    collateralBought,
    debtDrawn,
    collateralTotal,
    debtTotal,
    currentLtv,
    maxLtv,
    healthFactorWad,
  } = event.args;
  await ensureToken(context, collateral);
  await ensureToken(context, debt);

  const flows = await drainFlows(context, event.transaction.hash, accountAddr, collateral, debt);
  const poolId = await consumeSwaps(context, event.transaction.hash);
  const priceX18 = collateralBought > 0n ? (debtDrawn * WAD) / collateralBought : null;

  const key = pairKey(accountAddr, collateral, debt);
  const pointer = await context.db.find(activePosition, { id: key });
  const existing = pointer ? await context.db.find(position, { id: pointer.positionId }) : null;

  // A genuine increase: a prior router event already reported this epoch's open.
  if (existing && existing.openReported) {
    const updated = await context.db.update(position, { id: existing.id }).set((row) => {
      const totalBought = row.totalCollateralBought + collateralBought;
      const totalDrawn = row.totalDebtDrawn + debtDrawn;
      return {
        equity: row.equity + equity,
        totalCollateralBought: totalBought,
        totalDebtDrawn: totalDrawn,
        avgEntryPriceX18: totalBought > 0n ? (totalDrawn * WAD) / totalBought : row.avgEntryPriceX18,
        collateralAmount: collateralTotal,
        debtPrincipal: debtTotal,
        lltv: maxLtv,
        lastLtvWad: currentLtv,
        lastHealthFactorWad: healthFactorWad,
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
      collateralDelta: equity + collateralBought,
      debtDelta: debtDrawn,
      equityDelta: equity,
      priceX18,
      poolId,
      ltvAfterWad: currentLtv,
      healthFactorWad,
    });
    return;
  }

  // Otherwise this event opens the epoch. Adopt the flow-created row when one exists (the common
  // Morpho path: the supply/borrow flows created it earlier in this tx), else create it (Aave flows
  // that could not resolve the pair, so no epoch was opened by the flow layer). Either way the event
  // totals are authoritative and the economics come only from here.
  const id = existing ? existing.id : positionId(accountAddr, collateral, debt, event.transaction.hash);
  const opened = {
    venue: flows.venue !== "UNKNOWN" ? flows.venue : (existing?.venue ?? flows.venue),
    equity,
    totalCollateralBought: collateralBought,
    totalDebtDrawn: debtDrawn,
    avgEntryPriceX18: priceX18,
    leverageX18AtOpen: equity > 0n ? (collateralTotal * WAD) / equity : null,
    collateralAmount: collateralTotal,
    debtPrincipal: debtTotal,
    openPoolId: poolId,
    morphoMarketId: flows.morphoMarketId ?? existing?.morphoMarketId ?? null,
    lltv: maxLtv,
    lastLtvWad: currentLtv,
    lastHealthFactorWad: healthFactorWad,
    openReported: true,
    updatedAt: event.block.timestamp,
  };

  if (existing) {
    await context.db.update(position, { id }).set(opened);
  } else {
    await context.db.insert(position).values({
      id,
      chainId: context.chain.id,
      owner,
      account: accountAddr,
      collateral,
      debt,
      status: "OPEN",
      openTxHash: event.transaction.hash,
      openedAt: event.block.timestamp,
      openBlock: event.block.number,
      liquidated: false,
      seizedCollateral: 0n,
      liquidationRepaidDebt: 0n,
      badDebt: 0n,
      ...opened,
    });
    await context.db.insert(activePosition).values({ id: key, positionId: id }).onConflictDoUpdate({ positionId: id });
  }

  await context.db.insert(positionAction).values({
    id: eventId(event.transaction.hash, event.log.logIndex),
    positionId: id,
    type: "OPEN",
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    collateralDelta: collateralTotal,
    debtDelta: debtDrawn,
    equityDelta: equity,
    priceX18,
    poolId,
    ltvAfterWad: currentLtv,
    healthFactorWad,
  });
});

ponder.on("MarginRouter:PositionDecreased", async ({ event, context }) => {
  const {
    account: accountAddr,
    collateral,
    debt,
    debtRepaid,
    collateralWithdrawn,
    collateralReturned,
    collateralTotal,
    debtTotal,
    currentLtv,
    healthFactorWad,
  } = event.args;

  await drainFlows(context, event.transaction.hash, accountAddr, collateral, debt);
  const poolId = await consumeSwaps(context, event.transaction.hash);

  const key = pairKey(accountAddr, collateral, debt);
  const pointer = await context.db.find(activePosition, { id: key });
  if (!pointer) return;
  const row = await context.db.find(position, { id: pointer.positionId });
  if (!row) return;

  // a full close leaves nothing behind; a partial decrease keeps the epoch open
  const isClose = collateralTotal === 0n && debtTotal === 0n;
  const collateralSold = clamp0(collateralWithdrawn - collateralReturned);
  const priceX18 = collateralSold > 0n ? (debtRepaid * WAD) / collateralSold : null;

  await context.db.update(position, { id: row.id }).set({
    collateralAmount: collateralTotal,
    debtPrincipal: debtTotal,
    lastLtvWad: currentLtv,
    lastHealthFactorWad: healthFactorWad,
    ...(isClose
      ? {
          status: "CLOSED" as const,
          closeTxHash: event.transaction.hash,
          closedAt: event.block.timestamp,
          collateralReturned,
          exitPriceX18: priceX18,
          realizedPnl: collateralReturned - row.equity,
        }
      : {}),
    updatedAt: event.block.timestamp,
  });
  if (isClose) await context.db.delete(activePosition, { id: key });

  await context.db.insert(positionAction).values({
    id: eventId(event.transaction.hash, event.log.logIndex),
    positionId: row.id,
    type: isClose ? "CLOSE" : "DECREASE",
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    collateralDelta: -collateralWithdrawn,
    debtDelta: -debtRepaid,
    equityDelta: isClose ? -row.equity : 0n,
    priceX18,
    poolId,
    ltvAfterWad: currentLtv,
    healthFactorWad,
  });
});

ponder.on("MarginRouter:CollateralAdded", async ({ event, context }) => {
  const {
    account: accountAddr,
    collateral,
    amount,
    collateralTotal,
    debtTotal,
    currentLtv,
    healthFactorWad,
  } = event.args;

  // resolve the pair: from this tx's staged supply flow (carries it for Morpho), or
  // fall back to the account's single open position with this collateral token
  const rows = await txLendingEvents(context, event.transaction.hash, accountAddr);
  const supplyRow = rows.find((r) => r.kind === "SUPPLY_COLLATERAL");
  let debt = supplyRow?.debt ?? null;
  if (!debt) {
    const candidates = await context.db.sql
      .select()
      .from(position)
      .where(and(eq(position.account, accountAddr), eq(position.collateral, collateral), eq(position.status, "OPEN")));
    if (candidates.length !== 1) return; // ambiguous or none; raw lendingEvent row remains
    debt = candidates[0]!.debt;
  }

  await drainFlows(context, event.transaction.hash, accountAddr, collateral, debt);
  const pointer = await context.db.find(activePosition, { id: pairKey(accountAddr, collateral, debt) });
  if (!pointer) return;

  await context.db.update(position, { id: pointer.positionId }).set((row) => ({
    equity: row.equity + amount,
    collateralAmount: collateralTotal,
    debtPrincipal: debtTotal,
    lastLtvWad: currentLtv,
    lastHealthFactorWad: healthFactorWad,
    // adopt a flow-opened collateral-only epoch as router-reported
    openReported: true,
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
    ltvAfterWad: currentLtv,
    healthFactorWad,
  });
});

/**
 * Resulting-state snapshot, emitted after every supply/withdraw/borrow/repay on any path (a curated
 * flow OR an `execute` plan). It carries the full pair and the adapter's describePosition totals, so it
 * fills the resulting-state fields that the curated Position* events would otherwise be the only source
 * of. It never touches economics (equity, entry price, leverage) or writes a positionAction row: those
 * come from the curated events and the lending-flow layer. Two jobs:
 *
 *  1. On a live epoch, reconcile the router-authoritative snapshot: LTV, health, max/liquidation LTV,
 *     and the running totals. For a curated flow this matches the Position* event that follows in the
 *     same tx (redundant but idempotent); for an execute plan it is the ONLY source of the LTV/health
 *     snapshot, and for Aave v4 / Compound v3 (no flow-truth layer indexed) it is also the only source
 *     of the running totals.
 *  2. When no epoch is live, open one. This is an execute-composed open the flow layer never created:
 *     an Aave v3 open whose pair its single-reserve events could not resolve, or an Aave v4 / Compound
 *     v3 open with no flow-truth layer. Economics stay empty (openReported = false); a later curated
 *     event adopts and fills them, exactly as it adopts a flow-created epoch.
 */
ponder.on("MarginRouter:PositionUpdated", async ({ event, context }) => {
  const {
    owner,
    account: accountAddr,
    collateral,
    debt,
    collateralTotal,
    debtTotal,
    currentLtv,
    maxLtv,
    healthFactorWad,
  } = event.args;
  await ensureToken(context, collateral);
  await ensureToken(context, debt);

  const terminal = collateralTotal === 0n && debtTotal === 0n;
  const live = await findActivePosition(context, accountAddr, collateral, debt);

  if (live) {
    await context.db.update(position, { id: live.id }).set({
      collateralAmount: collateralTotal,
      debtPrincipal: debtTotal,
      lltv: maxLtv,
      lastLtvWad: currentLtv,
      lastHealthFactorWad: healthFactorWad,
      // an execute / escape-hatch close nets the position to zero and emits no curated close; terminate
      // the epoch here. Leave the activePosition pointer (as the flow layer does) so a curated close in
      // the same tx can still enrich it and the next open overwrites it.
      ...(terminal ? { status: "CLOSED" as const } : {}),
      updatedAt: event.block.timestamp,
    });
    return;
  }

  // No live epoch: a terminal snapshot has nothing to open.
  if (terminal) return;

  // Open the epoch from the snapshot. Venue comes from this tx's staged flows when resolvable (Aave v3
  // unattributed opens), else UNKNOWN (Aave v4 / Compound, which stage no flows).
  const flows = await drainFlows(context, event.transaction.hash, accountAddr, collateral, debt);
  const id = positionId(accountAddr, collateral, debt, event.transaction.hash);
  await context.db
    .insert(position)
    .values({
      id,
      chainId: context.chain.id,
      owner,
      account: accountAddr,
      collateral,
      debt,
      venue: flows.venue,
      status: "OPEN",
      openReported: false,
      collateralAmount: collateralTotal,
      debtPrincipal: debtTotal,
      equity: 0n,
      totalCollateralBought: 0n,
      totalDebtDrawn: 0n,
      avgEntryPriceX18: null,
      leverageX18AtOpen: null,
      openTxHash: event.transaction.hash,
      openedAt: event.block.timestamp,
      openBlock: event.block.number,
      openPoolId: null,
      morphoMarketId: flows.morphoMarketId ?? null,
      lltv: maxLtv,
      liquidated: false,
      seizedCollateral: 0n,
      liquidationRepaidDebt: 0n,
      badDebt: 0n,
      lastLtvWad: currentLtv,
      lastHealthFactorWad: healthFactorWad,
      updatedAt: event.block.timestamp,
    })
    .onConflictDoNothing();
  await context.db
    .insert(activePosition)
    .values({ id: pairKey(accountAddr, collateral, debt), positionId: id })
    .onConflictDoUpdate({ positionId: id });
});
