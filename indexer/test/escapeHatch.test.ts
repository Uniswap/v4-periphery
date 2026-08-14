/**
 * Router-less full-close detection: an `execute` plan or an owner escape-hatch
 * op unwinds a position through venue flows that never emit a router
 * PositionDecreased. When a flow zeroes both running amounts on an OPEN epoch,
 * the terminal transition is inferred here — confirmed against block-pinned
 * venue truth (zero on BOTH legs). There is no tx.to gate: execute plans run
 * with tx.to == MarginRouter, so a clone-only gate would leave them stuck OPEN.
 *
 * The synthetic CLOSE positionAction carries a deterministic id and the
 * activePosition pointer is left in place. findActivePosition ignores non-OPEN
 * pointers, so the next open starts a fresh epoch; a curated router close later
 * in the same tx supersedes the synthetic row (see the final describe block).
 */
import { activePosition, position, positionAction } from "ponder:schema";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { deployments } from "../addresses";
import { eventId, pairKey, positionId, syntheticCloseId } from "../src/helpers";
import { createHarness, type Harness, type HarnessEvent } from "./support/harness";
import {
  stubOracleMarks,
  AAVE_V3_POOL,
  AAVE_V4_SPOKE,
  ACCOUNT,
  E6,
  E18,
  LIQ_BLOCK,
  LIQ_TX,
  liquidationEvent,
  MORPHO_BLUE,
  MORPHO_MARKET_ID,
  openMarginPosition,
  OPEN_TX,
  RAW_MARK_X18,
  stageSwap,
  stubChainDebt,
  USDC,
  USDC_VARIABLE_DEBT_TOKEN,
  WETH,
} from "./support/scenario";

type Hex = `0x${string}`;

const MARGIN_ROUTER = deployments.mainnet.marginRouter;

// aToken address for the WETH reserve (v3); balanceOf on it is stubbed to 0.
const A_WETH: Hex = "0x00000000000000000000000000000000000000a1";

// router-less unwind flows land in their own blocks/txs, after any liquidation blocks.
const ESCAPE_BLOCK_1 = 25_600_050n;
const ESCAPE_BLOCK_2 = 25_600_051n;
const ESCAPE_REPAY_TX: Hex = "0x4444444444444444444444444444444444444444444444444444444444444444";
const ESCAPE_WITHDRAW_TX: Hex = "0x5555555555555555555555555555555555555555555555555555555555555555";
const CLOSE_POOL_ID: Hex = "0x00000000000000000000000000000000000000000000000000000000cafe0002";
const REOPEN_TX: Hex = "0x6666666666666666666666666666666666666666666666666666666666666666";

// curated full close: protocol flows + a same-tx router PositionDecreased.
const CLOSE_TX: Hex = "0x7777777777777777777777777777777777777777777777777777777777777777";
const CLOSE_BLOCK = 25_600_070n;

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

const PAIR_KEY = pairKey(ACCOUNT, WETH, USDC);
const POSITION_ID = positionId(ACCOUNT, WETH, USDC, OPEN_TX);
const positionRow = (openTxHash: Hex = OPEN_TX) =>
  harness.context.db.find(position, { id: positionId(ACCOUNT, WETH, USDC, openTxHash) });
const pointerRow = () => harness.context.db.find(activePosition, { id: PAIR_KEY });
const closeActions = async () =>
  (await harness.db.select().from(positionAction)).filter((a) => a.type === "CLOSE");

// --- venue flow-event builders (arg names mirror the handlers' destructuring) ---

function morphoFlow(args: {
  kind: "REPAY" | "WITHDRAW_COLLATERAL";
  assets: bigint;
  txHash: Hex;
  txTo: Hex;
  blockNumber: bigint;
  logIndex: number;
}): HarnessEvent {
  const { kind, assets, txHash, txTo, blockNumber, logIndex } = args;
  return {
    name: kind === "REPAY" ? "MorphoBlue:Repay" : "MorphoBlue:WithdrawCollateral",
    args: { id: MORPHO_MARKET_ID, caller: ACCOUNT, onBehalf: ACCOUNT, receiver: ACCOUNT, assets, shares: 0n },
    txHash,
    txTo,
    logIndex,
    blockNumber,
    timestamp: blockNumber,
    logAddress: MORPHO_BLUE,
  };
}

