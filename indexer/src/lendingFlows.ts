import type { Context } from "ponder:registry";
import { account, activePosition, lendingEvent, lendingMarket, position, positionAction, swapEvent } from "ponder:schema";
import { and, eq } from "ponder";
import { erc20Abi } from "viem";

import { aaveV3PoolFunctionsAbi, aaveV4SpokeFunctionsAbi, morphoBlueFunctionsAbi } from "../abis";
import { deployments } from "../addresses";
import {
  adjustId,
  clamp0,
  eventId,
  findActivePosition,
  logIndexOf,
  lower,
  pairKey,
  positionId,
  reserveBelongsTo,
  syntheticCloseId,
  txLendingEvents,
  WAD,
} from "./helpers";
import { readMarkAtBlockSoft } from "./marks";
import { recordTxSwaps } from "./swaps";

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
 * driven by an `execute` plan or an owner escape-hatch op (neither emits a curated router event) are
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
  await applyFlow(context, flow, { alreadyStaged: false });
}

/**
 * Apply a flow to its position and record it. `alreadyStaged` distinguishes a fresh flow (insert the
 * lendingEvent row) from one that was staged earlier in the same transaction with a null pair and is now
 * being completed (update that row in place) — the row id is `${txHash}-${logIndex}` either way, so
 * inserting twice would collide.
 */
async function applyFlow(
  context: Context,
  flow: FlowEvent,
  { alreadyStaged }: { alreadyStaged: boolean }
): Promise<void> {
  // Swaps come from the transaction's receipt, and the router only records them from its own
  // handlers — which for an execute plan fire AFTER each venue event, and for an owner
  // escape-hatch operation never fire at all. Record here so the price/equity derivations below
  // see this tx's swaps on every path. Idempotent, and the receipt fetch is client-cached.
  await recordTxSwaps(context, flow.txHash, flow.blockNumber);

  let live = await findActivePosition(context, flow.account, flow.collateral, flow.debt);

  const collateralDelta =
    flow.kind === "SUPPLY_COLLATERAL" ? flow.assets : flow.kind === "WITHDRAW_COLLATERAL" ? -flow.assets : 0n;
  const debtDelta = flow.kind === "BORROW" ? flow.assets : flow.kind === "REPAY" ? -flow.assets : 0n;

  if (!live && (flow.kind === "SUPPLY_COLLATERAL" || flow.kind === "BORROW")) {
    const opened = await openFlowPosition(context, flow);
    live = await context.db.find(position, { id: opened.id });
  }

  let closed = false;
  if (live) {
    const collateralAfter = clamp0(live.collateralAmount + collateralDelta);
    const debtAfter = clamp0(live.debtPrincipal + debtDelta);
    await context.db.update(position, { id: live.id }).set({
      collateralAmount: collateralAfter,
      debtPrincipal: debtAfter,
      updatedAt: flow.timestamp,
    });
    closed = await detectRouterlessClose(context, flow, live, collateralAfter, debtAfter);
  }

  const row = {
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
  };
  const id = eventId(flow.txHash, flow.logIndex);
  if (alreadyStaged) {
    await context.db.update(lendingEvent, { id }).set({ ...row, reserve: null });
  } else {
    await context.db.insert(lendingEvent).values({ id, ...row });
  }

  // Execute-driven ops emit only a resulting-state snapshot, never a delta-carrying router event, so
  // the ADJUST action row and the equity move are synthesized here (after the lendingEvent insert, so
  // the gross-sum re-derivation sees this flow). A terminal zero-out is a CLOSE, not an ADJUST, so it
  // is skipped when detectRouterlessClose fired.
  if (live && !closed) {
    await synthesizeAdjust(context, flow, live.id);
  }
}

interface SwapRow {
  poolId: `0x${string}`;
  amount0: bigint;
  amount1: bigint;
}

/** This tx's staged margin swaps, oldest first. Peeks (never sets `consumed`),
 *  so curated router handlers keep their poolId attribution. `includeConsumed`
 *  reads them back after a router handler already consumed them (supersession). */
