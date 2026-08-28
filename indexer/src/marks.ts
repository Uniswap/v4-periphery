import type { Context } from "ponder:registry";
import { morphoMarketRef, token } from "ponder:schema";
import { aaveOracleAbi, morphoOracleAbi } from "../abis";
import { deployments } from "../addresses";
import { WAD } from "./helpers";

/**
 * The venue-oracle mark for a position action, in the RAW convention used throughout this schema:
 * debt raw units per collateral raw unit, ×1e18, uninverted. `avgEntryPriceX18` and `priceX18` share
 * it; the API layer normalizes decimals and reciprocates for a SHORT.
 *
 * Two sources, in order:
 *  1. The router event's own totals. Exact and free — collateralTotal, debtTotal and currentLtv all
 *     come from one describePosition snapshot, so accrued interest cancels between numerator and
 *     denominator instead of biasing the result.
 *  2. A block-pinned oracle read, for the actions the router reports no usable LTV for: a full close
 *     (the contract emits Ltv.wrap(0)), a liquidation (a protocol event, no router state), a
 *     debt-free position (LTV 0), and the synthetic ADJUST the execute() path produces.
 */

interface MarkParams {
  context: Context;
  venue: string;
  collateral: `0x${string}`;
  debt: `0x${string}`;
  morphoMarketId: `0x${string}` | null;
  blockNumber: bigint;
}

// An LTV at or above 1.0 means the position is past its own collateral value; the router should never
// report it, and dividing by it would yield a mark that silently understates.
const MAX_USABLE_LTV = WAD;

function deriveMarkFromTotals(params: {
  collateralTotal: bigint;
  debtTotal: bigint;
  ltvAfterWad: bigint;
}): bigint | null {
  const { collateralTotal, debtTotal, ltvAfterWad } = params;
  if (collateralTotal <= 0n || debtTotal <= 0n) return null;
  if (ltvAfterWad <= 0n || ltvAfterWad >= MAX_USABLE_LTV) return null;
  // ltv = debt·WAD² / (collateral·mark)  ⇒  mark = debt·WAD² / (collateral·ltv)
  return (debtTotal * WAD * WAD) / (collateralTotal * ltvAfterWad);
}

async function decimalsOf(context: Context, address: `0x${string}`): Promise<number> {
  const row = await context.db.find(token, { address });
  if (row === null) throw new Error(`mark: no token row for ${address}`);
  return row.decimals;
}

/**
 * Oracle mark at a specific block. Morpho reads the market's own oracle; Aave reads the shared
 * AaveOracle's two 8dp USD prices. Throws so the soft wrapper can log why the mark was unavailable.
 */
async function readMarkAtBlock(params: MarkParams): Promise<bigint> {
  const { context, venue, collateral, debt, morphoMarketId, blockNumber } = params;

  if (venue === "MORPHO") {
    if (!morphoMarketId) throw new Error("mark: Morpho action without a market id");
    const ref = await context.db.find(morphoMarketRef, { id: morphoMarketId });
    if (ref === null) throw new Error(`mark: no morphoMarketRef for ${morphoMarketId}`);
    const price = await context.client.readContract({
      abi: morphoOracleAbi,
      address: ref.oracle,
      functionName: "price",
      blockNumber,
    });
    // Morpho scales price by 1e36·10^(debtDec−collDec); the raw ×1e18 form is price/1e18 exactly.
    return price / WAD;
  }

  const [collateralUsd, debtUsd, collateralDecimals, debtDecimals] = await Promise.all([
    context.client.readContract({
      abi: aaveOracleAbi,
      address: deployments.mainnet.aaveOracle,
      functionName: "getAssetPrice",
      args: [collateral],
      blockNumber,
    }),
    context.client.readContract({
      abi: aaveOracleAbi,
      address: deployments.mainnet.aaveOracle,
      functionName: "getAssetPrice",
      args: [debt],
      blockNumber,
    }),
    decimalsOf(context, collateral),
    decimalsOf(context, debt),
  ]);
  if (debtUsd <= 0n) throw new Error("mark: AaveOracle returned a non-positive debt price");
  // Both prices share the 8dp base currency, so it cancels; only the decimal gap remains.
  return (collateralUsd * WAD * 10n ** BigInt(debtDecimals)) / (debtUsd * 10n ** BigInt(collateralDecimals));
}

/**
 * Warn and return null on any failure (unavailable/reverting oracle, missing market ref) so a
 * per-action mark read never halts the indexer — an honest null mark on that action instead. Every
 * per-action mark path goes through here: curated actions, synthetic ADJUSTs, and liquidations,
 * where oracle staleness clusters.
 */
export async function readMarkAtBlockSoft(params: MarkParams): Promise<bigint | null> {
  try {
    return await readMarkAtBlock(params);
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.warn(
      `mark: no oracle mark for ${params.venue} ${params.collateral}/${params.debt} @ block ${params.blockNumber} (${reason}); recording null`
    );
    return null;
  }
}

/** Derive from the event's own totals where they give a usable LTV, else fall through to the oracle. */
export async function resolveMarkX18(
  params: MarkParams & { collateralTotal: bigint; debtTotal: bigint; ltvAfterWad: bigint | null }
): Promise<bigint | null> {
  const { ltvAfterWad, collateralTotal, debtTotal } = params;
  if (ltvAfterWad !== null) {
    const derived = deriveMarkFromTotals({ collateralTotal, debtTotal, ltvAfterWad });
    if (derived !== null) return derived;
  }
  return readMarkAtBlockSoft(params);
}
