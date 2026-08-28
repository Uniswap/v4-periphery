/**
 * Flow-layer ADJUST synthesis: an `execute` plan emits venue flows (and margin
 * swaps) but no router lifecycle event. When such flows apply to a live epoch,
 * the flow layer synthesizes a single `positionAction` type ADJUST per tx and
 * moves `equity` (swap-relative, so leverage bought/sold is excluded), keying
 * the row `${txHash}-${positionId}-adjust`. A curated router event later in the
 * same tx supersedes the synthetic row (deletes it, reverses its increments)
 * and applies its own authoritative economics. A terminal zero-out is a CLOSE
 * not an ADJUST, and also supersedes any same-tx synthetic ADJUST.
 */
import { activePosition, position, positionAction, swapEvent } from "ponder:schema";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { adjustId, pairKey, positionId, syntheticCloseId } from "../src/helpers";
import { createHarness, type Harness, type HarnessEvent } from "./support/harness";
import {
  liquidationEvent,
  RAW_MARK_X18,
  stageSwap, stubOracleMarks, ACCOUNT, E18, E6, MORPHO_BLUE, MORPHO_MARKET_ID, MORPHO_ORACLE, openMarginPosition, OPEN_TX, OWNER, USDC, WETH, ZERO } from "./support/scenario";

type Hex = `0x${string}`;

const ADJUST_TX: Hex = "0x8888888888888888888888888888888888888888888888888888888888888888";
const ADJUST_BLOCK = 25_600_090n;
const POOL_ID: Hex = "0x00000000000000000000000000000000000000000000000000000000cafe0001";
// A tx that opens an epoch from flows alone, with no router event.
const FLOW_OPEN_TX: Hex = "0x7777777777777777777777777777777777777777777777777777777777777777";

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
const positionRow = () => harness.context.db.find(position, { id: POSITION_ID });
const adjustRow = (txHash: Hex = ADJUST_TX) => harness.context.db.find(positionAction, { id: adjustId(txHash, POSITION_ID) });
const actionsOfType = async (type: string) => (await harness.db.select().from(positionAction)).filter((a) => a.type === type);

// WETH (collateral) sorts above USDC (debt): token0 = USDC, token1 = WETH.
// A v4 Swap amount is the swapper delta: negative = paid in, positive = received.
function morphoFlow(args: {
  kind: "SUPPLY_COLLATERAL" | "WITHDRAW_COLLATERAL" | "BORROW" | "REPAY";
  assets: bigint;
  logIndex: number;
  txHash?: Hex;
}): HarnessEvent {
  const { kind, assets, logIndex, txHash = ADJUST_TX } = args;
  const name = {
    SUPPLY_COLLATERAL: "MorphoBlue:SupplyCollateral",
    WITHDRAW_COLLATERAL: "MorphoBlue:WithdrawCollateral",
    BORROW: "MorphoBlue:Borrow",
    REPAY: "MorphoBlue:Repay",
  }[kind];
  return {
    name,
    args: { id: MORPHO_MARKET_ID, caller: ACCOUNT, onBehalf: ACCOUNT, receiver: ACCOUNT, assets, shares: 0n },
    txHash,
    logIndex,
    blockNumber: ADJUST_BLOCK,
    timestamp: ADJUST_BLOCK,
    logAddress: MORPHO_BLUE,
  };
}

/**
 * Stage a margin swap for the tx. Swaps are no longer their own indexed source: the router and
 * flow layers parse them out of the transaction receipt, so a test declares them up front rather
 * than dispatching them in log order.
 */
function swap(args: { amount0: bigint; amount1: bigint; logIndex: number; txHash?: Hex }): void {
  const { amount0, amount1, logIndex, txHash = ADJUST_TX } = args;
  stageSwap(harness, { txHash, poolId: POOL_ID, amount0, amount1, logIndex });
}

