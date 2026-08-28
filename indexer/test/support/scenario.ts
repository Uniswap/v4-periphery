/**
 * Synthetic margin scenario builders: minimal event sequences that put the
 * store into a realistic state (account row, market registry rows, an OPEN
 * position epoch) before replaying liquidation-path events.
 */
import { encodeAbiParameters, encodeEventTopics } from "viem";

import { poolManagerSwapAbi } from "../../abis";
import { deployments } from "../../addresses";
import type { Harness, ReadCall } from "./harness";

type Hex = `0x${string}`;

export const WETH: Hex = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
export const USDC: Hex = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
export const ACCOUNT: Hex = "0x00000000000000000000000000000000000000aa";
export const OWNER: Hex = "0x00000000000000000000000000000000000000bb";
export const LIQUIDATOR: Hex = "0x00000000000000000000000000000000000000cc";
export const MORPHO_MARKET_ID: Hex = "0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc";
export const WETH_VARIABLE_DEBT_TOKEN: Hex = "0xea51d7853eefb32b6ee06b1c12e6dcca88be0ffe";
export const USDC_VARIABLE_DEBT_TOKEN: Hex = "0x72e95b8931767c79ba4eee721354d6e99a61d004";
export const AAVE_V4_HUB: Hex = "0xcca852bc40e560adc3b1cc58ca5b55638ce826c9";
export const ZERO: Hex = "0x0000000000000000000000000000000000000000";
export const MORPHO_ORACLE: Hex = "0x00000000000000000000000000000000000000dd";
export const AAVE_ORACLE = deployments.mainnet.aaveOracle;
// $4,000/ETH in each venue's own scaling, chosen to AGREE with the open fixture's currentLtv (0.5 at
// 2 WETH against 4000 USDC) — so the event-derived mark and an oracle read produce the same raw
// 4e9, and a test can assert the two sources agree. Morpho scales by 1e36·10^(debtDec−collDec);
// AaveOracle is 8dp USD per asset.
export const RAW_MARK_X18 = 4000n * 10n ** 6n; // debt raw per collateral raw, ×1e18
export const MORPHO_ORACLE_PRICE = 4000n * 10n ** 24n;
export const WETH_USD_8DP = 4000n * 10n ** 8n;
export const USDC_USD_8DP = 10n ** 8n;

// Every action stamps a venue-oracle mark; stub the price reads so tests assert real marks instead of
// the softened null. Registered first, so a test can still override with its own onRead.
export function stubOracleMarks(harness: Harness): void {
  harness.onRead({ address: MORPHO_ORACLE, functionName: "price" }, MORPHO_ORACLE_PRICE);
  harness.onRead({ address: AAVE_ORACLE, functionName: "getAssetPrice" }, (call: ReadCall) =>
    (call.args?.[0] as Hex)?.toLowerCase() === USDC ? USDC_USD_8DP : WETH_USD_8DP
  );
}

export const MORPHO_BLUE = deployments.mainnet.morphoBlue;
export const AAVE_V3_POOL = deployments.mainnet.aaveV3Pool;
export const AAVE_V4_SPOKE = deployments.mainnet.aaveV4Spoke;

export const E18 = 10n ** 18n;
export const E6 = 10n ** 6n;

export const PREMIUM_DELTA_ZERO = { sharesDelta: 0n, offsetRayDelta: 0n, restoredPremiumRay: 0n };

export const OPEN_TX: Hex = "0x1111111111111111111111111111111111111111111111111111111111111111";
export const LIQ_TX: Hex = "0x2222222222222222222222222222222222222222222222222222222222222222";
export const LIQ_TX_2: Hex = "0x3333333333333333333333333333333333333333333333333333333333333333";

const SETUP_TX: Hex = "0x9999999999999999999999999999999999999999999999999999999999999999";
const SETUP_BLOCK = 25_600_000n;
export const OPEN_BLOCK = 25_600_010n;
export const LIQ_BLOCK = 25_600_020n;
export const LIQ_BLOCK_2 = 25_600_030n;

type Venue = "MORPHO" | "AAVE_V3" | "AAVE_V4";

/**
 * Register the WETH/USDC market for `venue`, create the margin account, and
 * open a 2x-ish position: 1 WETH equity + 1 WETH bought, 4000 USDC debt.
 */
export async function openMarginPosition(
  harness: Harness,
  { venue, openTxHash = OPEN_TX }: { venue: Venue; openTxHash?: Hex }
): Promise<void> {
  let logIndex = 0;
  const setup = (name: string, args: Record<string, unknown>) =>
    harness.dispatch({
      name,
      args,
      txHash: SETUP_TX,
      logIndex: logIndex++,
      blockNumber: SETUP_BLOCK,
      timestamp: SETUP_BLOCK,
    });

  await setup("MarginRouter:AccountCreated", { owner: OWNER, account: ACCOUNT, subId: 0n });

  if (venue === "MORPHO") {
    await setup("MorphoAdapter:MarketSet", {
      id: MORPHO_MARKET_ID,
      collateral: WETH,
      debt: USDC,
      oracle: MORPHO_ORACLE,
      irm: ZERO,
      lltv: 860000000000000000n,
    });
  } else if (venue === "AAVE_V3") {
    await setup("AaveAdapter:MarketSet", { collateral: WETH, debt: USDC, allowed: true });
  } else {
    await setup("AaveV4Adapter:MarketSet", {
      collateral: WETH,
      debt: USDC,
      collateralReserveId: 0n,
      debtReserveId: 7n,
      allowed: true,
    });
  }

  await harness.dispatch({
    name: "MarginRouter:PositionIncreased",
    args: {
      owner: OWNER,
      account: ACCOUNT,
      collateral: WETH,
      debt: USDC,
      equity: E18,
      collateralBought: E18,
      debtDrawn: 4000n * E6,
      collateralTotal: 2n * E18,
      debtTotal: 4000n * E6,
      currentLtv: 500000000000000000n,
      maxLtv: 860000000000000000n,
      healthFactorWad: 2n * E18,
    },
    txHash: openTxHash,
    logIndex: 10,
    blockNumber: OPEN_BLOCK,
    timestamp: OPEN_BLOCK,
  });
}

