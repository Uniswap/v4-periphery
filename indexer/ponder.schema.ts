import { index, onchainEnum, onchainTable } from "ponder";

/** Lending venue behind a position. Determined by which protocol's events fired in the open tx. */
export const venue = onchainEnum("venue", ["MORPHO", "AAVE_V3", "AAVE_V4", "COMPOUND_V3", "UNKNOWN"]);

/**
 * Position lifecycle. LIQUIDATED means the tracked debt principal reached zero via
 * liquidation; a partially liquidated position stays OPEN with `liquidated = true`.
 */
export const positionStatus = onchainEnum("position_status", ["OPEN", "CLOSED", "LIQUIDATED"]);

export const actionType = onchainEnum("action_type", [
  "OPEN",
  "INCREASE",
  "DECREASE",
  "ADD_COLLATERAL",
  "CLOSE",
  "LIQUIDATION",
  "ADJUST",
]);

export const lendingEventKind = onchainEnum("lending_event_kind", [
  "SUPPLY_COLLATERAL",
  "WITHDRAW_COLLATERAL",
  "BORROW",
  "REPAY",
  "LIQUIDATE",
  "DEFICIT",
]);

/** ERC-20 metadata, populated lazily the first time a token appears. */
export const token = onchainTable("token", (t) => ({
  address: t.hex().primaryKey(),
  symbol: t.text().notNull(),
  decimals: t.integer().notNull(),
}));

/** One row per MarginAccount clone, from the factory's AccountCreated. */
export const account = onchainTable(
  "account",
  (t) => ({
    address: t.hex().primaryKey(),
    chainId: t.integer().notNull(),
    owner: t.hex().notNull(),
    subId: t.bigint().notNull(),
    createdAt: t.bigint().notNull(),
    createdAtBlock: t.bigint().notNull(),
    createdTxHash: t.hex().notNull(),
  }),
  (table) => ({
    ownerIdx: index().on(table.owner),
  })
);

/** Router adapter allowlist state (AdapterAllowed events). */
export const adapter = onchainTable("adapter", (t) => ({
  address: t.hex().primaryKey(),
  venue: venue("venue").notNull(),
  allowed: t.boolean().notNull(),
  updatedAt: t.bigint().notNull(),
}));

/**
 * Current market routing per (venue, collateral, debt), from the adapters'
 * MarketSet events. Later MarketSet events replace earlier rows (as onchain).
 */
export const lendingMarket = onchainTable("lending_market", (t) => ({
  id: t.text().primaryKey(), // `${venue}-${collateral}-${debt}` (lowercase)
  venue: venue("venue").notNull(),
  adapter: t.hex().notNull(),
  collateral: t.hex().notNull(),
  debt: t.hex().notNull(),
  allowed: t.boolean().notNull(),
  // Morpho-specific
  morphoMarketId: t.hex(),
  oracle: t.hex(),
  irm: t.hex(),
  lltv: t.bigint(),
  // Aave v4-specific
  collateralReserveId: t.bigint(),
  debtReserveId: t.bigint(),
  updatedAt: t.bigint().notNull(),
}));

/**
 * Append-only map of every Morpho market id ever registered by the adapter,
 * so historical events (including markets later replaced) always resolve to a
 * (collateral, debt) pair and LLTV.
 */
export const morphoMarketRef = onchainTable("morpho_market_ref", (t) => ({
  id: t.hex().primaryKey(), // Morpho market id
  collateral: t.hex().notNull(),
  debt: t.hex().notNull(),
  oracle: t.hex().notNull(),
  lltv: t.bigint().notNull(),
}));

/** v4 pool metadata from PoolManager Initialize, for the pool sub-label. */
export const pool = onchainTable("pool", (t) => ({
  poolId: t.hex().primaryKey(),
  currency0: t.hex().notNull(),
  currency1: t.hex().notNull(),
  fee: t.integer().notNull(),
  tickSpacing: t.integer().notNull(),
  hooks: t.hex().notNull(),
  createdAt: t.bigint().notNull(),
}));

