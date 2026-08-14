/**
 * Port-validation cases for the PoC flow-derivation layer merged onto the newer
 * base branch. Groups tests that pin behavior at the seams between the router
 * lifecycle handlers (src/router.ts) and the flow layer (src/lendingFlows.ts).
 */
import { lendingEvent, position, positionAction } from "ponder:schema";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { deployments } from "../addresses";
import { adjustId, eventId, positionId } from "../src/helpers";
import { createHarness, type Harness, type HarnessEvent } from "./support/harness";
import {
  ACCOUNT,
  E18,
  E6,
  MORPHO_BLUE,
  MORPHO_MARKET_ID,
  openMarginPosition,
  OPEN_BLOCK,
  OPEN_TX,
  OWNER,
  stubOracleMarks,
  USDC,
  WETH,
} from "./support/scenario";

type Hex = `0x${string}`;

const MARGIN_ROUTER = deployments.mainnet.marginRouter;

// A tx that stages a COMPOUND_V3 lendingEvent and opens the epoch, distinct from OPEN_TX.
const COMPOUND_TX = ("0x" + "c0".repeat(32)) as Hex;

const ADJUST_TX: Hex = "0x8888888888888888888888888888888888888888888888888888888888888888";
const ADJUST_BLOCK = 25_600_090n;

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

/** A Morpho lending flow in ADJUST_TX (mirrors test/adjust.test.ts). */
function morphoFlow(args: {
  kind: "SUPPLY_COLLATERAL" | "WITHDRAW_COLLATERAL" | "BORROW" | "REPAY";
  assets: bigint;
  logIndex: number;
}): HarnessEvent {
  const { kind, assets, logIndex } = args;
  const name = {
    SUPPLY_COLLATERAL: "MorphoBlue:SupplyCollateral",
    WITHDRAW_COLLATERAL: "MorphoBlue:WithdrawCollateral",
    BORROW: "MorphoBlue:Borrow",
    REPAY: "MorphoBlue:Repay",
  }[kind];
  return {
    name,
    args: { id: MORPHO_MARKET_ID, caller: ACCOUNT, onBehalf: ACCOUNT, receiver: ACCOUNT, assets, shares: 0n },
    txHash: ADJUST_TX,
    txTo: MARGIN_ROUTER,
    logIndex,
    blockNumber: ADJUST_BLOCK,
    timestamp: ADJUST_BLOCK,
    logAddress: MORPHO_BLUE,
  };
}

describe("COMPOUND_V3 venue passthrough through drainFlows", () => {
  it("threads a directly-staged COMPOUND_V3 lendingEvent onto the opened position's venue", async () => {
    // Compound's flow-truth layer is deferred (see src/aave.ts), so no src/ handler ever stages a
    // COMPOUND_V3 lendingEvent. Stage one directly for this (tx, account, pair) so drainFlows'
    // venue-passthrough branch (src/router.ts:74) has a COMPOUND_V3 row to match.
    await harness.context.db.insert(lendingEvent).values({
      id: eventId(COMPOUND_TX, 0),
      txHash: COMPOUND_TX,
      venue: "COMPOUND_V3",
      kind: "SUPPLY_COLLATERAL",
      account: ACCOUNT,
      collateral: WETH,
      debt: USDC,
      assets: 2n * E18,
      blockNumber: OPEN_BLOCK,
      timestamp: OPEN_BLOCK,
      applied: false,
    });

    // Router open for the same pair/tx: drainFlows matches the staged row on (collateral, debt) and
    // threads its venue (currentLtv 0.5 lets resolveMarkX18 derive the mark from totals, no oracle read).
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
      txHash: COMPOUND_TX,
      logIndex: 10,
      blockNumber: OPEN_BLOCK,
      timestamp: OPEN_BLOCK,
    });

    const id = positionId(ACCOUNT, WETH, USDC, COMPOUND_TX);
    const row = await harness.context.db.find(position, { id });
    expect(row).not.toBeNull();
    // src/router.ts:74 set venue = row.venue; :175 adopted it as the opened epoch's venue.
    expect(row!.venue).toBe("COMPOUND_V3");
    expect(row!.status).toBe("OPEN");

    // drainFlows marked the matched row applied:true (src/router.ts:76), proving the match branch ran.
    const staged = await harness.context.db.find(lendingEvent, { id: eventId(COMPOUND_TX, 0) });
    expect(staged!.applied).toBe(true);
  });
});