async function txSwaps(
  context: Context,
  txHash: `0x${string}`,
  { includeConsumed }: { includeConsumed: boolean }
): Promise<SwapRow[]> {
  const where = includeConsumed
    ? eq(swapEvent.txHash, txHash)
    : and(eq(swapEvent.txHash, txHash), eq(swapEvent.consumed, false));
  const rows = await context.db.sql.select().from(swapEvent).where(where);
  // swapEconomics attributes the pool from the FIRST row, so order is load-bearing. All rows share
  // this tx; order by numeric log index (the id is `${txHash}-${logIndex}` and sorts lexically — 12
  // before 8), same as consumeSwaps and txLendingEvents.
  return rows.sort((a, b) => logIndexOf(a.id) - logIndexOf(b.id));
}

/**
 * Swap-relative collateral/debt split for the leg, receiver- and pool-agnostic.
 * A v4 Swap amount is the swapper delta: negative = paid in, positive = received.
 * Collateral received (borrow-leg output) is `bought`, collateral paid (repay-leg
 * input) is `sold`; `buyDebt` is debt spent to buy.
 *
 * Which side is the collateral cannot come from the market pair. A routed leg may
 * execute on a native-keyed pool, whose currency0 is the native sentinel rather than
 * the wrapper the market names — address-sorting (WETH, USDC) then reads the debt leg
 * as collateral, yielding bought = 0 and booking the whole leveraged notional as owner
 * equity. The swap row carries no token identity to sort on either. The leg direction
 * decides it instead, and every caller knows it: a buy receives collateral and pays
 * debt, a sell the reverse. Borrow and repay legs are mutually exclusive within one
 * plan (marginExecuteEncoding rejects both), so the direction is unambiguous.
 *
 * Summing across swaps is right for a SPLIT — every path trades the market's own pair — and silently
 * wrong for a MULTI-HOP, whose middle fill is denominated in an intermediate token the swap row cannot
 * identify. Multi-hop cannot reach here: the encoder emits only SWAP_EXACT_OUT_SINGLE and has no path
 * opcode. Enabling it means deriving attribution from the calldata's ASSERT_FILL first.
 */
function swapEconomics(
  swaps: SwapRow[],
  { leg }: { leg: "BUY" | "SELL" | "NONE" }
): {
  bought: bigint;
  sold: bigint;
  buyDebt: bigint;
  poolId: `0x${string}` | null;
} {
  let bought = 0n;
  let sold = 0n;
  let buyDebt = 0n;
  let poolId: `0x${string}` | null = null;
  for (const swap of swaps) {
    if (poolId === null) poolId = swap.poolId;
    const received = swap.amount0 > 0n ? swap.amount0 : swap.amount1;
    const paid = swap.amount0 > 0n ? -swap.amount1 : -swap.amount0;
    if (received <= 0n || paid <= 0n) continue; // not a two-sided fill
    if (leg === "BUY") {
      bought += received;
      buyDebt += paid;
    } else if (leg === "SELL") {
      sold += paid;
    }
  }
  return { bought, sold, buyDebt, poolId };
}

/** Per-tx gross flow amounts for the pair, re-derived from this tx's lendingEvent rows. */
function grossSums(
  rows: Awaited<ReturnType<typeof txLendingEvents>>,
  collateral: `0x${string}`,
  debt: `0x${string}`
): { supplied: bigint; withdrawn: bigint; borrowed: bigint; repaid: bigint } {
  let supplied = 0n;
  let withdrawn = 0n;
  let borrowed = 0n;
  let repaid = 0n;
  for (const row of rows) {
    if (!row.collateral || !row.debt) continue;
    if (lower(row.collateral) !== lower(collateral) || lower(row.debt) !== lower(debt)) continue;
    if (row.kind === "SUPPLY_COLLATERAL") supplied += row.assets;
    else if (row.kind === "WITHDRAW_COLLATERAL") withdrawn += row.assets;
    else if (row.kind === "BORROW") borrowed += row.assets;
    else if (row.kind === "REPAY") repaid += row.assets;
  }
  return { supplied, withdrawn, borrowed, repaid };
}

