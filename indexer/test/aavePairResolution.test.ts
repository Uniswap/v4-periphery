/**
 * Aave pair resolution for a FIRST-EVER open.
 *
 * An Aave flow event names one reserve, not a pair, so `resolvePair` recovers the (collateral, debt)
 * pair from the market registry — and falls back to "which pair does this account already hold?" when
 * several registered markets share that reserve in the same role. A first-ever open has no live
 * position, so that fallback finds nothing and the flow is STAGED with a null pair.
 *
 * A staged flow used to be completed by the curated router event later in the same transaction. An
 * `execute()`-driven open emits no router event, so nothing drains it: the position gets no row at all
 * — not wrong numbers, NO ROW, so it is invisible to the API and cannot be closed.
 *
 * Not reachable with today's registry (WETH/USDC in both directions gives exactly one candidate per
 * reserve+role), which is why it has gone unnoticed. It opens the moment a second Aave market shares a
 * reserve in the same role — a WETH/USDT market alongside WETH/USDC.
 */
import { activePosition, lendingEvent, position } from "ponder:schema";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { deployments } from "../addresses";
import { createHarness, type Harness, type HarnessEvent } from "./support/harness";
import { ACCOUNT, AAVE_V3_POOL, E18, E6, OWNER, stubOracleMarks, USDC, WETH } from "./support/scenario";

type Hex = `0x${string}`;

const MARGIN_ROUTER = deployments.mainnet.marginRouter;
// A second debt asset sharing WETH as its collateral reserve — the ambiguity trigger.
const USDT: Hex = "0xdAC17F958D2ee523a2206206994597C13D831ec7";

const OPEN_TX: Hex = "0x1111111111111111111111111111111111111111111111111111111111111111";
const BLOCK = 25_600_200n;

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
  // The account must be known, or every flow handler short-circuits on isMarginAccount.
  await harness.dispatch({
    name: "MarginRouter:AccountCreated",
    args: { owner: OWNER, account: ACCOUNT, subId: 0n },
    txHash: OPEN_TX,
    logIndex: 0,
    blockNumber: BLOCK,
    timestamp: BLOCK,
  });
  // Two registered Aave markets share WETH as the collateral reserve.
  for (const debt of [USDC, USDT]) {
    await harness.dispatch({
      name: "AaveAdapter:MarketSet",
      args: { collateral: WETH, debt, allowed: true },
      txHash: OPEN_TX,
      logIndex: 0,
      blockNumber: BLOCK,
      timestamp: BLOCK,
    });
  }
});

function aaveFlow(args: { name: string; extra: Record<string, unknown>; logIndex: number }): HarnessEvent {
  return {
    name: args.name,
    args: args.extra,
    txHash: OPEN_TX,
    txTo: MARGIN_ROUTER,
    logIndex: args.logIndex,
    blockNumber: BLOCK,
    timestamp: BLOCK,
    logAddress: AAVE_V3_POOL,
  };
}

// The clone's own events, which name BOTH currencies explicitly — the only source that can complete an
// ambiguous first-ever open with no router event and no prior position.
function cloneEvent(args: { name: string; extra: Record<string, unknown>; logIndex: number }): HarnessEvent {
  return {
    name: args.name,
    args: args.extra,
    txHash: OPEN_TX,
    txTo: MARGIN_ROUTER,
    logIndex: args.logIndex,
    blockNumber: BLOCK,
    timestamp: BLOCK,
    logAddress: ACCOUNT,
  };
}

