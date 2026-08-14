/**
 * Liquidation fidelity matrix (plan cases a–f; g lives in harness.test.ts):
 * status transitions come from block-pinned chain-truth debt reads, the
 * arithmetic debtPrincipal update stays for display, and deficit events are
 * bookkept as badDebt without driving terminal transitions themselves.
 */
import { activePosition, lendingEvent, position } from "ponder:schema";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { pairKey, positionId } from "../src/helpers";
import { createHarness, type Harness } from "./support/harness";
import {
  stubOracleMarks,
  AAVE_V3_POOL,
  AAVE_V4_HUB,
  AAVE_V4_SPOKE,
  ACCOUNT,
  E6,
  E18,
  LIQ_BLOCK,
  LIQ_BLOCK_2,
  LIQ_TX,
  LIQ_TX_2,
  OPEN_TX,
  PREMIUM_DELTA_ZERO,
  USDC,
  WETH,
  liquidationEvent,
  openMarginPosition,
  stubChainDebt,
  stubMorphoSharePrice,
} from "./support/scenario";

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

const POSITION_ID = positionId(ACCOUNT, WETH, USDC, OPEN_TX);
const PAIR_KEY = pairKey(ACCOUNT, WETH, USDC);

const findPosition = () => harness.context.db.find(position, { id: POSITION_ID });
const findPointer = () => harness.context.db.find(activePosition, { id: PAIR_KEY });

async function dispatchLiquidation({
  venue,
  repaidDebt,
  seizedCollateral,
  txHash = LIQ_TX,
  logIndex = 3,
  blockNumber = LIQ_BLOCK,
}: {
  venue: "MORPHO" | "AAVE_V3" | "AAVE_V4";
  repaidDebt: bigint;
  seizedCollateral: bigint;
  txHash?: `0x${string}`;
  logIndex?: number;
  blockNumber?: bigint;
}) {
  const liq = liquidationEvent({ venue, repaidDebt, seizedCollateral });
  await harness.dispatch({ ...liq, txHash, logIndex, blockNumber, timestamp: blockNumber });
}

describe("(a) full liquidation, chain debt cleared", () => {
  for (const venue of ["MORPHO", "AAVE_V3", "AAVE_V4"] as const) {
    it(`${venue}: LIQUIDATED + pointer deleted`, async () => {
      await openMarginPosition(harness, { venue });
      stubChainDebt(harness, { venue, remaining: 0n });
      await dispatchLiquidation({ venue, repaidDebt: 4000n * E6, seizedCollateral: 2n * E18 });

      const row = await findPosition();
      expect(row!.status).toBe("LIQUIDATED");
      expect(row!.liquidated).toBe(true);
      expect(row!.debtPrincipal).toBe(0n);
      expect(row!.seizedCollateral).toBe(2n * E18);
      expect(row!.liquidationRepaidDebt).toBe(4000n * E6);
      expect(await findPointer()).toBeNull();

      // classification read is pinned to the liquidation block
      const debtReads = harness.readCalls.filter((call) => call.blockNumber !== undefined);
      expect(debtReads.length).toBeGreaterThan(0);
      for (const call of debtReads) {
        expect(call.blockNumber).toBe(LIQ_BLOCK);
      }
    });
  }
});

describe("(b) partial liquidation, chain debt remains", () => {
  for (const venue of ["MORPHO", "AAVE_V3", "AAVE_V4"] as const) {
    it(`${venue}: stays OPEN with liquidated=true`, async () => {
      await openMarginPosition(harness, { venue });
      stubChainDebt(harness, { venue, remaining: 2000n * E6 });
      await dispatchLiquidation({ venue, repaidDebt: 2000n * E6, seizedCollateral: E18 });

      const row = await findPosition();
      expect(row!.status).toBe("OPEN");
      expect(row!.liquidated).toBe(true);
      expect(row!.liquidationTxHash).toBe(LIQ_TX);
      expect(row!.debtPrincipal).toBe(2000n * E6);
      expect(await findPointer()).not.toBeNull();
    });
  }
});

describe("(c) divergence-A: arithmetic remainder > 0 but chain debt == 0", () => {
  it("MORPHO: LIQUIDATED, and the venue read replaces the arithmetic remainder", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    stubChainDebt(harness, { venue: "MORPHO", remaining: 0n });
    // repaid 3000 of 4000: arithmetic says 1000 left, chain says none
    await dispatchLiquidation({ venue: "MORPHO", repaidDebt: 3000n * E6, seizedCollateral: 2n * E18 });

    const row = await findPosition();
    expect(row!.status).toBe("LIQUIDATED");
    // the venue is the terminal-state truth: the stored principal is refreshed from the read, not
    // left at the stale clamped subtraction (which would show phantom debt on a retired position)
    expect(row!.debtPrincipal).toBe(0n);
    expect(await findPointer()).toBeNull();

    // classification read is pinned to the liquidation block
    const debtReads = harness.readCalls.filter((call) => call.blockNumber !== undefined);
    expect(debtReads.length).toBeGreaterThan(0);
    for (const call of debtReads) {
      expect(call.blockNumber).toBe(LIQ_BLOCK);
    }
  });
});