/**
 * One row per position epoch: from first open until close or full liquidation.
 * A re-open of the same (account, pair) after a terminal state is a new row.
 *
 * Amount conventions: all bigint amounts are raw token units (no decimal
 * scaling); join `token` for decimals. Prices are X18 fixed-point ratios of
 * raw debt units per raw collateral unit; scale by 10^(collateralDecimals -
 * debtDecimals) for a human price.
 */
export const position = onchainTable(
  "position",
  (t) => ({
    id: t.text().primaryKey(), // `${account}-${collateral}-${debt}-${openTxHash}`
    chainId: t.integer().notNull(),
    owner: t.hex().notNull(),
    account: t.hex().notNull(),
    collateral: t.hex().notNull(),
    debt: t.hex().notNull(),
    venue: venue("venue").notNull(),
    status: positionStatus("status").notNull(),

    // True once a curated Position* event has reported this epoch's economics. An epoch first seen
    // through lending flows or a PositionUpdated snapshot (an `execute` plan or owner escape-hatch op,
    // which emit no curated Position* event) stays false: its amounts, LTV, and health are authoritative
    // but equity/leverage/pool/entry price are unknown. The first curated event adopts it and flips true.
    openReported: t.boolean().notNull(),

    // Running amounts, from lending-protocol events where a flow-truth layer exists (Morpho, Aave v3) and
    // reconciled to the router's describePosition totals on every PositionUpdated. For venues with no
    // flow layer yet (Aave v4, Compound v3) PositionUpdated / the curated Position* totals are the only
    // source. debtPrincipal ignores interest accrual between events; live debt must be read onchain.
    collateralAmount: t.bigint().notNull(),
    debtPrincipal: t.bigint().notNull(),

    // Economics accumulated across OPEN/INCREASE actions.
    equity: t.bigint().notNull(), // margin posted, in collateral token units
    totalCollateralBought: t.bigint().notNull(),
    totalDebtDrawn: t.bigint().notNull(),
    avgEntryPriceX18: t.bigint(), // totalDebtDrawn * 1e18 / totalCollateralBought
    // Venue-oracle mark at open, RAW ×1e18. Distinct from avgEntryPriceX18, which is the fill price
    // of the BORROWED leg only and re-averages on every later buy — so it drifts on a pure leverage
    // change and was never the price the owner's own margin went in at. Written once, at open.
    entryMarkX18: t.bigint(),
    // Total collateral at open, raw units. totalCollateralBought is a running high-water figure that
    // no sell decrements, so it cannot answer "how big was this position when it opened".
    collateralAtOpen: t.bigint(),
    leverageX18AtOpen: t.bigint(), // (equity + bought) * 1e18 / equity at first open

    // Open context.
    openTxHash: t.hex().notNull(),
    openedAt: t.bigint().notNull(),
    openBlock: t.bigint().notNull(),
    openPoolId: t.hex(),
    morphoMarketId: t.hex(),
    lltv: t.bigint(), // liquidation LTV (WAD) at open, when known

    // Close context (user-initiated full close).
    closeTxHash: t.hex(),
    closedAt: t.bigint(),
    collateralReturned: t.bigint(),
    exitPriceX18: t.bigint(),
    realizedPnl: t.bigint(), // collateralReturned - equity, collateral units

    // Liquidation context (accumulated across partial liquidations).
    liquidated: t.boolean().notNull(),
    liquidatedAt: t.bigint(),
    liquidationTxHash: t.hex(),
    seizedCollateral: t.bigint().notNull(),
    liquidationRepaidDebt: t.bigint().notNull(),
    badDebt: t.bigint().notNull(),

    // Resulting state from the router's most recent PositionUpdated snapshot (emitted after every
    // mutation on any path, curated or `execute`) or curated Position* event. Snapshots, not live
    // values: interest accrual moves the true LTV between events. `lltv` above carries the paired
    // max/liquidation LTV from the same snapshot.
    lastLtvWad: t.bigint(),
    lastHealthFactorWad: t.bigint(),

    updatedAt: t.bigint().notNull(),
  }),
  (table) => ({
    ownerIdx: index().on(table.owner),
    accountIdx: index().on(table.account),
    statusIdx: index().on(table.status),
  })
);

/**
 * Pointer from (account, pair) to its live position row. A curated close clears it; a router-less
 * close (execute / escape-hatch) terminates the epoch's status but leaves the pointer, so readers
 * must confirm the target is OPEN (see `findActivePosition`). The next open overwrites it.
 */