describe("Aave first-ever open on a shared reserve", () => {
  it("leaves the collateral staged and the position reading as INFINITE leverage", async () => {
    await harness.dispatch(
      aaveFlow({ name: "AaveV3Pool:Supply", extra: { reserve: WETH, onBehalfOf: ACCOUNT, amount: E18 }, logIndex: 1 }),
    );
    await harness.dispatch(
      aaveFlow({ name: "AaveV3Pool:Borrow", extra: { reserve: USDC, onBehalfOf: ACCOUNT, amount: 2000n * E6 }, logIndex: 2 }),
    );

    // Only the SUPPLY is ambiguous — two registered markets share WETH as collateral. The BORROW names
    // USDC as debt, which only one market does, so it resolves and OPENS the epoch on its own.
    const staged = (await harness.db.select().from(lendingEvent)).filter((row) => row.collateral === null);
    expect(staged).toHaveLength(1);
    expect(staged[0]!.kind).toBe("SUPPLY_COLLATERAL");
    expect(staged[0]!.applied).toBe(false);

    // The damage, before the clone events arrive: debt applied, collateral not. Not a missing row — a
    // position carrying debt against ZERO collateral, which reads as infinite leverage and instant
    // liquidation everywhere downstream. The next test completes it.
    const positions = await harness.db.select().from(position);
    expect(positions).toHaveLength(1);
    expect(positions[0]!.debtPrincipal).toBe(2000n * E6);
    expect(positions[0]!.collateralAmount).toBe(0n);
  });

  it("completes the position once the clone's own events name both currencies", async () => {
    await harness.dispatch(
      aaveFlow({ name: "AaveV3Pool:Supply", extra: { reserve: WETH, onBehalfOf: ACCOUNT, amount: E18 }, logIndex: 1 }),
    );
    await harness.dispatch(
      aaveFlow({ name: "AaveV3Pool:Borrow", extra: { reserve: USDC, onBehalfOf: ACCOUNT, amount: 2000n * E6 }, logIndex: 2 }),
    );

    // CollateralSupplied gives the collateral, Borrowed the debt — together, the pair.
    await harness.dispatch(
      cloneEvent({
        name: "MarginAccounts:CollateralSupplied",
        extra: { caller: MARGIN_ROUTER, adapter: MARGIN_ROUTER, collateral: WETH, amount: E18 },
        logIndex: 3,
      }),
    );
    await harness.dispatch(
      cloneEvent({
        name: "MarginAccounts:Borrowed",
        extra: { caller: MARGIN_ROUTER, adapter: MARGIN_ROUTER, debt: USDC, amount: 2000n * E6, to: MARGIN_ROUTER },
        logIndex: 4,
      }),
    );

    const positions = await harness.db.select().from(position);
    expect(positions).toHaveLength(1);
    expect(positions[0]!.collateral.toLowerCase()).toBe(WETH.toLowerCase());
    expect(positions[0]!.debt.toLowerCase()).toBe(USDC.toLowerCase());
    // Amounts come from the venue flows, which are the source of truth — the clone events only resolve
    // the pair, so a double-count here would mean two writers.
    expect(positions[0]!.collateralAmount).toBe(E18);
    expect(positions[0]!.debtPrincipal).toBe(2000n * E6);

    const active = await harness.db.select().from(activePosition);
    expect(active).toHaveLength(1);

    const drained = await harness.db.select().from(lendingEvent);
    expect(drained.every((row) => row.applied === true)).toBe(true);
    expect(drained.every((row) => row.collateral !== null && row.debt !== null)).toBe(true);
  });

  // Found by an adversarial review: a replay filtered only by (tx, account) lets the FIRST pair to
  // resolve claim every staged flow in the transaction. With two markets sharing WETH as collateral and
  // one tx touching both, that doubles one position's collateral and leaves the other carrying debt
  // against zero — reintroducing the exact state this whole path exists to prevent. Each staged row
  // records the reserve it named, so a replay can only claim rows belonging to its own pair.
  it("claims only the staged flows belonging to the resolved pair", async () => {
    // Two supplies on the shared WETH reserve — one per market — plus each market's own borrow.
    await harness.dispatch(
      aaveFlow({ name: "AaveV3Pool:Supply", extra: { reserve: WETH, onBehalfOf: ACCOUNT, amount: E18 }, logIndex: 1 }),
    );
    await harness.dispatch(
      aaveFlow({ name: "AaveV3Pool:Supply", extra: { reserve: WETH, onBehalfOf: ACCOUNT, amount: 2n * E18 }, logIndex: 2 }),
    );

    await harness.dispatch(
      cloneEvent({
        name: "MarginAccounts:CollateralSupplied",
        extra: { caller: MARGIN_ROUTER, adapter: MARGIN_ROUTER, collateral: WETH, amount: E18 },
        logIndex: 3,
      }),
    );
    await harness.dispatch(
      cloneEvent({
        name: "MarginAccounts:Borrowed",
        extra: { caller: MARGIN_ROUTER, adapter: MARGIN_ROUTER, debt: USDC, amount: 2000n * E6, to: MARGIN_ROUTER },
        logIndex: 4,
      }),
    );

    // Both WETH supplies name the pair's collateral reserve, so both legitimately belong to it — the
    // point is that the USDT market's DEBT flow is not swept in by the same resolution.
    const usdtRows = (await harness.db.select().from(lendingEvent)).filter(
      (row) => row.debt !== null && row.debt.toLowerCase() === USDT.toLowerCase(),
    );
    expect(usdtRows).toHaveLength(0);

    const positions = await harness.db.select().from(position);
    expect(positions).toHaveLength(1);
    expect(positions[0]!.debt.toLowerCase()).toBe(USDC.toLowerCase());
  });

  // Ids are `${txHash}-${logIndex}`, so a string sort puts 12 before 8. Replaying out of emission order
  // changes where clamp0 bites and can miss a cross-through-zero that should have closed the epoch.
  it("replays staged flows in numeric log-index order, not lexicographic id order", async () => {
    await harness.dispatch(
      aaveFlow({ name: "AaveV3Pool:Supply", extra: { reserve: WETH, onBehalfOf: ACCOUNT, amount: E18 }, logIndex: 12 }),
    );
    await harness.dispatch(
      aaveFlow({
        name: "AaveV3Pool:Withdraw",
        extra: { reserve: WETH, user: ACCOUNT, to: ACCOUNT, amount: (E18 * 3n) / 4n },
        logIndex: 8,
      }),
    );
    await harness.dispatch(
      cloneEvent({
        name: "MarginAccounts:CollateralSupplied",
        extra: { caller: MARGIN_ROUTER, adapter: MARGIN_ROUTER, collateral: WETH, amount: E18 },
        logIndex: 20,
      }),
    );
    await harness.dispatch(
      cloneEvent({
        name: "MarginAccounts:Borrowed",
        extra: { caller: MARGIN_ROUTER, adapter: MARGIN_ROUTER, debt: USDC, amount: 1n, to: MARGIN_ROUTER },
        logIndex: 21,
      }),
    );

    // Emission order is withdraw(8) then supply(12): clamp0(0 − 0.75) = 0, then +1.0 → 1.0.
    // Lexicographic order would be supply(12) then withdraw(8): 1.0 then −0.75 → 0.25.
    const positions = await harness.db.select().from(position);
    expect(positions).toHaveLength(1);
    expect(positions[0]!.collateralAmount).toBe(E18);
  });

  it("does not resolve a pair the registry never registered", async () => {
    await harness.dispatch(
      aaveFlow({ name: "AaveV3Pool:Supply", extra: { reserve: WETH, onBehalfOf: ACCOUNT, amount: E18 }, logIndex: 1 }),
    );
    // WETH/DAI is not a registered market, so this pair must be refused rather than invented.
    const DAI: Hex = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
    await harness.dispatch(
      cloneEvent({
        name: "MarginAccounts:CollateralSupplied",
        extra: { caller: MARGIN_ROUTER, adapter: MARGIN_ROUTER, collateral: WETH, amount: E18 },
        logIndex: 3,
      }),
    );
    await harness.dispatch(
      cloneEvent({
        name: "MarginAccounts:Borrowed",
        extra: { caller: MARGIN_ROUTER, adapter: MARGIN_ROUTER, debt: DAI, amount: 1n, to: MARGIN_ROUTER },
        logIndex: 4,
      }),
    );

    expect(await harness.db.select().from(position)).toHaveLength(0);
  });
});
