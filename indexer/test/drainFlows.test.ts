/**
 * IDX-3 validation: the drainFlows twin of the flow-attribution hardening.
 *  - a staged (null-pair) lendingEvent is claimed only when its named reserve belongs to the pair
 *    (same predicate applyStagedFlows uses); a reserve-less staged row is refused (fail-closed);
 *  - consumeSwaps + txLendingEvents replay in NUMERIC log-index order (ids are `${txHash}-${logIndex}`
 *    strings, so a lexical sort puts logIndex 12 before 8);
 *  - the 62a514f-shaped same-block ambiguous collateral add does not cross-claim.
 */
import { lendingEvent, position, positionAction, swapEvent } from "ponder:schema";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { eventId, pairKey, positionId } from "../src/helpers";
import { createHarness, type Harness } from "./support/harness";
import { ACCOUNT, E6, E18, OPEN_BLOCK, OWNER, stubOracleMarks, USDC, WETH } from "./support/scenario";

type Hex = `0x${string}`;

const DAI: Hex = "0x6b175474e89094c44da98b954eedeac495271d0f";
const POOL_8: Hex = "0x0000000000000000000000000000000000000000000000000000000000000008";
const POOL_12: Hex = "0x0000000000000000000000000000000000000000000000000000000000000012";

const TX_A = ("0x" + "a1".repeat(32)) as Hex;
const TX_SWAP = ("0x" + "5a".repeat(32)) as Hex;
const TX_USDC = ("0x" + "d1".repeat(32)) as Hex; // WETH/USDC open
const TX_DAI = ("0x" + "d2".repeat(32)) as Hex; // WETH/DAI open
const ADD_TX = ("0x" + "add".padEnd(64, "0")) as Hex;
const ADD_BLOCK = OPEN_BLOCK + 100n;

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

/** A curated open for (WETH, debt), event totals authoritative. */
function positionIncreased(args: { debt: Hex; txHash: Hex; logIndex?: number; blockNumber?: bigint }) {
  const { debt, txHash, logIndex = 10, blockNumber = OPEN_BLOCK } = args;
  return harness.dispatch({
    name: "MarginRouter:PositionIncreased",
    args: {
      owner: OWNER,
      account: ACCOUNT,
      collateral: WETH,
      debt,
      equity: E18,
      collateralBought: E18,
      debtDrawn: 4000n * E6,
      collateralTotal: 2n * E18,
      debtTotal: 4000n * E6,
      currentLtv: 500000000000000000n,
      maxLtv: 860000000000000000n,
      healthFactorWad: 2n * E18,
    },
    txHash,
    logIndex,
    blockNumber,
    timestamp: blockNumber,
  });
}

/** Stage a null-pair (collateral=debt=null) lending flow, as the venue handlers do for Aave. */
function stageFlow(args: {
  id: string;
  txHash: Hex;
  kind: "SUPPLY_COLLATERAL" | "WITHDRAW_COLLATERAL" | "BORROW" | "REPAY";
  reserve: Hex | null;
  blockNumber?: bigint;
}) {
  const { id, txHash, kind, reserve, blockNumber = OPEN_BLOCK } = args;
  return harness.context.db.insert(lendingEvent).values({
    id,
    txHash,
    venue: "AAVE_V3",
    kind,
    account: ACCOUNT,
    collateral: null,
    debt: null,
    reserve,
    assets: E18,
    blockNumber,
    timestamp: blockNumber,
    applied: false,
  });
}

describe("drainFlows claims a null-pair row only when its reserve belongs to the pair", () => {
  it("applies the WETH-supply and USDC-borrow rows, refuses a sibling DAI-borrow and a reserve-less row", async () => {
    // Four null-pair rows staged in one tx for the account, before the curated WETH/USDC open.
    await stageFlow({ id: eventId(TX_A, 0), txHash: TX_A, kind: "SUPPLY_COLLATERAL", reserve: WETH }); // belongs (coll)
    await stageFlow({ id: eventId(TX_A, 1), txHash: TX_A, kind: "BORROW", reserve: USDC }); // belongs (debt)
    await stageFlow({ id: eventId(TX_A, 2), txHash: TX_A, kind: "BORROW", reserve: DAI }); // sibling market's debt
    await stageFlow({ id: eventId(TX_A, 3), txHash: TX_A, kind: "BORROW", reserve: null }); // reserve-less

    await positionIncreased({ debt: USDC, txHash: TX_A });

    const r0 = await harness.context.db.find(lendingEvent, { id: eventId(TX_A, 0) });
    const r1 = await harness.context.db.find(lendingEvent, { id: eventId(TX_A, 1) });
    const r2 = await harness.context.db.find(lendingEvent, { id: eventId(TX_A, 2) });
    const r3 = await harness.context.db.find(lendingEvent, { id: eventId(TX_A, 3) });

    // Claimed: reserve matches the pair's collateral / debt role. drainFlows set (collateral, debt, applied).
    expect(r0!.applied).toBe(true);
    expect(r0!.collateral).toBe(WETH);
    expect(r0!.debt).toBe(USDC);
    expect(r1!.applied).toBe(true);
    expect(r1!.debt).toBe(USDC);

    // Refused: the DAI-borrow reserve belongs to no role of WETH/USDC; the reserve-less row is fail-closed.
    // Without the belongs guard both would be claimed unconditionally (the old null-pair branch).
    expect(r2!.applied).toBe(false);
    expect(r2!.collateral).toBeNull();
    expect(r3!.applied).toBe(false);
    expect(r3!.collateral).toBeNull();
  });
});