describe("execute-driven ADJUST synthesis (no router event)", () => {
  // A SPLIT arrives as several fills in one tx. Every path trades the market's own pair — each split
  // pool is validated against the market before encoding — so the amounts add up in the market's two
  // currencies and the folded price is correct. MULTI-HOP is the shape that would break this, and it
  // cannot reach here: the encoder has no path opcode, discovery drops multi-hop candidates, and the
  // client audit refuses them.
  it("folds a SPLIT correctly: 3000 USDC across two fills for 0.5 WETH is 6000/WETH", async () => {
    swap({ amount0: -2000n * E6, amount1: E18 / 4n, logIndex: 1 });
    swap({ amount0: -1000n * E6, amount1: E18 / 4n, logIndex: 2 });

    await openMarginPosition(harness, { venue: "MORPHO" });

    await harness.dispatch(morphoFlow({ kind: "BORROW", assets: 3000n * E6, logIndex: 0 }));
    await harness.dispatch(morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18, logIndex: 3 }));

    const adjust = await adjustRow();
    // buyDebt 3000 USDC / bought 0.5 WETH.
    expect(adjust!.priceX18).toBe(6000n * E6);
    expect(adjust!.collateralDelta).toBe(E18);
    expect(adjust!.debtDelta).toBe(3000n * E6);
    // equity in = supplied − bought.
    expect(adjust!.equityDelta).toBe(E18 / 2n);
  });

  it("withdraw-only → equity decrements, one ADJUST with negative collateral/equity delta", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });

    await harness.dispatch(morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: E18 / 2n, logIndex: 0 }));

    const row = await positionRow();
    expect(row!.status).toBe("OPEN");
    expect(row!.equity).toBe(E18 / 2n); // E18 - withdrawn(E18/2); no swap → all equity out

    const adjust = await adjustRow();
    expect(adjust).not.toBeNull();
    expect(adjust!.type).toBe("ADJUST");
    expect(adjust!.collateralDelta).toBe(-(E18 / 2n));
    expect(adjust!.debtDelta).toBe(0n);
    expect(adjust!.equityDelta).toBe(-(E18 / 2n));
    expect(await actionsOfType("ADJUST")).toHaveLength(1);
  });

  it("add+borrow (buy leg) → equityIn = supplied − bought, priceX18 derived, swap NOT consumed, avgEntry updated", async () => {
    swap({ amount0: -2000n * E6, amount1: E18 / 2n, logIndex: 1 }); // pay USDC, receive WETH

    await openMarginPosition(harness, { venue: "MORPHO" });

    // borrow 2000 USDC, swap it for 0.5 WETH, supply 1 WETH (0.5 fresh + 0.5 bought)
    await harness.dispatch(morphoFlow({ kind: "BORROW", assets: 2000n * E6, logIndex: 0 }));
    await harness.dispatch(morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18, logIndex: 2 }));

    const row = await positionRow();
    expect(row!.equity).toBe(E18 + E18 / 2n); // base E18 + (supplied E18 − bought 0.5)
    expect(row!.totalCollateralBought).toBe(E18 + E18 / 2n);
    expect(row!.totalDebtDrawn).toBe(4000n * E6 + 2000n * E6);
    expect(row!.avgEntryPriceX18).toBe(4000n * E6);

    const adjust = await adjustRow();
    expect(adjust!.equityDelta).toBe(E18 / 2n); // supplied − bought
    expect(adjust!.debtDelta).toBe(2000n * E6);
    expect(adjust!.collateralDelta).toBe(E18);
    expect(adjust!.priceX18).toBe(4000n * E6); // buyDebt * WAD / bought
    expect(adjust!.poolId).toBe(POOL_ID);
    expect(await actionsOfType("ADJUST")).toHaveLength(1);

    // synthesis peeks but never consumes: the swap stays available for a curated router handler
    const swaps = await harness.db.select().from(swapEvent);
    expect(swaps).toHaveLength(1);
    expect(swaps[0]!.consumed).toBe(false);
  });

  it("buy leg on a NATIVE-keyed pool → collateral is token0, equity still excludes the bought leverage", async () => {
    swap({ amount0: E18 / 2n, amount1: -2000n * E6, logIndex: 1 }); // receive ETH, pay USDC

    await openMarginPosition(harness, { venue: "MORPHO" });

    // Same economics as (b), routed through the native ETH/USDC pool instead. Its currency0 is the
    // native sentinel, so the collateral leg is amount0 and the debt leg amount1 — the reverse of the
    // WETH-keyed pool. Address-sorting the market pair (WETH > USDC) picks the wrong side.
    await harness.dispatch(morphoFlow({ kind: "BORROW", assets: 2000n * E6, logIndex: 0 }));
    await harness.dispatch(morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18, logIndex: 2 }));

    const row = await positionRow();
    expect(row!.equity).toBe(E18 + E18 / 2n); // base + (supplied − bought), NOT base + supplied
    expect(row!.totalCollateralBought).toBe(E18 + E18 / 2n);
    expect(row!.totalDebtDrawn).toBe(4000n * E6 + 2000n * E6);

    const adjust = await adjustRow();
    expect(adjust!.equityDelta).toBe(E18 / 2n);
    expect(adjust!.priceX18).toBe(4000n * E6);
  });

  it("sell leg on a NATIVE-keyed pool → collateral sold is token0, excluded from equityOut", async () => {
    swap({ amount0: -(E18 / 4n), amount1: 1000n * E6, logIndex: 2 }); // pay ETH, receive USDC

    await openMarginPosition(harness, { venue: "MORPHO" });

    await harness.dispatch(morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18 / 2n, logIndex: 0 }));
    await harness.dispatch(morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: E18 / 4n, logIndex: 1 }));
    await harness.dispatch(morphoFlow({ kind: "REPAY", assets: 1000n * E6, logIndex: 3 }));

    const adjust = await adjustRow();
    // withdrawn(0.25) − sold(0.25) = 0, so the sale is leverage, not an owner withdrawal
    expect(adjust!.equityDelta).toBe(E18 / 2n);
    expect(adjust!.debtDelta).toBe(-(1000n * E6));
  });

  // The discriminating case for equity attribution: ONE transaction that both sells collateral as
  // leverage AND hands real equity back to the owner. The swap-relative form has to separate them —
  // booking the whole withdrawal as an owner exit understates equity, booking none of it overstates.
  // Mark and size at open. router.ts pins these on a curated open; a flow-created epoch never reaches
  // that code, so without pinning them here buildCostBasis falls back and every execute()-driven
  // position renders an entry price of 0 and an opened leverage of 0.
  it("a flow-created epoch pins entryMarkX18 / collateralAtOpen / leverageX18AtOpen", async () => {
    swap({ amount0: -2000n * E6, amount1: E18 / 2n, logIndex: 1, txHash: FLOW_OPEN_TX });

    // Register the market and the account, but do NOT open a position — the epoch must come from flows
    // alone, with no router event anywhere.
    await harness.dispatch({
      name: "MarginRouter:AccountCreated",
      args: { owner: OWNER, account: ACCOUNT, subId: 0n },
      txHash: FLOW_OPEN_TX,
      logIndex: 0,
      blockNumber: ADJUST_BLOCK,
      timestamp: ADJUST_BLOCK,
    });
    await harness.dispatch({
      name: "MorphoAdapter:MarketSet",
      args: { id: MORPHO_MARKET_ID, collateral: WETH, debt: USDC, oracle: MORPHO_ORACLE, irm: ZERO, lltv: 860000000000000000n },
      txHash: FLOW_OPEN_TX,
      logIndex: 0,
      blockNumber: ADJUST_BLOCK,
      timestamp: ADJUST_BLOCK,
    });

    await harness.dispatch(morphoFlow({ kind: "BORROW", assets: 2000n * E6, logIndex: 0, txHash: FLOW_OPEN_TX }));
    await harness.dispatch(
      morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18 + E18 / 2n, logIndex: 2, txHash: FLOW_OPEN_TX }),
    );

    const rows = await harness.db.select().from(position);
    const row = rows.find((r) => r.openTxHash === FLOW_OPEN_TX);
    expect(row).toBeDefined();
    expect(row!.entryMarkX18).toBe(RAW_MARK_X18);
    // end-of-tx collateral, not the first flow's — the supply and the bought leverage can arrive in
    // either order, so the figure has to settle rather than latch on the first write
    expect(row!.collateralAtOpen).toBe(E18 + E18 / 2n);
    // equity = supplied(1.5) − bought(0.5) = 1.0, so 1.5 collateral is 1.5x
    expect(row!.leverageX18AtOpen).toBe((E18 * 3n) / 2n);
  });

  it("delever + withdraw equity in one tx → only the owner-bound portion leaves equity", async () => {
    swap({ amount0: 1000n * E6, amount1: -(E18 / 4n), logIndex: 1 }); // receive USDC, pay WETH

    await openMarginPosition(harness, { venue: "MORPHO" });

    // withdraw 0.75 WETH: 0.25 funds the swap that repays 1000 USDC, 0.5 goes to the owner.
    await harness.dispatch(morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: (E18 * 3n) / 4n, logIndex: 0 }));
    await harness.dispatch(morphoFlow({ kind: "REPAY", assets: 1000n * E6, logIndex: 2 }));

    const adjust = await adjustRow();
    // withdrawn(0.75) − sold(0.25) = 0.5 out, NOT the full 0.75
    expect(adjust!.equityDelta).toBe(-(E18 / 2n));
    expect(adjust!.debtDelta).toBe(-(1000n * E6));
  });

  it("add+repay (sell leg) → debtDelta < 0, equityIn = supplied, collateralSold excluded from equityOut", async () => {
    swap({ amount0: 1000n * E6, amount1: -(E18 / 4n), logIndex: 2 }); // receive USDC, pay WETH

    await openMarginPosition(harness, { venue: "MORPHO" });

    // supply 0.5 WETH fresh; withdraw 0.25 WETH, sell it for 1000 USDC, repay 1000 USDC
    await harness.dispatch(morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18 / 2n, logIndex: 0 }));
    await harness.dispatch(morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: E18 / 4n, logIndex: 1 }));
    await harness.dispatch(morphoFlow({ kind: "REPAY", assets: 1000n * E6, logIndex: 3 }));

    const row = await positionRow();
    expect(row!.status).toBe("OPEN");
    expect(row!.equity).toBe(E18 + E18 / 2n); // base E18 + fresh equity 0.5; sold collateral is not equity out
    expect(row!.totalCollateralBought).toBe(E18); // untouched: no buy leg
    expect(row!.totalDebtDrawn).toBe(4000n * E6);

    const adjust = await adjustRow();
    expect(adjust!.debtDelta).toBe(-(1000n * E6)); // negative: net repay
    expect(adjust!.collateralDelta).toBe(E18 / 4n); // supplied 0.5 − withdrawn 0.25
    expect(adjust!.equityDelta).toBe(E18 / 2n); // equityIn = supplied 0.5 − bought 0; equityOut = clamp0(withdrawn 0.25 − sold 0.25) = 0
    expect(await actionsOfType("ADJUST")).toHaveLength(1);
  });
});