// True when this tx already booked a LIQUIDATION for the position. A liquidation is a protocol event
// with equityDelta 0 — the seizure is a loss against a frozen basis, not an owner-driven equity move —
// so an ADJUST synthesized from the same tx's Withdraw/Repay flows would double-count it.
async function hasLiquidationInTx(
  context: Context,
  txHash: `0x${string}`,
  positionRowId: string
): Promise<boolean> {
  const rows = await context.db.sql
    .select()
    .from(positionAction)
    .where(
      and(
        eq(positionAction.txHash, txHash),
        eq(positionAction.positionId, positionRowId),
        eq(positionAction.type, "LIQUIDATION")
      )
    );
  return rows.length > 0;
}

/**
 * Synthesize (or refresh) the tx's ADJUST action and move equity for an
 * execute-driven op. Called once per applying flow; it re-derives the full tx
 * state each time, so the row and equity are correct after the last flow
 * regardless of flow/swap order.
 *
 * Equity is swap-relative: `equityIn = supplied − bought`, `equityOut =
 * withdrawn − sold` (both clamped ≥ 0), so collateral bought/sold as leverage
 * is excluded and only real margin in/out moves equity. Equity is recomputed as
 * `clamp0(equityBase + equityDelta)` from a stable pre-tx base captured on the
 * first flow — clamp0 is applied once, not composed across flows — so the write
 * is exact, step-order-independent, and exactly reversible on supersession even
 * when an intermediate step would floor equity at 0.
 *
 * Economics (totalCollateralBought/totalDebtDrawn/avgEntry) update only on a buy
 * leg, with the same volume-weighted formula as the PositionIncreased handler.
 * PoC scope: assumes a single buy leg per tx (a real margin adjust swaps once);
 * `priceX18 != null` marks that a prior flow already applied buy economics, so
 * the per-flow economics diff neither double-counts nor drops it.
 */
