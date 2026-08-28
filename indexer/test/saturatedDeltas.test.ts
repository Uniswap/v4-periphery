/**
 * Post-audit event saturation, and the swap ordering that pool attribution depends on.
 *
 * The audited router saturates two event deltas to zero so its best-effort event block cannot revert
 * (a permissionless onBehalf repay/supply landing inside the tx can move the position against the
 * operation's direction). A zero delta therefore no longer means "zero", it means "unknown", and a
 * derived price must be null rather than 0.
 */
import { position, positionAction } from "ponder:schema";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { createHarness, type Harness } from "./support/harness";
import {
  ACCOUNT,
  E6,
  E18,
  MORPHO_BLUE,
  MORPHO_MARKET_ID,
  MORPHO_ORACLE,
  OPEN_BLOCK,
  openMarginPosition,
  OWNER,
  stageSwap,
  stubOracleMarks,
  USDC,
  WETH,
  ZERO,
} from "./support/scenario";

type Hex = `0x${string}`;

const TX = ("0x" + "5a".repeat(32)) as Hex;
const ADJUST_TX = ("0x" + "5b".repeat(32)) as Hex;
const ADJUST_BLOCK = OPEN_BLOCK + 40n;

let harness: Harness;

beforeAll(async () => {
  harness = await createHarness();
});
afterAll(async () => {
  await harness.close();
});
beforeEach(async () => {
  await harness.reset();
  stubOracleMarks(harness);
});

/** A Morpho market and account, then one curated open with caller-chosen deltas. */
async function openWith({ debtDrawn, collateralBought }: { debtDrawn: bigint; collateralBought: bigint }) {
  await harness.dispatch({
    name: "MarginRouter:AccountCreated",
    args: { owner: OWNER, account: ACCOUNT, subId: 0n },
    txHash: TX,
    logIndex: 0,
    blockNumber: OPEN_BLOCK,
    timestamp: OPEN_BLOCK,
  });
  await harness.dispatch({
    name: "MorphoAdapter:MarketSet",
    args: {
      id: MORPHO_MARKET_ID,
      collateral: WETH,
      debt: USDC,
      oracle: MORPHO_ORACLE,
      irm: ZERO,
      lltv: 860000000000000000n,
    },
    txHash: TX,
    logIndex: 1,
    blockNumber: OPEN_BLOCK,
    timestamp: OPEN_BLOCK,
  });
  await harness.dispatch({
    name: "MarginRouter:PositionIncreased",
    args: {
      owner: OWNER,
      account: ACCOUNT,
      collateral: WETH,
      debt: USDC,
      equity: E18,
      collateralBought,
      debtDrawn,
      collateralTotal: E18 + collateralBought,
      debtTotal: debtDrawn,
      currentLtv: 500000000000000000n,
      maxLtv: 860000000000000000n,
      healthFactorWad: 2n * E18,
    },
    txHash: TX,
    logIndex: 20,
    blockNumber: OPEN_BLOCK,
    timestamp: OPEN_BLOCK,
  });
  const actions = await harness.db.select().from(positionAction);
  return actions.find((a) => a.type === "OPEN")!;
}

/** A second PositionIncreased on the same pair — the INCREASE branch, where the basis accumulates. */
async function increaseWith({ debtDrawn, collateralBought }: { debtDrawn: bigint; collateralBought: bigint }) {
  await harness.dispatch({
    name: "MarginRouter:PositionIncreased",
    args: {
      owner: OWNER,
      account: ACCOUNT,
      collateral: WETH,
      debt: USDC,
      equity: 0n,
      collateralBought,
      debtDrawn,
      collateralTotal: 10n * E18,
      debtTotal: 10_000n * E6,
      currentLtv: 500000000000000000n,
      maxLtv: 860000000000000000n,
      healthFactorWad: 2n * E18,
    },
    txHash: TX,
    logIndex: 30,
    blockNumber: OPEN_BLOCK,
    timestamp: OPEN_BLOCK,
  });
  const rows = await harness.db.select().from(position);
  return rows[0]!;
}

