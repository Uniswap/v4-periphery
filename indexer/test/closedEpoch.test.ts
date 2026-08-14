/**
 * IDX-4: don't fold a curated open into a snapshot-terminated epoch.
 *  - PositionIncreased / CollateralAdded status-filter the pointer (findActivePosition), so a curated
 *    open on a pair whose pointed epoch is non-OPEN starts a NEW epoch and overwrites the pointer;
 *  - a terminal PositionUpdated snapshot marks status/closedAt/closeTxHash but leaves the pointer and
 *    the economics untouched.
 */
import { activePosition, position, positionAction } from "ponder:schema";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { pairKey, positionId } from "../src/helpers";
import { createHarness, type Harness } from "./support/harness";
import { ACCOUNT, E6, E18, OPEN_BLOCK, OPEN_TX, OWNER, stubOracleMarks, USDC, WETH } from "./support/scenario";
import { openMarginPosition } from "./support/scenario";

type Hex = `0x${string}`;

const TERM_TX = ("0x" + "e1".repeat(32)) as Hex;
const TERM_BLOCK = OPEN_BLOCK + 50n;
const REOPEN_TX = ("0x" + "e2".repeat(32)) as Hex;
const REOPEN_BLOCK = OPEN_BLOCK + 100n;

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

/** A terminal (zero/zero) PositionUpdated snapshot: an execute-composed full close. */
function terminalSnapshot(txHash: Hex, blockNumber: bigint) {
  return harness.dispatch({
    name: "MarginRouter:PositionUpdated",
    args: {
      owner: OWNER,
      account: ACCOUNT,
      collateral: WETH,
      debt: USDC,
      collateralTotal: 0n,
      debtTotal: 0n,
      currentLtv: 0n,
      maxLtv: 860000000000000000n,
      healthFactorWad: 0n,
    },
    txHash,
    logIndex: 5,
    blockNumber,
    timestamp: blockNumber,
  });
}

describe("a terminal PositionUpdated snapshot closes the epoch but leaves the pointer", () => {
  it("sets status/closedAt/closeTxHash, keeps economics and the activePosition pointer", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" });
    const id = positionId(ACCOUNT, WETH, USDC, OPEN_TX);
    const opened = await harness.context.db.find(position, { id });
    expect(opened!.status).toBe("OPEN");
    expect(opened!.equity).toBe(E18);

    await terminalSnapshot(TERM_TX, TERM_BLOCK);

    const closed = await harness.context.db.find(position, { id });
    expect(closed!.status).toBe("CLOSED");
    expect(closed!.closedAt).toBe(TERM_BLOCK);
    expect(closed!.closeTxHash).toBe(TERM_TX);
    // Economics untouched: the snapshot never rewrites equity / entry price / liquidation figures.
    expect(closed!.equity).toBe(E18);
    expect(closed!.liquidated).toBe(false);

    // The pointer is deliberately left in place (findActivePosition ignores non-OPEN pointers).
    const pointer = await harness.context.db.find(activePosition, { id: pairKey(ACCOUNT, WETH, USDC) });
    expect(pointer).not.toBeNull();
    expect(pointer!.positionId).toBe(id);
  });
});

describe("a curated open after a snapshot-terminated epoch starts a NEW epoch", () => {
  it("does not resurrect the closed epoch; creates a fresh row + OPEN action and overwrites the pointer", async () => {
    await openMarginPosition(harness, { venue: "MORPHO" }); // epoch #1 at OPEN_TX
    const firstId = positionId(ACCOUNT, WETH, USDC, OPEN_TX);

    // Execute-composed full close leaves epoch #1 CLOSED with the pointer still pointing at it.
    await terminalSnapshot(TERM_TX, TERM_BLOCK);
    expect((await harness.context.db.find(position, { id: firstId }))!.status).toBe("CLOSED");

    // A later curated open on the SAME pair. findActivePosition sees the pointer's non-OPEN epoch as
    // absent, so this must open a brand-new epoch rather than fold into the dead one.
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
      txHash: REOPEN_TX,
      logIndex: 10,
      blockNumber: REOPEN_BLOCK,
      timestamp: REOPEN_BLOCK,
    });

    const secondId = positionId(ACCOUNT, WETH, USDC, REOPEN_TX);
    expect(secondId).not.toBe(firstId);

    // Epoch #1 stays CLOSED; epoch #2 is a distinct OPEN row with its own OPEN action.
    expect((await harness.context.db.find(position, { id: firstId }))!.status).toBe("CLOSED");
    const second = await harness.context.db.find(position, { id: secondId });
    expect(second!.status).toBe("OPEN");
    expect(second!.openTxHash).toBe(REOPEN_TX);

    const openActions = (await harness.db.select().from(positionAction)).filter(
      (a) => a.type === "OPEN" && a.positionId === secondId
    );
    expect(openActions).toHaveLength(1);

    // The pointer now tracks the fresh epoch.
    const pointer = await harness.context.db.find(activePosition, { id: pairKey(ACCOUNT, WETH, USDC) });
    expect(pointer!.positionId).toBe(secondId);
  });
});