describe("curated router event supersedes the synthetic ADJUST", () => {
  it("same-tx PositionIncreased → no ADJUST survives, economics match router-only, poolId intact", async () => {
    swap({ amount0: -2000n * E6, amount1: E18 / 2n, logIndex: 1 });

    await openMarginPosition(harness, { venue: "MORPHO" });

    // same flows as (b) synthesize an ADJUST first
    await harness.dispatch(morphoFlow({ kind: "BORROW", assets: 2000n * E6, logIndex: 0 }));
    await harness.dispatch(morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18, logIndex: 2 }));
    expect(await adjustRow()).not.toBeNull();

    // curated router increase, same tx: authoritative economics
    await harness.dispatch({
      name: "MarginRouter:PositionIncreased",
      args: {
        owner: OWNER,
        account: ACCOUNT,
        collateral: WETH,
        debt: USDC,
        equity: E18 / 2n,
        collateralBought: E18 / 2n,
        debtDrawn: 2000n * E6,
        collateralTotal: 3n * E18,
        debtTotal: 6000n * E6,
        currentLtv: 500000000000000000n,
        maxLtv: 860000000000000000n,
        healthFactorWad: 2n * E18,
      },
      txHash: ADJUST_TX,
      logIndex: 20,
      blockNumber: ADJUST_BLOCK,
      timestamp: ADJUST_BLOCK,
    });

    // synthetic ADJUST is gone; its equity/economics increments were reversed
    expect(await adjustRow()).toBeNull();
    expect(await actionsOfType("ADJUST")).toHaveLength(0);

    const row = await positionRow();
    expect(row!.equity).toBe(E18 + E18 / 2n); // base E18 + router equity 0.5 (as if no synthesis happened)
    expect(row!.totalCollateralBought).toBe(E18 + E18 / 2n);
    expect(row!.totalDebtDrawn).toBe(6000n * E6);
    expect(row!.avgEntryPriceX18).toBe(4000n * E6);
    expect(row!.collateralAmount).toBe(3n * E18);
    expect(row!.debtPrincipal).toBe(6000n * E6);

    // the router INCREASE action carries the pool: synthesis never consumed the swap
    const increases = await actionsOfType("INCREASE");
    expect(increases).toHaveLength(1);
    expect(increases[0]!.poolId).toBe(POOL_ID);
    const swaps = await harness.db.select().from(swapEvent);
    expect(swaps[0]!.consumed).toBe(true);
  });
});

