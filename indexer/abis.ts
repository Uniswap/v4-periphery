/**
 * Event ABIs for every log source the indexer consumes, plus a small section
 * of function ABIs (at the bottom) for the handlers' chain-truth reads.
 *
 * Signatures are copied verbatim from the audited sources:
 * - MarginRouter / MarginAccountFactory / adapters: this repo (src/, current deployment)
 * - Morpho Blue: lib/morpho-blue/src/libraries/EventsLib.sol
 * - Aave v3 Pool: aave-v3 IPool (topic hashes verified against live mainnet logs)
 * - Aave v4 Spoke: reserveId-keyed flows (topic hashes verified against live mainnet logs; arg layout + names from the verified Spoke impl ABI — ISpoke.sol vendors only the call surface, not events)
 * - Uniswap v4 PoolManager: lib/v4-core IPoolManager
 */

export const marginRouterAbi = [
  {
    type: "event",
    name: "AccountCreated",
    inputs: [
      { name: "owner", type: "address", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "subId", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "AdapterAllowed",
    inputs: [
      { name: "adapter", type: "address", indexed: true },
      { name: "allowed", type: "bool", indexed: false },
    ],
  },
  {
    type: "event",
    name: "PositionIncreased",
    inputs: [
      { name: "owner", type: "address", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "collateral", type: "address", indexed: false },
      { name: "debt", type: "address", indexed: false },
      { name: "equity", type: "uint256", indexed: false },
      { name: "collateralBought", type: "uint256", indexed: false },
      { name: "debtDrawn", type: "uint256", indexed: false },
      { name: "collateralTotal", type: "uint256", indexed: false },
      { name: "debtTotal", type: "uint256", indexed: false },
      { name: "currentLtv", type: "uint256", indexed: false },
      { name: "maxLtv", type: "uint256", indexed: false },
      { name: "healthFactorWad", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "PositionDecreased",
    inputs: [
      { name: "owner", type: "address", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "collateral", type: "address", indexed: false },
      { name: "debt", type: "address", indexed: false },
      { name: "debtRepaid", type: "uint256", indexed: false },
      { name: "collateralWithdrawn", type: "uint256", indexed: false },
      { name: "collateralReturned", type: "uint256", indexed: false },
      { name: "collateralTotal", type: "uint256", indexed: false },
      { name: "debtTotal", type: "uint256", indexed: false },
      { name: "currentLtv", type: "uint256", indexed: false },
      { name: "healthFactorWad", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "CollateralAdded",
    inputs: [
      { name: "owner", type: "address", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "collateral", type: "address", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
      { name: "collateralTotal", type: "uint256", indexed: false },
      { name: "debtTotal", type: "uint256", indexed: false },
      { name: "currentLtv", type: "uint256", indexed: false },
      { name: "healthFactorWad", type: "uint256", indexed: false },
    ],
  },
  {
    // Resulting-state snapshot emitted after every collateral/debt mutation on any path (curated or an
    // `execute` plan), so execute-composed positions are as observable from logs as curated ones.
    type: "event",
    name: "PositionUpdated",
    inputs: [
      { name: "owner", type: "address", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "collateral", type: "address", indexed: false },
      { name: "debt", type: "address", indexed: false },
      { name: "collateralTotal", type: "uint256", indexed: false },
      { name: "debtTotal", type: "uint256", indexed: false },
      { name: "currentLtv", type: "uint256", indexed: false },
      { name: "maxLtv", type: "uint256", indexed: false },
      { name: "healthFactorWad", type: "uint256", indexed: false },
    ],
  },
] as const;

export const morphoAdapterAbi = [
  {
    type: "event",
    name: "MarketSet",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "collateral", type: "address", indexed: true },
      { name: "debt", type: "address", indexed: true },
      { name: "oracle", type: "address", indexed: false },
      { name: "irm", type: "address", indexed: false },
      { name: "lltv", type: "uint256", indexed: false },
    ],
  },
] as const;

export const aaveAdapterAbi = [
  {
    type: "event",
    name: "MarketSet",
    inputs: [
      { name: "collateral", type: "address", indexed: true },
      { name: "debt", type: "address", indexed: true },
      { name: "allowed", type: "bool", indexed: false },
    ],
  },
] as const;

export const aaveV4AdapterAbi = [
  {
    type: "event",
    name: "MarketSet",
    inputs: [
      { name: "collateral", type: "address", indexed: true },
      { name: "debt", type: "address", indexed: true },
      { name: "collateralReserveId", type: "uint256", indexed: false },
      { name: "debtReserveId", type: "uint256", indexed: false },
      { name: "allowed", type: "bool", indexed: false },
    ],
  },
] as const;

export const compoundAdapterAbi = [
  {
    type: "event",
    name: "MarketSet",
    inputs: [
      { name: "collateral", type: "address", indexed: true },
      { name: "debt", type: "address", indexed: true },
      { name: "allowed", type: "bool", indexed: false },
    ],
  },
] as const;

export const morphoBlueAbi = [
  {
    type: "event",
    name: "SupplyCollateral",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "caller", type: "address", indexed: true },
      { name: "onBehalf", type: "address", indexed: true },
      { name: "assets", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "WithdrawCollateral",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "caller", type: "address", indexed: false },
      { name: "onBehalf", type: "address", indexed: true },
      { name: "receiver", type: "address", indexed: true },
      { name: "assets", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Borrow",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "caller", type: "address", indexed: false },
      { name: "onBehalf", type: "address", indexed: true },
      { name: "receiver", type: "address", indexed: true },
      { name: "assets", type: "uint256", indexed: false },
      { name: "shares", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Repay",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "caller", type: "address", indexed: true },
      { name: "onBehalf", type: "address", indexed: true },
      { name: "assets", type: "uint256", indexed: false },
      { name: "shares", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Liquidate",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "caller", type: "address", indexed: true },
      { name: "borrower", type: "address", indexed: true },
      { name: "repaidAssets", type: "uint256", indexed: false },
      { name: "repaidShares", type: "uint256", indexed: false },
      { name: "seizedAssets", type: "uint256", indexed: false },
      { name: "badDebtAssets", type: "uint256", indexed: false },
      { name: "badDebtShares", type: "uint256", indexed: false },
    ],
  },
] as const;

export const aaveV3PoolAbi = [
  {
    type: "event",
    name: "Supply",
    inputs: [
      { name: "reserve", type: "address", indexed: true },
      { name: "user", type: "address", indexed: false },
      { name: "onBehalfOf", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "referralCode", type: "uint16", indexed: true },
    ],
  },
  {
    type: "event",
    name: "Withdraw",
    inputs: [
      { name: "reserve", type: "address", indexed: true },
      { name: "user", type: "address", indexed: true },
      { name: "to", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Borrow",
    inputs: [
      { name: "reserve", type: "address", indexed: true },
      { name: "user", type: "address", indexed: false },
      { name: "onBehalfOf", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "interestRateMode", type: "uint8", indexed: false },
      { name: "borrowRate", type: "uint256", indexed: false },
      { name: "referralCode", type: "uint16", indexed: true },
    ],
  },
  {
    type: "event",
    name: "Repay",
    inputs: [
      { name: "reserve", type: "address", indexed: true },
      { name: "user", type: "address", indexed: true },
      { name: "repayer", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "useATokens", type: "bool", indexed: false },
    ],
  },
  {
    type: "event",
    name: "LiquidationCall",
    inputs: [
      { name: "collateralAsset", type: "address", indexed: true },
      { name: "debtAsset", type: "address", indexed: true },
      { name: "user", type: "address", indexed: true },
      { name: "debtToCover", type: "uint256", indexed: false },
      { name: "liquidatedCollateralAmount", type: "uint256", indexed: false },
      { name: "liquidator", type: "address", indexed: false },
      { name: "receiveAToken", type: "bool", indexed: false },
    ],
  },
  // bad debt written off by a liquidation, in debt-asset units; fires BEFORE
  // the same-tx LiquidationCall (verified against the deployed pool impl)
  {
    type: "event",
    name: "DeficitCreated",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "debtAsset", type: "address", indexed: true },
      { name: "amountCreated", type: "uint256", indexed: false },
    ],
  },
] as const;

/**
 * Aave v4 Main Spoke. Markets are keyed by a per-Spoke `reserveId` (uint256), not
 * an asset address. Flow events index (reserveId, caller, onBehalfOf — the position
 * owner); for margin flows the MarginAccount is its own caller and onBehalfOf, so
 * handlers filter on `onBehalfOf`. LiquidationCall instead indexes
 * (collateralReserveId, debtReserveId, user — the position owner). Data words put
 * shares BEFORE amount on every flow event (verified impl ABI); Repay's trailing
 * tuple is the same PremiumDelta struct LiquidationCall carries.
 */
export const aaveV4SpokeAbi = [
  {
    type: "event",
    name: "Supply",
    inputs: [
      { name: "reserveId", type: "uint256", indexed: true },
      { name: "caller", type: "address", indexed: true },
      { name: "onBehalfOf", type: "address", indexed: true },
      { name: "shares", type: "uint256", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Withdraw",
    inputs: [
      { name: "reserveId", type: "uint256", indexed: true },
      { name: "caller", type: "address", indexed: true },
      { name: "onBehalfOf", type: "address", indexed: true },
      { name: "shares", type: "uint256", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Borrow",
    inputs: [
      { name: "reserveId", type: "uint256", indexed: true },
      { name: "caller", type: "address", indexed: true },
      { name: "onBehalfOf", type: "address", indexed: true },
      { name: "shares", type: "uint256", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Repay",
    inputs: [
      { name: "reserveId", type: "uint256", indexed: true },
      { name: "caller", type: "address", indexed: true },
      { name: "onBehalfOf", type: "address", indexed: true },
      { name: "shares", type: "uint256", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
      {
        name: "premiumDelta",
        type: "tuple",
        indexed: false,
        components: [
          { name: "sharesDelta", type: "int256" },
          { name: "offsetRayDelta", type: "int256" },
          { name: "restoredPremiumRay", type: "uint256" },
        ],
      },
    ],
  },
  {
    type: "event",
    name: "SetUsingAsCollateral",
    inputs: [
      { name: "reserveId", type: "uint256", indexed: true },
      { name: "caller", type: "address", indexed: true },
      { name: "onBehalfOf", type: "address", indexed: true },
      { name: "usingAsCollateral", type: "bool", indexed: false },
    ],
  },
  // names from the verified Spoke impl ABI; `collateralAmountRemoved` is the total
  // collateral assets seized (liquidator portion + treasury fee)
  {
    type: "event",
    name: "LiquidationCall",
    inputs: [
      { name: "collateralReserveId", type: "uint256", indexed: true },
      { name: "debtReserveId", type: "uint256", indexed: true },
      { name: "user", type: "address", indexed: true },
      { name: "liquidator", type: "address", indexed: false },
      { name: "receiveShares", type: "bool", indexed: false },
      { name: "debtAmountRestored", type: "uint256", indexed: false },
      { name: "drawnSharesLiquidated", type: "uint256", indexed: false },
      {
        name: "premiumDelta",
        type: "tuple",
        indexed: false,
        components: [
          { name: "sharesDelta", type: "int256" },
          { name: "offsetRayDelta", type: "int256" },
          { name: "restoredPremiumRay", type: "uint256" },
        ],
      },
      { name: "collateralAmountRemoved", type: "uint256", indexed: false },
      { name: "collateralSharesLiquidated", type: "uint256", indexed: false },
      { name: "collateralSharesToLiquidator", type: "uint256", indexed: false },
    ],
  },
  // bad debt written off by a liquidation, in hub SHARES (convert via the
  // hub's previewRestoreByShares); fires AFTER the same-tx LiquidationCall
  // (topic0 0x59932f333b3a5e3fec86e662babe8dd767529ed207420e7468bd220cdfb3f076,
  // verified against live mainnet logs)
  {
    type: "event",
    name: "ReportDeficit",
    inputs: [
      { name: "reserveId", type: "uint256", indexed: true },
      { name: "user", type: "address", indexed: true },
      { name: "drawnShares", type: "uint256", indexed: false },
      {
        name: "premiumDelta",
        type: "tuple",
        indexed: false,
        components: [
          { name: "sharesDelta", type: "int256" },
          { name: "offsetRayDelta", type: "int256" },
          { name: "restoredPremiumRay", type: "uint256" },
        ],
      },
    ],
  },
] as const;

export const poolManagerInitAbi = [
  {
    type: "event",
    name: "Initialize",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "currency0", type: "address", indexed: true },
      { name: "currency1", type: "address", indexed: true },
      { name: "fee", type: "uint24", indexed: false },
      { name: "tickSpacing", type: "int24", indexed: false },
      { name: "hooks", type: "address", indexed: false },
      { name: "sqrtPriceX96", type: "uint160", indexed: false },
      { name: "tick", type: "int24", indexed: false },
    ],
  },
] as const;

export const poolManagerSwapAbi = [
  {
    type: "event",
    name: "Swap",
    inputs: [
      { name: "id", type: "bytes32", indexed: true },
      { name: "sender", type: "address", indexed: true },
      { name: "amount0", type: "int128", indexed: false },
      { name: "amount1", type: "int128", indexed: false },
      { name: "sqrtPriceX96", type: "uint160", indexed: false },
      { name: "liquidity", type: "uint128", indexed: false },
      { name: "tick", type: "int24", indexed: false },
      { name: "fee", type: "uint24", indexed: false },
    ],
  },
] as const;

/**
 * Function ABIs for the handlers' block-pinned chain reads: liquidation
 * classification (remaining venue debt) and v4 deficit share conversion.
 * All signatures verified against live mainnet contracts.
 */

export const morphoBlueFunctionsAbi = [
  // LIQUIDATED iff borrowShares == 0
  {
    type: "function",
    name: "position",
    stateMutability: "view",
    inputs: [
      { name: "id", type: "bytes32" },
      { name: "user", type: "address" },
    ],
    outputs: [
      { name: "supplyShares", type: "uint256" },
      { name: "borrowShares", type: "uint128" },
      { name: "collateral", type: "uint128" },
    ],
  },
  // market totals for the borrowShares -> assets conversion (Morpho SharesMath)
  {
    type: "function",
    name: "market",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      { name: "totalSupplyAssets", type: "uint128" },
      { name: "totalSupplyShares", type: "uint128" },
      { name: "totalBorrowAssets", type: "uint128" },
      { name: "totalBorrowShares", type: "uint128" },
      { name: "lastUpdate", type: "uint128" },
      { name: "fee", type: "uint128" },
    ],
  },
] as const;

export const aaveV3PoolFunctionsAbi = [
  // resolves the reserve's variableDebtToken; remaining debt = balanceOf(account)
  {
    type: "function",
    name: "getReserveVariableDebtToken",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ type: "address" }],
  },
  // resolves the reserve's aToken; supplied balance = balanceOf(account)
  {
    type: "function",
    name: "getReserveAToken",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ type: "address" }],
  },
] as const;

export const aaveV4SpokeFunctionsAbi = [
  // drawn debt + accrued premium for the user on a reserve
  {
    type: "function",
    name: "getUserTotalDebt",
    stateMutability: "view",
    inputs: [
      { name: "reserveId", type: "uint256" },
      { name: "user", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  // reserve routing: underlying asset + hub and hub-side assetId
  {
    type: "function",
    name: "getReserve",
    stateMutability: "view",
    inputs: [{ name: "reserveId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "underlying", type: "address" },
          { name: "hub", type: "address" },
          { name: "assetId", type: "uint16" },
          { name: "decimals", type: "uint8" },
          { name: "collateralRisk", type: "uint24" },
          { name: "flags", type: "uint8" },
          { name: "dynamicConfigKey", type: "uint32" },
        ],
      },
    ],
  },
  // underlying supplied by the user on a reserve
  {
    type: "function",
    name: "getUserSuppliedAssets",
    stateMutability: "view",
    inputs: [
      { name: "reserveId", type: "uint256" },
      { name: "user", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
] as const;

export const aaveV4HubFunctionsAbi = [
  // hub shares -> underlying assets at the pinned block
  {
    type: "function",
    name: "previewRestoreByShares",
    stateMutability: "view",
    inputs: [
      { name: "assetId", type: "uint256" },
      { name: "shares", type: "uint256" },
    ],
    outputs: [{ type: "uint256" }],
  },
] as const;

/** Morpho market oracle: price of 1 collateral in debt, scaled 1e36·10^(debtDec−collDec). */
export const morphoOracleAbi = [
  {
    type: "function",
    name: "price",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

/** AaveOracle: asset price in the 8dp base currency (USD). */
export const aaveOracleAbi = [
  {
    type: "function",
    name: "getAssetPrice",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

/**
 * The MarginAccount clone's own events (IMarginAccount). Indexed via a Ponder factory keyed on the
 * router's AccountCreated, so every clone is covered without knowing addresses up front.
 *
 * Used ONLY to resolve an Aave flow's (collateral, debt) pair. An Aave event names one reserve, and the
 * registry cannot pick a pair when several markets share that reserve in the same role — these events
 * name both currencies explicitly. Amounts stay the venue events' job: `recordFlow` is the single
 * writer, and reading amounts here would double-count.
 *
 * Do NOT reach for CollateralWithdrawn.amount as an amount source: it is the account's own balance
 * DELTA, and Morpho and Aave v3 both deliver straight to the final recipient, so it reads 0 on two of
 * the three live venues (real only on Aave v4).
 */
export const marginAccountAbi = [
  {
    type: "event",
    name: "CollateralSupplied",
    inputs: [
      { name: "caller", type: "address", indexed: true },
      { name: "adapter", type: "address", indexed: true },
      { name: "collateral", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Borrowed",
    inputs: [
      { name: "caller", type: "address", indexed: true },
      { name: "adapter", type: "address", indexed: true },
      { name: "debt", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "to", type: "address", indexed: false },
    ],
  },
] as const;