async function synthesizeAdjust(context: Context, flow: FlowEvent, positionRowId: string): Promise<void> {
  const lendingRows = await txLendingEvents(context, flow.txHash, flow.account);
  const { supplied, withdrawn, borrowed, repaid } = grossSums(lendingRows, flow.collateral, flow.debt);
  const swaps = await txSwaps(context, flow.txHash, { includeConsumed: false });
  // Borrow and repay legs are mutually exclusive within one plan, so exactly one of these identifies the
  // leg. Anything else — neither, or both — is not attributable and must not be guessed at.
  const leg = borrowed > 0n && repaid === 0n ? "BUY" : repaid > 0n && borrowed === 0n ? "SELL" : "NONE";
  const { bought, sold, buyDebt, poolId } = swapEconomics(swaps, { leg });

  const equityDelta = clamp0(supplied - bought) - clamp0(withdrawn - sold);
  const collateralDelta = supplied - withdrawn;
  const debtDelta = borrowed - repaid;
  // Null rather than a number nobody can justify: a wrong entry price silently corrupts cost basis forever.
  const priceX18 = bought > 0n ? (buyDebt * WAD) / bought : null;

  const id = adjustId(flow.txHash, positionRowId);
  const existing = await context.db.find(positionAction, { id });

  if (await hasLiquidationInTx(context, flow.txHash, positionRowId)) {
    return;
  }
  const priorBuyApplied = existing != null && existing.priceX18 !== null;
  const prevBought = priorBuyApplied ? bought : 0n;
  const prevBuyDebt = priorBuyApplied ? buyDebt : 0n;

  const live = await context.db.find(position, { id: positionRowId });
  // capture the pre-tx equity once (this tx's first synthesized flow), then reuse it
  const equityBase = existing ? (existing.equityBase ?? 0n) : (live?.equity ?? 0n);

  const markX18 = await readMarkAtBlockSoft({
    context,
    venue: flow.venue,
    collateral: flow.collateral,
    debt: flow.debt,
    morphoMarketId: flow.morphoMarketId ?? live?.morphoMarketId ?? null,
    blockNumber: flow.blockNumber,
  });
  // recordFlow applies each flow to the position BEFORE synthesizing, so these are already the
  // post-action balances. For a multi-flow tx the row is rewritten per flow and the ADJUST ends up
  // carrying the end-of-tx totals, which is what a fold wants.
  const collateralAfter = live?.collateralAmount ?? 0n;
  const debtAfter = live?.debtPrincipal ?? 0n;

  if (existing) {
    await context.db.update(positionAction, { id }).set({
      collateralDelta,
      debtDelta,
      equityDelta,
      priceX18,
      poolId,
      markX18,
      collateralAfter,
      debtAfter,
      logIndex: flow.logIndex,
      blockNumber: flow.blockNumber,
      timestamp: flow.timestamp,
    });
  } else {
    await context.db.insert(positionAction).values({
      id,
      positionId: positionRowId,
      type: "ADJUST",
      txHash: flow.txHash,
      logIndex: flow.logIndex,
      blockNumber: flow.blockNumber,
      timestamp: flow.timestamp,
      collateralDelta,
      debtDelta,
      equityDelta,
      priceX18,
      poolId,
      markX18,
      collateralAfter,
      debtAfter,
      equityBase,
    });
  }

  // Mark and size at open. router.ts pins these on a curated open and explains why: reading either off
  // the running totals later would let a pure leverage change move a figure the owner never traded at.
  // A flow-created epoch never reaches that code, so without this the backend's cost-basis fold falls
  // back and renders an entry price of 0 and an opened leverage of 0 for every execute()-driven position.
  //
  // Written only while this tx IS the epoch's opening tx, and rewritten on each of its flows so the
  // value settles on the end-of-tx totals — the opening supply and the bought leverage can arrive in
  // either order. Once the tx ends, openTxHash no longer matches and the figures are frozen.
  if (live?.openTxHash === flow.txHash && !live.openReported) {
    const equityAtOpen = clamp0(equityBase + equityDelta);
    await context.db.update(position, { id: positionRowId }).set({
      entryMarkX18: markX18,
      collateralAtOpen: collateralAfter,
      leverageX18AtOpen: equityAtOpen > 0n ? (collateralAfter * WAD) / equityAtOpen : null,
    });
  }

  await context.db.update(position, { id: positionRowId }).set((row) => {
    const equity = clamp0(equityBase + equityDelta);
    if (bought <= 0n) return { equity, updatedAt: flow.timestamp };
    const totalCollateralBought = row.totalCollateralBought - prevBought + bought;
    const totalDebtDrawn = row.totalDebtDrawn - prevBuyDebt + buyDebt;
    return {
      equity,
      totalCollateralBought,
      totalDebtDrawn,
      avgEntryPriceX18: totalCollateralBought > 0n ? (totalDebtDrawn * WAD) / totalCollateralBought : row.avgEntryPriceX18,
      updatedAt: flow.timestamp,
    };
  });
}

/**
 * Supersede this tx's synthetic ADJUST: reverse the equity (and, if it applied
 * a buy leg, the economics) increments it made, then delete the row. Called by
 * the curated router handlers before they write their authoritative action, and
 * by the CLOSE path (a terminal zero-out is a CLOSE, not an ADJUST). Swaps are
 * read with `includeConsumed` since a router handler may already have consumed
 * them; poolId attribution is untouched because synthesis never consumed them.
 *
 * Equity is restored to the row's captured pre-tx base, so reversal is exact
 * even when a forward step floored equity at 0 (subtracting equityDelta would
 * not recover the lost magnitude).
 */