describe("terminal zero-out is a CLOSE, not an ADJUST", () => {
  it("full unwind via execute in one tx → synthetic CLOSE, no surviving ADJUST", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 0n, 0n]);

    // repay full then withdraw full, same tx: the withdraw zeroes both legs
    await harness.dispatch(morphoFlow({ kind: "REPAY", assets: 4000n * E6, logIndex: 0 }));
    await harness.dispatch(morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: 2n * E18, logIndex: 1 }));

    const row = await positionRow();
    expect(row!.status).toBe("CLOSED");

    // the earlier repay flow's ADJUST is superseded by the close path
    expect(await adjustRow()).toBeNull();
    expect(await actionsOfType("ADJUST")).toHaveLength(0);

    const closes = await actionsOfType("CLOSE");
    expect(closes).toHaveLength(1);
    expect(closes[0]!.id).toBe(syntheticCloseId(ADJUST_TX, POSITION_ID));
    expect(closes[0]!.equityDelta).toBe(-E18); // -equity, restored after the ADJUST reversal

    // pointer retained (P1 semantics)
    expect(await harness.context.db.find(activePosition, { id: pairKey(ACCOUNT, WETH, USDC) })).not.toBeNull();
  });
});

describe("equity reversal is exact when a step would floor equity at 0", () => {
  it("profit-extraction partial curated decrease → equity restored to the pre-tx base, not inflated", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" }); // equity E18, collateral 2E18, debt 4000 USDC

    // execute-driven withdraw of 1.5 WETH: equityDelta = −1.5E18 drives running equity below 0
    // (E18 − 1.5E18 → floored to 0). Position stays open (0.5 WETH, 4000 USDC remain).
    await harness.dispatch(morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: (3n * E18) / 2n, logIndex: 0 }));
    const synthesized = await positionRow();
    expect(synthesized!.equity).toBe(0n); // forward step floored
    expect((await adjustRow())!.equityBase).toBe(E18); // pre-tx base captured

    // curated partial PositionDecreased in the same tx supersedes the synthetic ADJUST
    await harness.dispatch({
      name: "MarginRouter:PositionDecreased",
      args: {
        account: ACCOUNT,
        collateral: WETH,
        debt: USDC,
        debtRepaid: 0n,
        collateralWithdrawn: (3n * E18) / 2n,
        collateralReturned: (3n * E18) / 2n,
        collateralTotal: E18 / 2n,
        debtTotal: 4000n * E6,
        currentLtv: 900000000000000000n,
        healthFactorWad: (11n * E18) / 10n,
      },
      txHash: ADJUST_TX,
      logIndex: 20,
      blockNumber: ADJUST_BLOCK,
      timestamp: ADJUST_BLOCK,
    });

    const row = await positionRow();
    expect(row!.status).toBe("OPEN");
    // exact reversal restores the pre-tx base E18 (the buggy linear reverse would yield 1.5E18)
    expect(row!.equity).toBe(E18);
    expect(await adjustRow()).toBeNull();
    expect(await actionsOfType("ADJUST")).toHaveLength(0);
    expect(await actionsOfType("DECREASE")).toHaveLength(1);
  });

  // The mark is stamped per action so a cost-basis fold can value each equity move at the price that
  // applied when it happened. Two sources must agree: the router event's own totals (free, exact —
  // interest cancels between numerator and denominator) and a block-pinned oracle read.
  it("stamps a mark on the open action, derived from the event's own totals", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    const [open] = await actionsOfType("OPEN");
    expect(open!.markX18).toBe(RAW_MARK_X18);
    expect(open!.collateralAfter).toBe(2n * E18);
    expect(open!.debtAfter).toBe(4000n * E6);
  });

  it("pins the mark and size at open on the position row", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    const row = await positionRow();
    expect(row!.entryMarkX18).toBe(RAW_MARK_X18);
    expect(row!.collateralAtOpen).toBe(2n * E18);
  });

  // A pure leverage retarget re-averages avgEntryPriceX18 over the new buy leg, so it drifts off the
  // price the owner's own margin went in at. entryMarkX18 is written once and must not move.
  it("leaves entryMarkX18 and collateralAtOpen untouched by a later adjust", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    const before = await positionRow();
    await harness.dispatch(morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18, logIndex: 0 }));
    const after = await positionRow();
    expect(after!.entryMarkX18).toBe(before!.entryMarkX18);
    expect(after!.collateralAtOpen).toBe(before!.collateralAtOpen);
  });

  // The synthetic ADJUST carries no router-reported LTV, so its mark comes from the oracle. The stub
  // is set to the same $4,000 the open fixture's LTV implies, so agreement here is the assertion.
  it("stamps an oracle-read mark on a synthetic adjust, agreeing with the derived one", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    await harness.dispatch(morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18, logIndex: 0 }));
    const [adjust] = await actionsOfType("ADJUST");
    expect(adjust!.markX18).toBe(RAW_MARK_X18);
    expect(adjust!.collateralAfter).toBe(3n * E18); // 2 at open + 1 supplied
  });

  // A liquidation books its own economics with equityDelta 0 — the seizure is a loss against a frozen
  // basis, not an owner-driven equity move. The Withdraw/Repay flows a liquidation could emit in the
  // same tx would otherwise synthesize an ADJUST on top and double-count it. Aave v3/v4 do not emit
  // those today (verified against the deployed LiquidationLogic), so this is the guard, not a repro.
  it("suppresses adjust synthesis in a tx that already booked a liquidation", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    const liq = liquidationEvent({
      venue: "MORPHO",
      repaidDebt: 1000n * E6,
      seizedCollateral: E18 / 4n,
    });
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 1n, 0n]);
    await harness.dispatch({
      ...liq,
      txHash: ADJUST_TX,
      logIndex: 0,
      blockNumber: ADJUST_BLOCK,
      timestamp: ADJUST_BLOCK,
    });
    // Same tx, a flow that would normally synthesize an ADJUST.
    await harness.dispatch(morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: E18 / 4n, logIndex: 1 }));

    expect(await actionsOfType("LIQUIDATION")).toHaveLength(1);
    expect(await actionsOfType("ADJUST")).toHaveLength(0);
  });

  it("pure-execute equity is step-order-independent even when a step would floor", async () => {
    const finalEquity = async (flows: HarnessEvent[]): Promise<bigint> => {
      await harness.reset();
      stubOracleMarks(harness); // reset clears stubs
      await openMarginPosition(harness, { venue: "MORPHO" });
      for (const flow of flows) await harness.dispatch(flow);
      return (await positionRow())!.equity as bigint;
    };

    // net equityDelta = clamp0(supplied 1) − clamp0(withdrawn 1.5) = −0.5E18; base E18 → 0.5E18
    const withdrawFirst = await finalEquity([
      morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: (3n * E18) / 2n, logIndex: 0 }), // floors to 0 mid-tx
      morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18, logIndex: 1 }),
    ]);
    const supplyFirst = await finalEquity([
      morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18, logIndex: 0 }),
      morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: (3n * E18) / 2n, logIndex: 1 }),
    ]);

    expect(withdrawFirst).toBe(E18 / 2n);
    expect(supplyFirst).toBe(E18 / 2n);
  });
});

