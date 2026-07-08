/**
 * Event-only ABIs for every log source the indexer consumes.
 *
 * Signatures are copied verbatim from the audited sources:
 * - MarginRouter / MarginAccountFactory / adapters: this repo (src/)
 * - Morpho Blue: lib/morpho-blue/src/libraries/EventsLib.sol
 * - Aave v3 Pool: aave-v3 IPool (topic hashes verified against live mainnet logs)
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
    name: "PositionOpened",
    inputs: [
      { name: "owner", type: "address", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "collateral", type: "address", indexed: false },
      { name: "debt", type: "address", indexed: false },
      { name: "collateralBought", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "PositionClosed",
    inputs: [
      { name: "owner", type: "address", indexed: true },
      { name: "account", type: "address", indexed: true },
      { name: "collateral", type: "address", indexed: false },
      { name: "debt", type: "address", indexed: false },
      { name: "collateralReturned", type: "uint256", indexed: false },
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