describe("a saturated debtDrawn reads as an unknown price, not zero", () => {
  it("debtDrawn == 0 with collateral bought -> priceX18 null", async () => {
    const open = await openWith({ debtDrawn: 0n, collateralBought: E18 / 2n });
    // 0 would be a real entry price of zero and would drag avgEntryPriceX18 down permanently
    expect(open.priceX18).toBeNull();
  });

  // An unknown fill must leave NO trace in the basis: the damage is the inflated denominator it would
  // leave behind, not the price on the action row.
  it("opens with an empty cost basis, so the next real increase is not diluted", async () => {
    await openWith({ debtDrawn: 0n, collateralBought: E18 / 2n });
    const opened = (await harness.db.select().from(position))[0]!;
    expect(opened.avgEntryPriceX18).toBeNull();
    expect(opened.totalCollateralBought).toBe(0n);
    expect(opened.totalDebtDrawn).toBe(0n);

    // a normal increase prices at its OWN fill, not half of it
    const after = await increaseWith({ debtDrawn: 2000n * E6, collateralBought: E18 / 2n });
    expect(after.avgEntryPriceX18).toBe(4000n * E6);
  });

  it("a saturated INCREASE leaves an established basis untouched", async () => {
    await openWith({ debtDrawn: 2000n * E6, collateralBought: E18 / 2n });
    const opened = (await harness.db.select().from(position))[0]!;
    expect(opened.avgEntryPriceX18).toBe(4000n * E6);

    const after = await increaseWith({ debtDrawn: 0n, collateralBought: E18 / 2n });
    // without the guard the denominator grows against a standing numerator and this halves to 2000e6
    expect(after.avgEntryPriceX18).toBe(4000n * E6);
    expect(after.totalCollateralBought).toBe(E18 / 2n);
    expect(after.totalDebtDrawn).toBe(2000n * E6);
    // the authoritative totals still come from the event
    expect(after.collateralAmount).toBe(10n * E18);
    expect(after.debtPrincipal).toBe(10_000n * E6);
  });

  it("a normal leveraged open still derives its price", async () => {
    const open = await openWith({ debtDrawn: 2000n * E6, collateralBought: E18 / 2n });
    expect(open.priceX18).toBe(4000n * E6);
  });
});

describe("the flow layer replays staged swaps in numeric log-index order", () => {
  it("attributes the ADJUST pool from the earliest log index, not the lexically smallest id", async () => {
    // Row ids are `${txHash}-${logIndex}` and sort lexically, where "...-10" < "...-9" — so a lexical
    // order attributes pool B. Exercised through the FLOW layer (txSwaps/swapEconomics): the curated
    // handlers use consumeSwaps, which already sorts numerically.
    const poolA = ("0x" + "aa".repeat(32)) as Hex;
    const poolB = ("0x" + "bb".repeat(32)) as Hex;

    await openMarginPosition(harness, { venue: "MORPHO" });

    stageSwap(harness, { txHash: ADJUST_TX, poolId: poolA, amount0: -2000n * E6, amount1: E18 / 2n, logIndex: 9 });
    stageSwap(harness, { txHash: ADJUST_TX, poolId: poolB, amount0: -1000n * E6, amount1: E18 / 4n, logIndex: 10 });

    // an execute-driven borrow + supply with no curated router event: the flow layer synthesizes ADJUST
    for (const [kind, assets, logIndex] of [
      ["BORROW", 3000n * E6, 0],
      ["SUPPLY_COLLATERAL", (E18 * 3n) / 4n, 11],
    ] as const) {
      await harness.dispatch({
        name: kind === "BORROW" ? "MorphoBlue:Borrow" : "MorphoBlue:SupplyCollateral",
        args: { id: MORPHO_MARKET_ID, caller: ACCOUNT, onBehalf: ACCOUNT, receiver: ACCOUNT, assets, shares: 0n },
        txHash: ADJUST_TX,
        logIndex,
        blockNumber: ADJUST_BLOCK,
        timestamp: ADJUST_BLOCK,
        logAddress: MORPHO_BLUE,
      });
    }

    const actions = await harness.db.select().from(positionAction);
    const adjust = actions.find((a) => a.type === "ADJUST");
    expect(adjust).toBeDefined();
    expect(adjust!.poolId).toBe(poolA);
  });
});