describe("(d) divergence-B: arithmetic == 0 but chain dust > 0", () => {
  it("AAVE_V3: stays OPEN with liquidated=true", async () => {
    await openMarginPosition(harness, { venue: "AAVE_V3" });
    stubChainDebt(harness, { venue: "AAVE_V3", remaining: 1n }); // interest dust
    await dispatchLiquidation({ venue: "AAVE_V3", repaidDebt: 4000n * E6, seizedCollateral: 2n * E18 });

    const row = await findPosition();
    expect(row!.status).toBe("OPEN");
    expect(row!.liquidated).toBe(true);
    // arithmetic would clamp to 0 and retire the epoch; the venue's dust keeps it open AND stored
    expect(row!.debtPrincipal).toBe(1n);
    expect(await findPointer()).not.toBeNull();

    // classification read is pinned to the liquidation block
    const debtReads = harness.readCalls.filter((call) => call.blockNumber !== undefined);
    expect(debtReads.length).toBeGreaterThan(0);
    for (const call of debtReads) {
      expect(call.blockNumber).toBe(LIQ_BLOCK);
    }
  });
});

describe("(e) partial then full", () => {
  it("AAVE_V4: accumulates across liquidations and terminates on the second", async () => {
    await openMarginPosition(harness, { venue: "AAVE_V4" });

    stubChainDebt(harness, { venue: "AAVE_V4", remaining: 2000n * E6 });
    await dispatchLiquidation({ venue: "AAVE_V4", repaidDebt: 2000n * E6, seizedCollateral: E18 });
    let row = await findPosition();
    expect(row!.status).toBe("OPEN");
    expect(row!.liquidated).toBe(true);

    stubChainDebt(harness, { venue: "AAVE_V4", remaining: 0n });
    await dispatchLiquidation({
      venue: "AAVE_V4",
      repaidDebt: 2000n * E6,
      seizedCollateral: E18,
      txHash: LIQ_TX_2,
      blockNumber: LIQ_BLOCK_2,
    });

    row = await findPosition();
    expect(row!.status).toBe("LIQUIDATED");
    expect(row!.liquidationTxHash).toBe(LIQ_TX_2);
    expect(row!.seizedCollateral).toBe(2n * E18);
    expect(row!.liquidationRepaidDebt).toBe(4000n * E6);
    expect(await findPointer()).toBeNull();
  });
});

describe("(f) deficit liquidations", () => {
  it("AAVE_V3: DeficitCreated (before LiquidationCall) bookkeeps badDebt; chain truth terminates", async () => {
    await openMarginPosition(harness, { venue: "AAVE_V3" });
    stubChainDebt(harness, { venue: "AAVE_V3", remaining: 0n });

    // verified v3 ordering: DeficitCreated fires BEFORE LiquidationCall in the same tx
    await harness.dispatch({
      name: "AaveV3Pool:DeficitCreated",
      args: { user: ACCOUNT, debtAsset: USDC, amountCreated: 500n * E6 },
      txHash: LIQ_TX,
      logIndex: 2,
      blockNumber: LIQ_BLOCK,
      timestamp: LIQ_BLOCK,
      logAddress: AAVE_V3_POOL,
    });

    // deficit alone must NOT terminate the epoch
    let row = await findPosition();
    expect(row!.status).toBe("OPEN");
    expect(row!.badDebt).toBe(500n * E6);
    expect(await findPointer()).not.toBeNull();

    await dispatchLiquidation({ venue: "AAVE_V3", repaidDebt: 3500n * E6, seizedCollateral: 2n * E18, logIndex: 3 });

    row = await findPosition();
    expect(row!.status).toBe("LIQUIDATED");
    expect(row!.badDebt).toBe(500n * E6);
    expect(await findPointer()).toBeNull();

    const deficits = (await harness.db.select().from(lendingEvent)).filter((event) => event.kind === "DEFICIT");
    expect(deficits).toHaveLength(1);
    expect(deficits[0]!.assets).toBe(500n * E6);
    expect(deficits[0]!.badDebtAssets).toBe(500n * E6);
    expect(deficits[0]!.debt).toBe(USDC);
  });

  it("AAVE_V4: ReportDeficit (after LiquidationCall) converts shares and bookkeeps on the closed epoch", async () => {
    await openMarginPosition(harness, { venue: "AAVE_V4" });
    stubChainDebt(harness, { venue: "AAVE_V4", remaining: 0n });
    harness.onRead(
      { address: AAVE_V4_SPOKE, functionName: "getReserve" },
      { underlying: USDC, hub: AAVE_V4_HUB, assetId: 5, decimals: 6, collateralRisk: 0, flags: 12, dynamicConfigKey: 0 }
    );
    harness.onRead({ address: AAVE_V4_HUB, functionName: "previewRestoreByShares" }, 500n * E6);

    // verified v4 ordering: LiquidationCall fires BEFORE ReportDeficit in the same tx
    await dispatchLiquidation({ venue: "AAVE_V4", repaidDebt: 3500n * E6, seizedCollateral: 2n * E18, logIndex: 2 });
    let row = await findPosition();
    expect(row!.status).toBe("LIQUIDATED");
    expect(await findPointer()).toBeNull();

    await harness.dispatch({
      name: "AaveV4Spoke:ReportDeficit",
      args: { reserveId: 7n, user: ACCOUNT, drawnShares: 450n * E6, premiumDelta: PREMIUM_DELTA_ZERO },
      txHash: LIQ_TX,
      logIndex: 3,
      blockNumber: LIQ_BLOCK,
      timestamp: LIQ_BLOCK,
      logAddress: AAVE_V4_SPOKE,
    });

    row = await findPosition();
    expect(row!.status).toBe("LIQUIDATED");
    expect(row!.badDebt).toBe(500n * E6);

    const deficits = (await harness.db.select().from(lendingEvent)).filter((event) => event.kind === "DEFICIT");
    expect(deficits).toHaveLength(1);
    expect(deficits[0]!.assets).toBe(500n * E6); // assets, not shares
    expect(deficits[0]!.debt).toBe(USDC);

    // shares → assets conversion is pinned to the deficit block
    const conversionReads = harness.readCalls.filter((call) => call.functionName === "previewRestoreByShares");
    expect(conversionReads).toHaveLength(1);
    expect(conversionReads[0]!.blockNumber).toBe(LIQ_BLOCK);
    expect(conversionReads[0]!.args).toEqual([5n, 450n * E6]);
  });

  it("filters deficit events for non-margin users", async () => {
    await harness.dispatch({
      name: "AaveV3Pool:DeficitCreated",
      args: { user: "0x00000000000000000000000000000000000000dd", debtAsset: USDC, amountCreated: E6 },
      txHash: LIQ_TX,
      logIndex: 1,
      blockNumber: LIQ_BLOCK,
      timestamp: LIQ_BLOCK,
      logAddress: AAVE_V3_POOL,
    });
    await harness.dispatch({
      name: "AaveV4Spoke:ReportDeficit",
      args: { reserveId: 7n, user: "0x00000000000000000000000000000000000000dd", drawnShares: E6, premiumDelta: PREMIUM_DELTA_ZERO },
      txHash: LIQ_TX,
      logIndex: 2,
      blockNumber: LIQ_BLOCK,
      timestamp: LIQ_BLOCK,
      logAddress: AAVE_V4_SPOKE,
    });
    expect(await harness.db.select().from(lendingEvent)).toHaveLength(0);
  });
});