/** Liquidation event args for the scenario position, by venue. */
export function liquidationEvent({
  venue,
  repaidDebt,
  seizedCollateral,
  badDebt = 0n,
}: {
  venue: Venue;
  repaidDebt: bigint;
  seizedCollateral: bigint;
  badDebt?: bigint;
}): { name: string; args: Record<string, unknown>; logAddress: `0x${string}` } {
  if (venue === "MORPHO") {
    return {
      name: "MorphoBlue:Liquidate",
      logAddress: MORPHO_BLUE,
      args: {
        id: MORPHO_MARKET_ID,
        caller: LIQUIDATOR,
        borrower: ACCOUNT,
        repaidAssets: repaidDebt,
        repaidShares: 0n,
        seizedAssets: seizedCollateral,
        badDebtAssets: badDebt,
        badDebtShares: 0n,
      },
    };
  }
  if (venue === "AAVE_V3") {
    return {
      name: "AaveV3Pool:LiquidationCall",
      logAddress: AAVE_V3_POOL,
      args: {
        collateralAsset: WETH,
        debtAsset: USDC,
        user: ACCOUNT,
        debtToCover: repaidDebt,
        liquidatedCollateralAmount: seizedCollateral,
        liquidator: LIQUIDATOR,
        receiveAToken: false,
      },
    };
  }
  return {
    name: "AaveV4Spoke:LiquidationCall",
    logAddress: AAVE_V4_SPOKE,
    args: {
      collateralReserveId: 0n,
      debtReserveId: 7n,
      user: ACCOUNT,
      liquidator: LIQUIDATOR,
      receiveShares: false,
      debtAmountRestored: repaidDebt,
      drawnSharesLiquidated: repaidDebt,
      premiumDelta: PREMIUM_DELTA_ZERO,
      collateralAmountRemoved: seizedCollateral,
      collateralSharesLiquidated: seizedCollateral,
      collateralSharesToLiquidator: seizedCollateral,
    },
  };
}

/** Stub the venue's block-pinned debt getter to report `remaining` debt for ACCOUNT. */
export function stubChainDebt(harness: Harness, { venue, remaining }: { venue: Venue; remaining: bigint }): void {
  if (venue === "MORPHO") {
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, remaining, 0n]);
    // Morpho reports debt in SHARES, which the handler converts with toAssetsUp; these totals make
    // that conversion the identity (totalBorrowAssets + 1 == totalBorrowShares + VIRTUAL_SHARES), so
    // `remaining` means the same "assets the venue reports" here as it does for the Aave venues.
    // stubMorphoSharePrice overrides this when a test wants the conversion to actually move a value.
    harness.onRead({ address: MORPHO_BLUE, functionName: "market" }, [0n, 0n, 999_999n, 0n, 0n, 0n]);
  } else if (venue === "AAVE_V3") {
    harness.onRead({ address: AAVE_V3_POOL, functionName: "getReserveVariableDebtToken" }, USDC_VARIABLE_DEBT_TOKEN);
    harness.onRead({ address: USDC_VARIABLE_DEBT_TOKEN, functionName: "balanceOf" }, remaining);
  } else {
    harness.onRead({ address: AAVE_V4_SPOKE, functionName: "getUserTotalDebt" }, remaining);
  }
}

/**
 * Stage a v4 Swap into a transaction's receipt, the only way swaps now reach the indexer
 * (`recordTxSwaps` parses the receipt; there is no filtered PoolManager Swap source). Encodes a
 * real log against poolManagerSwapAbi, so the handler's own decode is exercised rather than
 * bypassed.
 */
export function stageSwap(
  harness: Harness,
  args: { txHash: Hex; poolId: Hex; amount0: bigint; amount1: bigint; logIndex: number; sender?: Hex; fee?: number },
): void {
  const { txHash, poolId, amount0, amount1, logIndex, sender = deployments.mainnet.marginRouter as Hex, fee = 500 } = args;
  const topics = encodeEventTopics({
    abi: poolManagerSwapAbi,
    eventName: "Swap",
    args: { id: poolId, sender },
  }) as [Hex, ...Hex[]];
  const data = encodeAbiParameters(
    [
      { name: "amount0", type: "int128" },
      { name: "amount1", type: "int128" },
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "liquidity", type: "uint128" },
      { name: "tick", type: "int24" },
      { name: "fee", type: "uint24" },
    ],
    [amount0, amount1, 0n, 0n, 0, fee],
  );
  harness.onReceiptLogs(txHash, [
    { address: deployments.mainnet.poolManager as Hex, topics, data, logIndex },
  ]);
}

/**
 * Override the Morpho market totals so borrowShares convert to a different assets figure:
 * assets = ceil(shares * (totalBorrowAssets + 1) / (totalBorrowShares + 1_000_000)).
 */
export function stubMorphoSharePrice(
  harness: Harness,
  { totalBorrowAssets, totalBorrowShares }: { totalBorrowAssets: bigint; totalBorrowShares: bigint },
): void {
  harness.onRead({ address: MORPHO_BLUE, functionName: "market" }, [0n, 0n, totalBorrowAssets, totalBorrowShares, 0n, 0n]);
}
