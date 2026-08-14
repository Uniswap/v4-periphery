/**
 * D0 gate: the replay harness reproduces current indexer behavior.
 * - Real mainnet Aave v4 liquidation receipts decode against abis.ts and are
 *   filtered by the handlers (borrower is not a margin account) — matrix (g).
 * - A synthetic margin liquidation flips the position's status.
 */
import { position, lendingEvent, activePosition } from "ponder:schema";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { pairKey, positionId } from "../src/helpers";
import { decodeReceiptEvents, loadReceipt } from "./support/fixtures";
import { createHarness, type Harness } from "./support/harness";
import {
  stubOracleMarks,
  ACCOUNT,
  AAVE_V4_SPOKE,
  E6,
  E18,
  LIQ_BLOCK,
  LIQ_TX,
  OPEN_TX,
  USDC,
  WETH,
  liquidationEvent,
  openMarginPosition,
  stubChainDebt,
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

// `args` are the exact decoded LiquidationCall values, re-derived from the receipt JSON
const FIXTURES = [
  {
    file: "receipt-0xb423d2d3.json",
    block: 25524077n,
    args: {
      user: "0x3Dd7D7db118028783F7018A25bB90f6a6449df13",
      collateralReserveId: 3n,
      debtReserveId: 8n,
      debtAmountRestored: 1626586829n,
      collateralAmountRemoved: 2743450n,
    },
  },
  {
    file: "receipt-0x4d935258.json",
    block: 25539964n,
    args: {
      user: "0xb2133716462c85084EBa7C6b807a35BAB00F3A1d",
      collateralReserveId: 0n,
      debtReserveId: 8n,
      debtAmountRestored: 1002884776n,
      collateralAmountRemoved: 546840006484876960n,
    },
  },
];

describe("real Aave v4 liquidation fixtures (matrix g)", () => {
  for (const { file, block, args: expectedArgs } of FIXTURES) {
    it(`${file}: decodes exactly one Spoke LiquidationCall and the handler filters it`, async () => {
      const receipt = loadReceipt(file);
      expect(BigInt(receipt.blockNumber)).toBe(block);

      const events = decodeReceiptEvents({ receipt, contract: "AaveV4Spoke", address: AAVE_V4_SPOKE });
      const liquidations = events.filter((e) => e.name === "AaveV4Spoke:LiquidationCall");
      expect(liquidations).toHaveLength(1);
      expect(liquidations[0]!.args).toMatchObject(expectedArgs);

      // non-margin borrower: handler drops the event before any write
      for (const event of events) {
        await harness.dispatch(event);
      }
      expect(await harness.db.select().from(lendingEvent)).toHaveLength(0);
      expect(await harness.db.select().from(position)).toHaveLength(0);
    });
  }
});

describe("synthetic margin liquidation", () => {
  it("opens an epoch and a full liquidation flips it to LIQUIDATED", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });

    const id = positionId(ACCOUNT, WETH, USDC, OPEN_TX);
    const opened = await harness.context.db.find(position, { id });
    expect(opened).not.toBeNull();
    expect(opened!.status).toBe("OPEN");
    expect(opened!.debtPrincipal).toBe(4000n * E6);

    stubChainDebt(harness, { venue: "MORPHO", remaining: 0n });
    const liq = liquidationEvent({ venue: "MORPHO", repaidDebt: 4000n * E6, seizedCollateral: 2n * E18 });
    await harness.dispatch({ ...liq, txHash: LIQ_TX, logIndex: 3, blockNumber: LIQ_BLOCK, timestamp: LIQ_BLOCK });

    const liquidated = await harness.context.db.find(position, { id });
    expect(liquidated!.status).toBe("LIQUIDATED");
    expect(liquidated!.liquidated).toBe(true);
    expect(liquidated!.liquidationTxHash).toBe(LIQ_TX);
    expect(await harness.context.db.find(activePosition, { id: pairKey(ACCOUNT, WETH, USDC) })).toBeNull();
  });
});