function aaveV3Flow(args: {
  kind: "REPAY" | "WITHDRAW_COLLATERAL";
  assets: bigint;
  txHash: Hex;
  txTo: Hex;
  blockNumber: bigint;
  logIndex: number;
}): HarnessEvent {
  const { kind, assets, txHash, txTo, blockNumber, logIndex } = args;
  return {
    name: kind === "REPAY" ? "AaveV3Pool:Repay" : "AaveV3Pool:Withdraw",
    args: { reserve: kind === "REPAY" ? USDC : WETH, user: ACCOUNT, amount: assets },
    txHash,
    txTo,
    logIndex,
    blockNumber,
    timestamp: blockNumber,
    logAddress: AAVE_V3_POOL,
  };
}

function aaveV4Flow(args: {
  kind: "REPAY" | "WITHDRAW_COLLATERAL";
  assets: bigint;
  txHash: Hex;
  txTo: Hex;
  blockNumber: bigint;
  logIndex: number;
}): HarnessEvent {
  const { kind, assets, txHash, txTo, blockNumber, logIndex } = args;
  return {
    name: kind === "REPAY" ? "AaveV4Spoke:Repay" : "AaveV4Spoke:Withdraw",
    args: { reserveId: kind === "REPAY" ? 7n : 0n, caller: ACCOUNT, onBehalfOf: ACCOUNT, amount: assets },
    txHash,
    txTo,
    logIndex,
    blockNumber,
    timestamp: blockNumber,
    logAddress: AAVE_V4_SPOKE,
  };
}

/** Repay(full) then Withdraw(full), in two blocks/txs. */
async function morphoFullUnwind({ txTo }: { txTo: Hex }): Promise<void> {
  await harness.dispatch(
    morphoFlow({ kind: "REPAY", assets: 4000n * E6, txHash: ESCAPE_REPAY_TX, txTo, blockNumber: ESCAPE_BLOCK_1, logIndex: 0 })
  );
  await harness.dispatch(
    morphoFlow({
      kind: "WITHDRAW_COLLATERAL",
      assets: 2n * E18,
      txHash: ESCAPE_WITHDRAW_TX,
      txTo,
      blockNumber: ESCAPE_BLOCK_2,
      logIndex: 0,
    })
  );
}

