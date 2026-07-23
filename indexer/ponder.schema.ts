import { index, onchainEnum, onchainTable } from "ponder";

/** Lending venue behind a position. Determined by which protocol's events fired in the open tx. */
export const venue = onchainEnum("venue", ["MORPHO", "AAVE_V3", "AAVE_V4", "UNKNOWN"]);

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
]);

export const lendingEventKind = onchainEnum("lending_event_kind", [
  "SUPPLY_COLLATERAL",
  "WITHDRAW_COLLATERAL",
  "BORROW",
  "REPAY",
  "LIQUIDATE",
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

    // True once a router lifecycle event has reported this epoch's economics. An epoch first seen
    // through lending-protocol flows (an `execute` plan or owner escape-hatch op, which emit no
    // router event) stays false: its amounts are authoritative but equity/leverage/pool/entry price
    // are unknown. The first router event on such an epoch adopts it and flips this true.
    openReported: t.boolean().notNull(),

    // Running amounts maintained from lending-protocol events (source of truth).
    // debtPrincipal ignores interest accrual; live debt must be read onchain.
    collateralAmount: t.bigint().notNull(),
    debtPrincipal: t.bigint().notNull(),

    // Economics accumulated across OPEN/INCREASE actions.
    equity: t.bigint().notNull(), // margin posted, in collateral token units
    totalCollateralBought: t.bigint().notNull(),
    totalDebtDrawn: t.bigint().notNull(),
    avgEntryPriceX18: t.bigint(), // totalDebtDrawn * 1e18 / totalCollateralBought
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

    // Resulting state reported by the router on the most recent lifecycle event.
    // Snapshots, not live values: interest accrual moves the true LTV between events.
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
    poolId: t.hex(),
    // Resulting position state reported by the router event (null for liquidations,
    // which are protocol events and carry no router-reported state).
    ltvAfterWad: t.bigint(),
    healthFactorWad: t.bigint(),
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