export async function reverseAndSupersedeAdjust(
  context: Context,
  { txHash, positionRowId }: { txHash: `0x${string}`; positionRowId: string }
): Promise<void> {
  const id = adjustId(txHash, positionRowId);
  const row = await context.db.find(positionAction, { id });
  if (!row) return;

  const swaps = await txSwaps(context, txHash, { includeConsumed: true });
  // The forward pass stamps priceX18 only on a buy leg, so the row records its own direction.
  const { bought, buyDebt } = swapEconomics(swaps, {
    leg: row.priceX18 !== null ? "BUY" : "NONE",
  });
  const reverseEconomics = row.priceX18 !== null && bought > 0n;

  await context.db.update(position, { id: positionRowId }).set((p) => {
    // synthesis always records equityBase; fall back to the linear reverse only defensively
    const equity = row.equityBase !== null ? clamp0(row.equityBase) : clamp0(p.equity - row.equityDelta);
    if (!reverseEconomics) return { equity };
    const totalCollateralBought = clamp0(p.totalCollateralBought - bought);
    const totalDebtDrawn = clamp0(p.totalDebtDrawn - buyDebt);
    return {
      equity,
      totalCollateralBought,
      totalDebtDrawn,
      avgEntryPriceX18: totalCollateralBought > 0n ? (totalDebtDrawn * WAD) / totalCollateralBought : null,
    };
  });
  await context.db.delete(positionAction, { id });
}

/**
 * Complete this transaction's staged flows now that the pair is known, replaying each through the same
 * apply path a resolved flow takes. Without this a first-ever Aave open on a shared reserve leaves its
 * supply staged forever — and because the BORROW leg resolves on its own and opens the epoch, the
 * position ends up carrying debt against ZERO collateral rather than simply missing.
 *
 * Ordered by log index so the deltas land in emission order, and idempotent: a row already applied is
 * skipped, so a second clone event in the same transaction cannot double-count.
 */
export async function applyStagedFlows(
  context: Context,
  {
    txHash,
    account,
    collateral,
    debt,
  }: { txHash: `0x${string}`; account: `0x${string}`; collateral: `0x${string}`; debt: `0x${string}` }
): Promise<void> {
  const staged = await context.db.sql
    .select()
    .from(lendingEvent)
    .where(and(eq(lendingEvent.txHash, txHash), eq(lendingEvent.account, account), eq(lendingEvent.applied, false)));

  // Ordered by NUMERIC log index. Ids are `${txHash}-${logIndex}`, so a string sort puts 12 before 8 and
  // replays the deltas out of emission order — which changes where clamp0 bites and can miss a
  // cross-through-zero that should have closed the epoch.
  const belongs = reserveBelongsTo({ collateral, debt });
  const ordered = staged
    .filter((r) => r.collateral === null && belongs(r))
    .map((r) => ({ row: r, logIndex: logIndexOf(r.id) }))
    .sort((a, b) => a.logIndex - b.logIndex);
  for (const { row, logIndex } of ordered) {
    // Liquidations carry their own terminal accounting, and an UNKNOWN venue is not something to
    // guess at — skip both rather than invent a pair for them. COMPOUND_V3 is skipped too: its
    // flow-truth layer is deferred (see src/aave.ts), so no Compound flow is ever staged for
    // attribution and the local Venue union stays the set of flow-truth-capable venues.
    if (
      row.kind === "LIQUIDATE" ||
      row.venue === "UNKNOWN" ||
      row.venue === "COMPOUND_V3"
    ) {
      continue;
    }
    await applyFlow(
      context,
      {
        venue: row.venue,
        kind: row.kind,
        account: row.account,
        collateral,
        debt,
        morphoMarketId: row.morphoMarketId ?? undefined,
        assets: row.assets,
        txHash: row.txHash,
        logIndex,
        blockNumber: row.blockNumber,
        timestamp: row.timestamp,
      },
      { alreadyStaged: true }
    );
  }
}

/**
 * Stage a flow whose (collateral, debt) pair could not be resolved from the
 * event alone (possible for Aave, whose events carry a single reserve). The
 * router lifecycle handler completes attribution in the same transaction.
 */