describe("router-less close detection", () => {
  it("1. Morpho escape-hatch unwind → CLOSED, economics null (repaid from outside the position)", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 0n, 0n]);

    await morphoFullUnwind({ txTo: ACCOUNT });

    const row = await positionRow();
    expect(row!.status).toBe("CLOSED");
    expect(row!.closeTxHash).toBe(ESCAPE_WITHDRAW_TX);
    expect(row!.closedAt).toBe(ESCAPE_BLOCK_2);
    expect(row!.collateralReturned).toBeNull();
    expect(row!.exitPriceX18).toBeNull();
    expect(row!.realizedPnl).toBeNull();

    // pointer left in place, still referencing the now-CLOSED epoch
    const pointer = await pointerRow();
    expect(pointer).not.toBeNull();
    expect(pointer!.positionId).toBe(POSITION_ID);

    const closes = await closeActions();
    expect(closes).toHaveLength(1);
    expect(closes[0]!.id).toBe(syntheticCloseId(ESCAPE_WITHDRAW_TX, POSITION_ID));
    expect(closes[0]!.equityDelta).toBe(-E18); // -equity
  });

  // A close that DOES sell collateral and retire the debt from the proceeds — the execute() shape — and
  // still gets null economics. Recorded deliberately, because the tempting derivation is unsound:
  //
  //   * a swap row carries no token identity, so "the input side of a router swap in this tx" cannot be
  //     told apart from "the position's collateral was sold". A close funded from OUTSIDE the position
  //     (pull an unrelated token, swap it to the debt token, repay, withdraw all collateral to the owner)
  //     satisfies every flow-sum test and would book a phantom profit of nearly the whole withdrawal.
  //   * exitPriceX18 means the REALIZED fill price everywhere else it is written (router.ts:
  //     debtRepaid·WAD / collateralSold). The oracle mark at that block is a different number — on this
  //     very fixture, 4.0e9 against a realized 2.67e9 — so the two would disagree on one row.
  //
  // Both are settled by the execute()-driven close, where the calldata is ours and ASSERT_FILL names the
  // swap's output currency and amount. Until then, null is the honest answer.
  it("1b. self-funded unwind → CLOSED, economics still null (unprovable from flow sums)", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 0n, 0n]);

    // Position is 2 WETH collateral / 4000 USDC debt / 1 WETH equity. Sell 1.5 WETH for the 4000 USDC
    // that retires the debt, withdraw all 2 WETH — so 0.5 WETH reaches the owner.
    stageSwap(harness, {
      txHash: ESCAPE_WITHDRAW_TX,
      poolId: CLOSE_POOL_ID,
      amount0: 4000n * E6,
      amount1: -((E18 * 3n) / 2n),
      logIndex: 1,
    });

    await harness.dispatch(
      morphoFlow({
        kind: "WITHDRAW_COLLATERAL",
        assets: 2n * E18,
        txHash: ESCAPE_WITHDRAW_TX,
        txTo: ACCOUNT,
        blockNumber: ESCAPE_BLOCK_2,
        logIndex: 0,
      }),
    );
    await harness.dispatch(
      morphoFlow({
        kind: "REPAY",
        assets: 4000n * E6,
        txHash: ESCAPE_WITHDRAW_TX,
        txTo: ACCOUNT,
        blockNumber: ESCAPE_BLOCK_2,
        logIndex: 2,
      }),
    );

    const row = await positionRow();
    expect(row!.status).toBe("CLOSED");
    expect(row!.collateralReturned).toBeNull();
    expect(row!.exitPriceX18).toBeNull();
    expect(row!.realizedPnl).toBeNull();
  });

  it("2. re-open of a closed pair starts a fresh epoch (stale pointer ignored)", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 0n, 0n]);
    await morphoFullUnwind({ txTo: ACCOUNT });
    // the stale pointer still references the CLOSED epoch
    expect((await pointerRow())!.positionId).toBe(POSITION_ID);

    // a re-opening supply flow must start a fresh epoch, not resurrect the ghost
    await harness.dispatch({
      name: "MorphoBlue:SupplyCollateral",
      args: { id: MORPHO_MARKET_ID, caller: ACCOUNT, onBehalf: ACCOUNT, assets: 3n * E18, shares: 0n },
      txHash: REOPEN_TX,
      txTo: ACCOUNT,
      logIndex: 0,
      blockNumber: ESCAPE_BLOCK_2 + 1n,
      timestamp: ESCAPE_BLOCK_2 + 1n,
      logAddress: MORPHO_BLUE,
    });

    const rows = await harness.db.select().from(position);
    expect(rows).toHaveLength(2);
    expect((await positionRow(REOPEN_TX))!.status).toBe("OPEN");
    expect((await positionRow(OPEN_TX))!.status).toBe("CLOSED");
    // pointer now tracks the fresh epoch
    expect((await pointerRow())!.positionId).toBe(positionId(ACCOUNT, WETH, USDC, REOPEN_TX));
  });

  it("3. residual venue debt vetoes the close (debt leg)", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    // arithmetic hits zero, but accrued interest leaves borrowShares behind
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 5n, 0n]);

    await morphoFullUnwind({ txTo: ACCOUNT });

    const row = await positionRow();
    expect(row!.status).toBe("OPEN");
    expect(await pointerRow()).not.toBeNull();
    expect(await closeActions()).toHaveLength(0);
    // the veto actually consulted chain truth at the terminal leg's block
    expect(harness.readCalls.some((c) => c.functionName === "position" && c.blockNumber === ESCAPE_BLOCK_2)).toBe(true);
  });

  it("4. gate dropped: execute-path unwind (tx.to = router, no router event) still closes", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 0n, 0n]);

    // execute() plans run with tx.to == MarginRouter and emit no Position* event
    await morphoFullUnwind({ txTo: MARGIN_ROUTER });

    const row = await positionRow();
    expect(row!.status).toBe("CLOSED");
    expect(await pointerRow()).not.toBeNull(); // pointer retained
    const closes = await closeActions();
    expect(closes).toHaveLength(1);
    expect(closes[0]!.id).toBe(syntheticCloseId(ESCAPE_WITHDRAW_TX, POSITION_ID));
    // the close was confirmed against block-pinned venue truth
    expect(harness.readCalls.some((c) => c.functionName === "position" && c.blockNumber === ESCAPE_BLOCK_2)).toBe(true);
  });

  it("5. partial unwind (half collateral) does not close (no venue read)", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 0n, 0n]);

    await harness.dispatch(
      morphoFlow({ kind: "REPAY", assets: 4000n * E6, txHash: ESCAPE_REPAY_TX, txTo: ACCOUNT, blockNumber: ESCAPE_BLOCK_1, logIndex: 0 })
    );
    await harness.dispatch(
      morphoFlow({
        kind: "WITHDRAW_COLLATERAL",
        assets: E18, // half of the 2 WETH collateral
        txHash: ESCAPE_WITHDRAW_TX,
        txTo: ACCOUNT,
        blockNumber: ESCAPE_BLOCK_2,
        logIndex: 0,
      })
    );

    const row = await positionRow();
    expect(row!.status).toBe("OPEN");
    expect(await pointerRow()).not.toBeNull();
    expect(harness.readCalls.some((c) => c.functionName === "position")).toBe(false);
  });

  it("6. Aave v3 full unwind → CLOSED, pointer retained", async () => {
    await openMarginPosition(harness, { venue: "AAVE_V3" });
    harness.onRead({ address: AAVE_V3_POOL, functionName: "getReserveAToken" }, A_WETH);
    harness.onRead({ address: AAVE_V3_POOL, functionName: "getReserveVariableDebtToken" }, USDC_VARIABLE_DEBT_TOKEN);
    harness.onRead({ functionName: "balanceOf" }, 0n); // aToken + debtToken both zero

    await harness.dispatch(
      aaveV3Flow({ kind: "REPAY", assets: 4000n * E6, txHash: ESCAPE_REPAY_TX, txTo: ACCOUNT, blockNumber: ESCAPE_BLOCK_1, logIndex: 0 })
    );
    await harness.dispatch(
      aaveV3Flow({
        kind: "WITHDRAW_COLLATERAL",
        assets: 2n * E18,
        txHash: ESCAPE_WITHDRAW_TX,
        txTo: ACCOUNT,
        blockNumber: ESCAPE_BLOCK_2,
        logIndex: 0,
      })
    );

    const row = await positionRow();
    expect(row!.status).toBe("CLOSED");
    expect(await pointerRow()).not.toBeNull();
  });

  it("7. Aave v4 full unwind → CLOSED, pointer retained, reads block-pinned", async () => {
    await openMarginPosition(harness, { venue: "AAVE_V4" });
    harness.onRead({ address: AAVE_V4_SPOKE, functionName: "getUserSuppliedAssets" }, 0n);
    harness.onRead({ address: AAVE_V4_SPOKE, functionName: "getUserTotalDebt" }, 0n);

    await harness.dispatch(
      aaveV4Flow({ kind: "REPAY", assets: 4000n * E6, txHash: ESCAPE_REPAY_TX, txTo: ACCOUNT, blockNumber: ESCAPE_BLOCK_1, logIndex: 0 })
    );
    await harness.dispatch(
      aaveV4Flow({
        kind: "WITHDRAW_COLLATERAL",
        assets: 2n * E18,
        txHash: ESCAPE_WITHDRAW_TX,
        txTo: ACCOUNT,
        blockNumber: ESCAPE_BLOCK_2,
        logIndex: 0,
      })
    );

    const row = await positionRow();
    expect(row!.status).toBe("CLOSED");
    expect(await pointerRow()).not.toBeNull();

    const venueReads = harness.readCalls.filter(
      (c) => c.functionName === "getUserSuppliedAssets" || c.functionName === "getUserTotalDebt"
    );
    expect(venueReads.length).toBeGreaterThan(0);
    for (const call of venueReads) expect(call.blockNumber).toBe(ESCAPE_BLOCK_2);
  });

  it("8. residual venue collateral vetoes the close (collateral leg)", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    // debt cleared, collateral dust remains (realistic v3-style residual)
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 0n, 7n]);

    await morphoFullUnwind({ txTo: ACCOUNT });

    const row = await positionRow();
    expect(row!.status).toBe("OPEN");
    expect(await pointerRow()).not.toBeNull();
    expect(harness.readCalls.some((c) => c.functionName === "position" && c.blockNumber === ESCAPE_BLOCK_2)).toBe(true);
  });

  it("9. close of a partially-liquidated epoch preserves liquidation state, pointer retained", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });

    // partial liquidation: chain debt remains → OPEN with liquidated=true
    stubChainDebt(harness, { venue: "MORPHO", remaining: 2000n * E6 });
    const liq = liquidationEvent({ venue: "MORPHO", repaidDebt: 2000n * E6, seizedCollateral: E18 });
    await harness.dispatch({ ...liq, txHash: LIQ_TX, logIndex: 3, blockNumber: LIQ_BLOCK, timestamp: LIQ_BLOCK });
    let row = await positionRow();
    expect(row!.status).toBe("OPEN");
    expect(row!.liquidated).toBe(true);

    // unwind of the remaining E18 collateral + 2000 USDC debt
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 0n, 0n]);
    await harness.dispatch(
      morphoFlow({ kind: "REPAY", assets: 2000n * E6, txHash: ESCAPE_REPAY_TX, txTo: ACCOUNT, blockNumber: ESCAPE_BLOCK_1, logIndex: 0 })
    );
    await harness.dispatch(
      morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: E18, txHash: ESCAPE_WITHDRAW_TX, txTo: ACCOUNT, blockNumber: ESCAPE_BLOCK_2, logIndex: 0 })
    );

    row = await positionRow();
    expect(row!.status).toBe("CLOSED");
    expect(row!.liquidated).toBe(true);
    expect(row!.liquidationTxHash).toBe(LIQ_TX);
    expect(await pointerRow()).not.toBeNull();
  });

  it("10. detector is flow-order independent: repay as terminal leg closes", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 0n, 0n]);

    // withdraw first (impossible on-chain with debt outstanding), repay last
    await harness.dispatch(
      morphoFlow({
        kind: "WITHDRAW_COLLATERAL",
        assets: 2n * E18,
        txHash: ESCAPE_WITHDRAW_TX,
        txTo: ACCOUNT,
        blockNumber: ESCAPE_BLOCK_1,
        logIndex: 0,
      })
    );
    await harness.dispatch(
      morphoFlow({ kind: "REPAY", assets: 4000n * E6, txHash: ESCAPE_REPAY_TX, txTo: ACCOUNT, blockNumber: ESCAPE_BLOCK_2, logIndex: 0 })
    );

    const row = await positionRow();
    expect(row!.status).toBe("CLOSED");
    expect(row!.closeTxHash).toBe(ESCAPE_REPAY_TX);
    expect(await pointerRow()).not.toBeNull();
  });
});