describe("PositionUpdated live-epoch reconcile coexists with a same-tx synthetic ADJUST", () => {
  // The PositionUpdated live branch (src/router.ts:480-495) is state-only: per its own doc comment it
  // "never touches economics ... or writes a positionAction row". Unlike PositionIncreased/Decreased/
  // CollateralAdded it does NOT call reverseAndSupersedeAdjust, so a flow-layer synthetic ADJUST from
  // an execute plan (its ONLY history row — no curated Position* event follows) survives, while the
  // snapshot reconciles LTV/health/lltv and the running totals. Superseding here would erase that row.
  it("keeps the ADJUST and its equity intact while reconciling the resulting-state snapshot", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" }); // equity E18, collateral 2E18, debt 4000 USDC

    // A Morpho supply flow synthesizes an ADJUST on the live epoch (mirrors adjust.test.ts).
    await harness.dispatch(morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18, logIndex: 0 }));
    const POSITION_ID = positionId(ACCOUNT, WETH, USDC, OPEN_TX);
    const adjustBefore = await harness.context.db.find(positionAction, { id: adjustId(ADJUST_TX, POSITION_ID) });
    expect(adjustBefore).not.toBeNull();
    expect(adjustBefore!.type).toBe("ADJUST");
    const equityAfterFlow = (await harness.context.db.find(position, { id: POSITION_ID }))!.equity;
    expect(equityAfterFlow).toBe(2n * E18); // base E18 + supplied E18

    // Same-tx PositionUpdated snapshot. State distinct from the open fixture (0.5 / 2.0 / 0.86) so the
    // reconcile is observable; a live pre-upgrade router emits this after the execute plan's flows.
    await harness.dispatch({
      name: "MarginRouter:PositionUpdated",
      args: {
        owner: OWNER,
        account: ACCOUNT,
        collateral: WETH,
        debt: USDC,
        collateralTotal: 3n * E18,
        debtTotal: 4000n * E6,
        currentLtv: 600000000000000000n,
        maxLtv: 800000000000000000n,
        healthFactorWad: (3n * E18) / 2n,
      },
      txHash: ADJUST_TX,
      logIndex: 20,
      blockNumber: ADJUST_BLOCK,
      timestamp: ADJUST_BLOCK,
    });

    const adjustAfter = await harness.context.db.find(positionAction, { id: adjustId(ADJUST_TX, POSITION_ID) });
    const row = await harness.context.db.find(position, { id: POSITION_ID });

    // The ADJUST survives untouched: not deleted, and its equity increment not reversed. A supersede
    // would have deleted this row and restored equity to the captured base (E18) — neither happened.
    expect(adjustAfter).not.toBeNull();
    expect(adjustAfter!.type).toBe("ADJUST");
    expect(adjustAfter!.equityDelta).toBe(E18);
    expect(adjustAfter!.collateralDelta).toBe(E18);
    expect(row!.equity).toBe(2n * E18); // still base + supplied; NOT reverted to equityBase E18

    // The snapshot reconciled the resulting-state fields (distinct from the open fixture values).
    expect(row!.status).toBe("OPEN");
    expect(row!.collateralAmount).toBe(3n * E18);
    expect(row!.debtPrincipal).toBe(4000n * E6);
    expect(row!.lastLtvWad).toBe(600000000000000000n);
    expect(row!.lastHealthFactorWad).toBe((3n * E18) / 2n);
    expect(row!.lltv).toBe(800000000000000000n);
  });
});