export async function stageUnattributedFlow(
  context: Context,
  flow: Omit<FlowEvent, "collateral" | "debt"> & { reserve: `0x${string}` }
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
    reserve: flow.reserve,
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
  debtReserveId?: bigint; // Aave v4 only
  repaidDebt: bigint;
  seizedCollateral: bigint;
  badDebt: bigint;
  txHash: `0x${string}`;
  logIndex: number;
  blockNumber: bigint;
  timestamp: bigint;
}

/**
 * Block-pinned venue truth for "nothing left at all" — both legs, unlike
 * readVenueDebt: escape-hatch termination requires zero debt AND collateral.
 */
async function readVenueBalances(
  context: Context,
  flow: FlowEvent
): Promise<{ collateral: bigint; debt: bigint }> {
  const { blockNumber } = flow;
  switch (flow.venue) {
    case "MORPHO": {
      if (!flow.morphoMarketId) throw new Error(`Morpho flow without market id: ${flow.txHash}`);
      const [, borrowShares, collateral] = await context.client.readContract({
        abi: morphoBlueFunctionsAbi,
        address: deployments.mainnet.morphoBlue,
        functionName: "position",
        args: [flow.morphoMarketId, flow.account],
        blockNumber,
      });
      return { collateral, debt: borrowShares };
    }
    case "AAVE_V3": {
      const [aToken, debtToken] = await Promise.all([
        context.client.readContract({
          abi: aaveV3PoolFunctionsAbi,
          address: deployments.mainnet.aaveV3Pool,
          functionName: "getReserveAToken",
          args: [flow.collateral],
          blockNumber,
        }),
        context.client.readContract({
          abi: aaveV3PoolFunctionsAbi,
          address: deployments.mainnet.aaveV3Pool,
          functionName: "getReserveVariableDebtToken",
          args: [flow.debt],
          blockNumber,
        }),
      ]);
      const [collateral, debt] = await Promise.all([
        context.client.readContract({ abi: erc20Abi, address: aToken, functionName: "balanceOf", args: [flow.account], blockNumber }),
        context.client.readContract({ abi: erc20Abi, address: debtToken, functionName: "balanceOf", args: [flow.account], blockNumber }),
      ]);
      return { collateral, debt };
    }
    case "AAVE_V4": {
      const market = await context.db.find(lendingMarket, {
        // markets.ts:91 template — venue prefix is a lowercase literal; the venue
        // enum value "AAVE_V4" would not match.
        id: `aave_v4-${lower(flow.collateral)}-${lower(flow.debt)}`,
      });
      if (market?.collateralReserveId == null || market.debtReserveId == null) {
        throw new Error(`Aave v4 flow without registered reserve ids: ${flow.txHash}`);
      }
      const [collateral, debt] = await Promise.all([
        context.client.readContract({
          abi: aaveV4SpokeFunctionsAbi,
          address: deployments.mainnet.aaveV4Spoke,
          functionName: "getUserSuppliedAssets",
          args: [market.collateralReserveId, flow.account],
          blockNumber,
        }),
        context.client.readContract({
          abi: aaveV4SpokeFunctionsAbi,
          address: deployments.mainnet.aaveV4Spoke,
          functionName: "getUserTotalDebt",
          args: [market.debtReserveId, flow.account],
          blockNumber,
        }),
      ]);
      return { collateral, debt };
    }
  }
}

/**
 * A router-less full close: venue flows zero both legs with no curated router close. When a flow
 * zeroes both running amounts on an OPEN epoch, confirm against block-pinned venue truth and apply
 * the terminal transition here. The owner escape hatch bypasses the router entirely, so not even a
 * PositionUpdated snapshot arrives — this is the only writer that can retire those epochs. The
 * activePosition pointer is left in place — findActivePosition ignores non-OPEN
 * pointers so the next open starts a fresh epoch, and a curated router close
 * later in the same tx still finds the pointer to enrich. The synthetic CLOSE
 * row carries a deterministic id so that curated close can supersede it (router.ts).
 */