describe("curated full close supersedes the synthetic router-less close", () => {
  it("router PositionDecreased in the same tx → one rich CLOSE, synthetic superseded, pointer deleted", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    // venue reports empty at close, so the flow layer writes a synthetic CLOSE first
    harness.onRead({ address: MORPHO_BLUE, functionName: "position" }, [0n, 0n, 0n]);

    // same-tx protocol flows zero both legs
    await harness.dispatch(
      morphoFlow({ kind: "REPAY", assets: 4000n * E6, txHash: CLOSE_TX, txTo: MARGIN_ROUTER, blockNumber: CLOSE_BLOCK, logIndex: 0 })
    );
    await harness.dispatch(
      morphoFlow({ kind: "WITHDRAW_COLLATERAL", assets: 2n * E18, txHash: CLOSE_TX, txTo: MARGIN_ROUTER, blockNumber: CLOSE_BLOCK, logIndex: 1 })
    );

    // synthetic close exists before the router event
    expect(await harness.context.db.find(positionAction, { id: syntheticCloseId(CLOSE_TX, POSITION_ID) })).not.toBeNull();

    // curated router close, same tx, authoritative economics (1.5 WETH returned)
    await harness.dispatch({
      name: "MarginRouter:PositionDecreased",
      args: {
        account: ACCOUNT,
        collateral: WETH,
        debt: USDC,
        debtRepaid: 4000n * E6,
        collateralWithdrawn: 2n * E18,
        collateralReturned: (3n * E18) / 2n,
        collateralTotal: 0n,
        debtTotal: 0n,
        currentLtv: 0n,
        healthFactorWad: 0n,
      },
      txHash: CLOSE_TX,
      logIndex: 5,
      blockNumber: CLOSE_BLOCK,
      timestamp: CLOSE_BLOCK,
    });

    const row = await positionRow();
    expect(row!.status).toBe("CLOSED");
    expect(row!.collateralReturned).toBe((3n * E18) / 2n);
    expect(row!.realizedPnl).toBe(E18 / 2n); // collateralReturned - equity = 1.5 - 1.0
    expect(row!.exitPriceX18).toBe(8000n * E6); // debtRepaid / collateralSold (0.5 WETH)

    // the router close deletes the pointer
    expect(await pointerRow()).toBeNull();
    // the synthetic row is superseded → gone; exactly one CLOSE row (the router's)
    expect(await harness.context.db.find(positionAction, { id: syntheticCloseId(CLOSE_TX, POSITION_ID) })).toBeNull();
    const closes = await closeActions();
    expect(closes).toHaveLength(1);
    expect(closes[0]!.id).toBe(eventId(CLOSE_TX, 5));
  });
});