describe("consumeSwaps replays in numeric log-index order", () => {
  it("attributes the earliest-logIndex swap's pool, not the lexically-first one", async () => {
    // Two unconsumed swaps in one tx: logIndex 8 and 12. A lexical id sort ("...-12" < "...-8") would pick 12.
    await harness.context.db.insert(swapEvent).values({
      id: eventId(TX_SWAP, 12),
      txHash: TX_SWAP,
      poolId: POOL_12,
      amount0: 0n,
      amount1: 0n,
      sqrtPriceX96: 0n,
      fee: 500,
      blockNumber: OPEN_BLOCK,
      consumed: false,
    });
    await harness.context.db.insert(swapEvent).values({
      id: eventId(TX_SWAP, 8),
      txHash: TX_SWAP,
      poolId: POOL_8,
      amount0: 0n,
      amount1: 0n,
      sqrtPriceX96: 0n,
      fee: 500,
      blockNumber: OPEN_BLOCK,
      consumed: false,
    });

    await positionIncreased({ debt: USDC, txHash: TX_SWAP });

    // openPoolId = consumeSwaps()'s first swap = the logIndex-8 pool (numeric order), not POOL_12.
    const row = await harness.context.db.find(position, { id: positionId(ACCOUNT, WETH, USDC, TX_SWAP) });
    expect(row!.openPoolId).toBe(POOL_8);
    // both swaps drained.
    expect((await harness.context.db.find(swapEvent, { id: eventId(TX_SWAP, 8) }))!.consumed).toBe(true);
    expect((await harness.context.db.find(swapEvent, { id: eventId(TX_SWAP, 12) }))!.consumed).toBe(true);
  });
});

describe("a 62a514f-shaped same-block ambiguous collateral add does not cross-claim", () => {
  it("leaves both WETH-collateral positions untouched when the add cannot be disambiguated", async () => {
    // Two OPEN positions on the same account share WETH collateral (WETH/USDC and WETH/DAI).
    await harness.dispatch({
      name: "MarginRouter:AccountCreated",
      args: { owner: OWNER, account: ACCOUNT, subId: 0n },
      txHash: TX_USDC,
      logIndex: 0,
      blockNumber: OPEN_BLOCK,
      timestamp: OPEN_BLOCK,
    });
    await positionIncreased({ debt: USDC, txHash: TX_USDC, logIndex: 1, blockNumber: OPEN_BLOCK });
    await positionIncreased({ debt: DAI, txHash: TX_DAI, logIndex: 1, blockNumber: OPEN_BLOCK });

    const usdcId = positionId(ACCOUNT, WETH, USDC, TX_USDC);
    const daiId = positionId(ACCOUNT, WETH, DAI, TX_DAI);
    const usdcBefore = await harness.context.db.find(position, { id: usdcId });
    const daiBefore = await harness.context.db.find(position, { id: daiId });
    expect(usdcBefore!.status).toBe("OPEN");
    expect(daiBefore!.status).toBe("OPEN");

    // A CollateralAdded(WETH) in a later block with no staged supply flow: both positions are candidates
    // (OPEN, collateral WETH), neither was updated in ADD_BLOCK, so resolution is ambiguous and the
    // handler returns without attributing the add to either.
    await harness.dispatch({
      name: "MarginRouter:CollateralAdded",
      args: {
        account: ACCOUNT,
        collateral: WETH,
        amount: E18,
        collateralTotal: 3n * E18,
        debtTotal: 4000n * E6,
        currentLtv: 400000000000000000n,
        healthFactorWad: 3n * E18,
      },
      txHash: ADD_TX,
      logIndex: 0,
      blockNumber: ADD_BLOCK,
      timestamp: ADD_BLOCK,
    });

    // Neither position absorbed the add: collateral/equity unchanged, no ADD_COLLATERAL action written.
    const usdcAfter = await harness.context.db.find(position, { id: usdcId });
    const daiAfter = await harness.context.db.find(position, { id: daiId });
    expect(usdcAfter!.collateralAmount).toBe(usdcBefore!.collateralAmount);
    expect(usdcAfter!.equity).toBe(usdcBefore!.equity);
    expect(daiAfter!.collateralAmount).toBe(daiBefore!.collateralAmount);
    expect(daiAfter!.equity).toBe(daiBefore!.equity);
    const adds = (await harness.db.select().from(positionAction)).filter((a) => a.type === "ADD_COLLATERAL");
    expect(adds).toHaveLength(0);
  });
});