async function detectRouterlessClose(
  context: Context,
  flow: FlowEvent,
  live: NonNullable<Awaited<ReturnType<typeof findActivePosition>>>,
  collateralAfter: bigint,
  debtAfter: bigint
): Promise<boolean> {
  if (collateralAfter !== 0n || debtAfter !== 0n) return false;
  if (live.status !== "OPEN") return false;

  const balances = await readVenueBalances(context, flow);
  if (balances.collateral !== 0n || balances.debt !== 0n) return false;

  // a terminal zero-out is a CLOSE, not an ADJUST: reverse and delete any
  // synthetic ADJUST this tx's earlier flows wrote, then read the restored equity
  await reverseAndSupersedeAdjust(context, { txHash: flow.txHash, positionRowId: live.id });
  const restored = await context.db.find(position, { id: live.id });
  const equity = restored?.equity ?? live.equity;

  // collateralReturned / exitPriceX18 / realizedPnl stay NULL. They are derivable in principle — the
  // collateral that left and was not spent on the repay swap is what reached the owner — but not from
  // what is available here, and a wrong number is worse than an honest unknown.
  //
  // Two reasons, both demonstrated rather than assumed. (1) A swap row carries no token identity, so
  // "the input side of a router swap in this tx" cannot be distinguished from "the position's collateral
  // was sold". A close funded from outside the position — pull an unrelated token, swap it to the debt
  // token, repay, withdraw all collateral to the owner — satisfies every test based on the flow sums and
  // books a phantom profit of nearly the whole withdrawal. (2) exitPriceX18 means the REALIZED fill price
  // everywhere else it is written (router.ts: debtRepaid·WAD / collateralSold), not the oracle mark; on a
  // 1.5-WETH-for-4000-USDC unwind those differ by 50%, and the two figures would disagree on one row.
  //
  // The right home is the execute()-driven close, where the calldata is ours: the ASSERT_FILL names the
  // swap's output currency and amount, which settles both the discrimination and the realized price. A
  // same-tx curated close still supersedes this row and fills these in.
  await context.db.update(position, { id: live.id }).set({
    status: "CLOSED",
    closeTxHash: flow.txHash,
    closedAt: flow.timestamp,
    updatedAt: flow.timestamp,
  });
  await context.db.insert(positionAction).values({
    id: syntheticCloseId(flow.txHash, live.id),
    positionId: live.id,
    type: "CLOSE",
    txHash: flow.txHash,
    logIndex: flow.logIndex,
    blockNumber: flow.blockNumber,
    timestamp: flow.timestamp,
    collateralDelta: 0n, // per-leg deltas are already on the lendingEvent rows
    debtDelta: 0n,
    equityDelta: -equity,
    priceX18: null,
    poolId: null,
  });
  return true;
}

// Morpho SharesMath virtual offsets, mirrored for the shares -> assets conversion below.
const MORPHO_VIRTUAL_SHARES = 1_000_000n;
const MORPHO_VIRTUAL_ASSETS = 1n;

/**
 * The venue's live remaining debt for the liquidated account, in DEBT ASSETS, read at the
 * liquidation block. The stored debtPrincipal lags accrued interest, so both deciding "fully
 * liquidated" and storing the remainder from it can retire a position that still owes accrued
 * debt. Returns null when the venue is unreadable (a flow layer that stages no reserve/market id,
 * or a failed read); the caller then falls back to the stored-principal arithmetic rather than
 * halting a liquidation-storm backfill.
 */