describe("PositionUpdated live-epoch reconcile coexists with a same-tx synthetic ADJUST", () => {
  // The PositionUpdated live branch is state-only and does NOT call reverseAndSupersedeAdjust, unlike
  // the curated handlers. A flow-layer synthetic ADJUST is an execute plan's ONLY history row, so
  // superseding it here would erase it; the snapshot must reconcile LTV/health/lltv and the running
  // totals around it.
  it("keeps the ADJUST and its equity intact while reconciling the resulting-state snapshot", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" }); // equity E18, collateral 2E18, debt 4000 USDC

    // A Morpho supply flow synthesizes an ADJUST on the live epoch (mirrors adjust.test.ts).
    await harness.dispatch(morphoFlow({ kind: "SUPPLY_COLLATERAL", assets: E18, logIndex: 0 }));
    const adjustBefore = await harness.context.db.find(positionAction, { id: adjustId(ADJUST_TX, POSITION_ID) });
    expect(adjustBefore).not.toBeNull();
    expect(adjustBefore!.type).toBe("ADJUST");
    const equityAfterFlow = (await harness.context.db.find(position, { id: POSITION_ID }))!.equity;
    expect(equityAfterFlow).toBe(2n * E18); // base E18 + supplied E18

    // Same-tx PositionUpdated snapshot, with state distinct from the open fixture (0.5 / 2.0 / 0.86)
    // so the reconcile is observable.
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