export const activePosition = onchainTable("active_position", (t) => ({
  id: t.text().primaryKey(), // `${account}-${collateral}-${debt}` (lowercase)
  positionId: t.text().notNull(),
}));

/** One row per lifecycle action, for the transaction-history feed. */
export const positionAction = onchainTable(
  "position_action",
  (t) => ({
    id: t.text().primaryKey(), // `${txHash}-${logIndex}`
    positionId: t.text().notNull(),
    type: actionType("type").notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    // Signed deltas applied by this action, raw token units.
    collateralDelta: t.bigint().notNull(),
    debtDelta: t.bigint().notNull(),
    equityDelta: t.bigint().notNull(),
    // Execution price for actions that swapped (X18 raw ratio, see position).
    priceX18: t.bigint(),
    // Venue-oracle mark at this action, RAW debt-per-collateral ×1e18 (same convention as
    // avgEntryPriceX18 — uninverted; the API layer reciprocates for a SHORT). Derived from the
    // event's own totals where the router reports an LTV, else read from the oracle at this block.
    // Null only when neither was available; a consumer must treat null as "cannot value this action".
    markX18: t.bigint(),
    // Position totals AFTER this action, raw token units. Lets a cost-basis fold value an equity
    // move against the balances it actually applied to.
    collateralAfter: t.bigint(),
    debtAfter: t.bigint(),
    poolId: t.hex(),
    // Resulting position state reported by the router event (null for liquidations,
    // which are protocol events and carry no router-reported state).
    ltvAfterWad: t.bigint(),
    healthFactorWad: t.bigint(),
    // Position equity before this tx's synthetic ADJUST began (execute-driven ops
    // only; null otherwise). The per-flow equity write and its supersession both
    // recompute equity as clamp0(equityBase + equityDelta), so clamp0 is applied
    // once rather than composed — exact and step-order-independent even when an
    // intermediate step would floor equity at 0.
    equityBase: t.bigint(),
  }),
  (table) => ({
    positionIdx: index().on(table.positionId),
    timestampIdx: index().on(table.timestamp),
  })
);

/**
 * Raw margin swaps (v4 Swap events where sender == MarginRouter). Staged for
 * same-tx correlation by router handlers; kept afterward as an audit trail.
 */
export const swapEvent = onchainTable(
  "swap_event",
  (t) => ({
    id: t.text().primaryKey(), // `${txHash}-${logIndex}`
    txHash: t.hex().notNull(),
    poolId: t.hex().notNull(),
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    sqrtPriceX96: t.bigint().notNull(),
    fee: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    consumed: t.boolean().notNull(),
  }),
  (table) => ({
    txIdx: index().on(table.txHash),
  })
);

/**
 * Raw lending-protocol flows attributed to margin accounts. Includes actions
 * that never emit a router event (owner escape-hatch operations), making this
 * the completeness backstop for account history.
 */
export const lendingEvent = onchainTable(
  "lending_event",
  (t) => ({
    id: t.text().primaryKey(), // `${txHash}-${logIndex}`
    txHash: t.hex().notNull(),
    venue: venue("venue").notNull(),
    kind: lendingEventKind("kind").notNull(),
    account: t.hex().notNull(),
    collateral: t.hex(),
    debt: t.hex(),
    morphoMarketId: t.hex(),
    /**
     * The single reserve a staged (null-pair) flow named. Only set while staged: it is what lets a later
     * pair resolution claim ONLY the rows that belong to that pair. Without it, one transaction touching
     * two markets that share a reserve would drain both markets' staged flows into whichever pair
     * resolved first — doubling one position's collateral and leaving the other with debt against zero.
     */
    reserve: t.hex(),
    assets: t.bigint().notNull(), // primary amount (supplied/withdrawn/borrowed/repaid)
    seizedAssets: t.bigint(), // liquidations only
    badDebtAssets: t.bigint(), // liquidations only
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    /** True once this flow's deltas have been applied to a position's running amounts. */
    applied: t.boolean().notNull(),
  }),
  (table) => ({
    txIdx: index().on(table.txHash),
    accountIdx: index().on(table.account),
  })
);