async function readVenueDebt(context: Context, liq: LiquidationEvent): Promise<bigint | null> {
  const { blockNumber } = liq;
  try {
    switch (liq.venue) {
      case "MORPHO": {
        if (!liq.morphoMarketId) return null;
        const [, borrowShares] = await context.client.readContract({
          abi: morphoBlueFunctionsAbi,
          address: deployments.mainnet.morphoBlue,
          functionName: "position",
          args: [liq.morphoMarketId, liq.account],
          blockNumber,
        });
        if (borrowShares === 0n) return 0n;
        const [, , totalBorrowAssets, totalBorrowShares] = await context.client.readContract({
          abi: morphoBlueFunctionsAbi,
          address: deployments.mainnet.morphoBlue,
          functionName: "market",
          args: [liq.morphoMarketId],
          blockNumber,
        });
        // Morpho toAssetsUp with its virtual offsets: never zero for non-zero shares, so a dust
        // remainder cannot round to a false full liquidation.
        const num = borrowShares * (totalBorrowAssets + MORPHO_VIRTUAL_ASSETS);
        const den = totalBorrowShares + MORPHO_VIRTUAL_SHARES;
        return (num + den - 1n) / den;
      }
      case "AAVE_V3": {
        const debtToken = await context.client.readContract({
          abi: aaveV3PoolFunctionsAbi,
          address: deployments.mainnet.aaveV3Pool,
          functionName: "getReserveVariableDebtToken",
          args: [liq.debt],
          blockNumber,
        });
        return await context.client.readContract({
          abi: erc20Abi,
          address: debtToken,
          functionName: "balanceOf",
          args: [liq.account],
          blockNumber,
        });
      }
      case "AAVE_V4": {
        if (liq.debtReserveId === undefined) return null;
        return await context.client.readContract({
          abi: aaveV4SpokeFunctionsAbi,
          address: deployments.mainnet.aaveV4Spoke,
          functionName: "getUserTotalDebt",
          args: [liq.debtReserveId, liq.account],
          blockNumber,
        });
      }
    }
  } catch {
    // fall through: the caller uses the stored-principal arithmetic
  }
  return null;
}

/**
 * Liquidations never emit a router event, so this applies terminally here:
 * amounts, accumulators, and (when the venue reports the debt fully cleared)
 * the LIQUIDATED status. Partial liquidations leave the position OPEN with
 * `liquidated` set. Both the terminal decision AND the stored remainder come
 * from one block-pinned venue read; the clamped subtraction is only the
 * fallback for when that read is unavailable.
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
  // Terminal-state truth comes from the venue: the stored principal lags accrued interest, so a
  // partial liquidation can repay more than the stored value while accrued debt remains, and the
  // clamped subtraction would misclassify it as full. The read is pinned to the liquidation block,
  // so it reflects this event, and it also refreshes the principal; the arithmetic is the fallback.
  const liveDebt = await readVenueDebt(context, liq);
  const remainingDebt = liveDebt ?? clamp0(live.debtPrincipal - debtCleared);
  const fullyLiquidated = remainingDebt === 0n;

  await context.db.update(position, { id: live.id }).set((row) => ({
    collateralAmount: clamp0(row.collateralAmount - liq.seizedCollateral),
    debtPrincipal: remainingDebt,
    liquidated: true,
    liquidatedAt: liq.timestamp,
    liquidationTxHash: liq.txHash,
    seizedCollateral: row.seizedCollateral + liq.seizedCollateral,
    liquidationRepaidDebt: row.liquidationRepaidDebt + liq.repaidDebt,
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
    // A liquidation carries no router-reported LTV, so the mark is an oracle read at its block —
    // softened, since an oracle failure must not halt indexing during a liquidation storm.
    markX18: await readMarkAtBlockSoft({
      context,
      venue: liq.venue,
      collateral: liq.collateral,
      debt: liq.debt,
      morphoMarketId: liq.morphoMarketId ?? null,
      blockNumber: liq.blockNumber,
    }),
    collateralAfter: clamp0(live.collateralAmount - liq.seizedCollateral),
    debtAfter: remainingDebt,
  });

  if (fullyLiquidated) {
    await context.db.delete(activePosition, { id: pairKey(liq.account, liq.collateral, liq.debt) });
  }
}