describe("(g) Morpho reports SHARES, not assets", () => {
  it("converts borrowShares to assets (toAssetsUp) before storing the remainder", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    // 1000e6 shares against a market where 1 share is worth ~2 assets
    stubChainDebt(harness, { venue: "MORPHO", remaining: 1000n * E6 });
    stubMorphoSharePrice(harness, { totalBorrowAssets: 2_000_000n * E6, totalBorrowShares: 1_000_000n * E6 });
    await dispatchLiquidation({ venue: "MORPHO", repaidDebt: 3000n * E6, seizedCollateral: E18 });

    // toAssetsUp: ceil(1000e6 * (2_000_000e6 + 1) / (1_000_000e6 + 1_000_000)) — ~2x the shares, so a
    // handler that stored raw shares would understate the debt by half.
    const expected =
      (1000n * E6 * (2_000_000n * E6 + 1n) + (1_000_000n * E6 + 1_000_000n) - 1n) / (1_000_000n * E6 + 1_000_000n);
    const row = await findPosition();
    expect(row!.debtPrincipal).toBe(expected);
    expect(expected).toBeGreaterThan(1000n * E6);
    expect(row!.status).toBe("OPEN");
  });

  it("rounds a dust share position UP, so it can never read as fully liquidated", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    stubChainDebt(harness, { venue: "MORPHO", remaining: 1n }); // 1 share
    stubMorphoSharePrice(harness, { totalBorrowAssets: 1n, totalBorrowShares: 1_000_000n * E6 });
    await dispatchLiquidation({ venue: "MORPHO", repaidDebt: 4000n * E6, seizedCollateral: 2n * E18 });

    const row = await findPosition();
    expect(row!.debtPrincipal).toBe(1n);
    expect(row!.status).toBe("OPEN");
    expect(await findPointer()).not.toBeNull();
  });
});

describe("(h) unreadable venue falls back to the stored-principal arithmetic", () => {
  it("AAVE_V3: a failing debt-token read does not halt, and does not retire the epoch", async () => {
    await openMarginPosition(harness, { venue: "AAVE_V3" });
    // no stubChainDebt: the getReserveVariableDebtToken read is unstubbed and throws
    await dispatchLiquidation({ venue: "AAVE_V3", repaidDebt: 3000n * E6, seizedCollateral: E18 });

    const row = await findPosition();
    expect(row!.liquidated).toBe(true);
    // arithmetic fallback: 4000 - 3000
    expect(row!.debtPrincipal).toBe(1000n * E6);
    expect(row!.status).toBe("OPEN");
    expect(await findPointer()).not.toBeNull();
  });
});
