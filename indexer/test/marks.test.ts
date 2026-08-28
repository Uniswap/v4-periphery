/**
 * IDX-8: the oracle-marks layer survives but is softened — a per-action mark resolution that cannot
 * reach a usable oracle records null PnL for that action instead of throwing and halting the indexer.
 */
import type { Context } from "ponder:registry";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import { readMarkAtBlockSoft, resolveMarkX18 } from "../src/marks";
import { createHarness, type Harness } from "./support/harness";
import { USDC, WETH } from "./support/scenario";

let harness: Harness;

beforeAll(async () => {
  harness = await createHarness();
});
afterAll(async () => {
  await harness.close();
});

describe("resolveMarkX18 softens an unavailable oracle to null", () => {
  it("returns null (not a throw) when the underlying oracle read is unavailable", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    // ltvAfterWad null forces the oracle branch; a MORPHO action with no market id makes
    // readMarkAtBlock throw internally — resolveMarkX18 must catch it and record null.
    const mark = await resolveMarkX18({
      context: harness.context as unknown as Context,
      venue: "MORPHO",
      collateral: WETH,
      debt: USDC,
      morphoMarketId: null,
      blockNumber: 1n,
      collateralTotal: 2n * 10n ** 18n,
      debtTotal: 4000n * 10n ** 6n,
      ltvAfterWad: null,
    });
    expect(mark).toBeNull();
    expect(warn).toHaveBeenCalledOnce();
    warn.mockRestore();
  });

  it("still returns the event-derived mark when the totals give a usable LTV (no oracle read)", async () => {
    const mark = await resolveMarkX18({
      context: harness.context as unknown as Context,
      venue: "MORPHO",
      collateral: WETH,
      debt: USDC,
      morphoMarketId: null, // would throw in the oracle branch, but the derived branch returns first
      blockNumber: 1n,
      collateralTotal: 2n * 10n ** 18n,
      debtTotal: 4000n * 10n ** 6n,
      ltvAfterWad: 500000000000000000n,
    });
    expect(mark).not.toBeNull();
  });
});

describe("readMarkAtBlockSoft is the non-halting per-action mark read", () => {
  // Used by synthetic ADJUSTs and liquidations (lendingFlows.ts) as well as the curated per-action
  // path, so an oracle failure during a liquidation storm records a null mark instead of halting.
  it("returns null (not a throw) when the underlying oracle read fails", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const mark = await readMarkAtBlockSoft({
      context: harness.context as unknown as Context,
      venue: "MORPHO",
      collateral: WETH,
      debt: USDC,
      morphoMarketId: null, // makes readMarkAtBlock throw internally
      blockNumber: 1n,
    });
    expect(mark).toBeNull();
    expect(warn).toHaveBeenCalledOnce();
    warn.mockRestore();
  });
});
