/**
 * Venue attribution for positions the flow layer cannot see.
 *
 * A venue with no flow-truth layer stages no lendingEvent rows, so `drainFlows` returns UNKNOWN and
 * the epoch used to open that way permanently. The MarginAccount clone names the adapter of every
 * action it performs, which identifies the venue; these cases pin how far that evidence is trusted.
 */
import { position } from "ponder:schema";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { deployments } from "../addresses";
import { positionId } from "../src/helpers";
import { createHarness, type Harness, type HarnessEvent } from "./support/harness";
import { ACCOUNT, E6, E18, OPEN_BLOCK, OWNER, stubOracleMarks, USDC, WETH } from "./support/scenario";

type Hex = `0x${string}`;

const COMPOUND_ADAPTER = deployments.mainnet.compoundAdapter as Hex;
const AAVE_ADAPTER = deployments.mainnet.aaveAdapter as Hex;
// Allowlisted by governance but absent from the indexer's adapter→venue map.
const UNMAPPED_ADAPTER = "0x00000000000000000000000000000000000000ee" as Hex;

const UNI: Hex = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984";
// The same token, checksummed as viem decodes it — the sighting key must not care.
const UNI_CHECKSUMMED: Hex = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984";

const TX: Hex = ("0x" + "c1".repeat(32)) as Hex;
const TX_2: Hex = ("0x" + "c2".repeat(32)) as Hex;

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

const at = (txHash: Hex, logIndex: number): Pick<HarnessEvent, "txHash" | "logIndex" | "blockNumber" | "timestamp"> => ({
  txHash,
  logIndex,
  blockNumber: OPEN_BLOCK,
  timestamp: OPEN_BLOCK,
});

/** A clone supply, naming the adapter it ran through. */
const supplied = (args: { adapter: Hex; collateral: Hex; txHash: Hex; logIndex: number }): HarnessEvent => ({
  name: "MarginAccounts:CollateralSupplied",
  args: { caller: OWNER, adapter: args.adapter, collateral: args.collateral, amount: E18 },
  logAddress: ACCOUNT,
  ...at(args.txHash, args.logIndex),
});

const borrowed = (args: { adapter: Hex; debt: Hex; txHash: Hex; logIndex: number }): HarnessEvent => ({
  name: "MarginAccounts:Borrowed",
  args: { caller: OWNER, adapter: args.adapter, debt: args.debt, amount: 1000n * E6, to: ACCOUNT },
  logAddress: ACCOUNT,
  ...at(args.txHash, args.logIndex),
});

/** The resulting-state snapshot the router emits after each account call. */
const snapshot = (args: {
  collateral: Hex;
  debt: Hex;
  txHash: Hex;
  logIndex: number;
  collateralTotal?: bigint;
  debtTotal?: bigint;
}): HarnessEvent => ({
  name: "MarginRouter:PositionUpdated",
  args: {
    owner: OWNER,
    account: ACCOUNT,
    collateral: args.collateral,
    debt: args.debt,
    collateralTotal: args.collateralTotal ?? 2n * E18,
    debtTotal: args.debtTotal ?? 1000n * E6,
    currentLtv: 500000000000000000n,
    maxLtv: 860000000000000000n,
    healthFactorWad: 2n * E18,
  },
  ...at(args.txHash, args.logIndex),
});

const venueOf = async (collateral: Hex, debt: Hex, txHash: Hex): Promise<string | undefined> => {
  const row = await harness.context.db.find(position, { id: positionId(ACCOUNT, collateral, debt, txHash) });
  return row?.venue as string | undefined;
};

async function registerAccount(): Promise<void> {
  await harness.dispatch({
    name: "MarginRouter:AccountCreated",
    args: { owner: OWNER, account: ACCOUNT, subId: 0n },
    ...at(("0x" + "99".repeat(32)) as Hex, 0),
  });
}

describe("a venue with no flow layer is attributed from the clone's adapter", () => {
  it("opens COMPOUND_V3 from the snapshot, where drainFlows can only say UNKNOWN", async () => {
    await registerAccount();
    await harness.dispatch(supplied({ adapter: COMPOUND_ADAPTER, collateral: UNI, txHash: TX, logIndex: 0 }));
    await harness.dispatch(snapshot({ collateral: UNI, debt: USDC, txHash: TX, logIndex: 1 }));

    expect(await venueOf(UNI, USDC, TX)).toBe("COMPOUND_V3");
  });

  it("matches the currency regardless of its casing", async () => {
    await registerAccount();
    await harness.dispatch(
      supplied({ adapter: COMPOUND_ADAPTER, collateral: UNI_CHECKSUMMED, txHash: TX, logIndex: 0 })
    );
    await harness.dispatch(snapshot({ collateral: UNI, debt: USDC, txHash: TX, logIndex: 1 }));

    expect(await venueOf(UNI, USDC, TX)).toBe("COMPOUND_V3");
  });

  // The epoch is opened by the snapshot with no prior row, so the curated event that follows takes
  // the branch where `existing` is null.
  it("opens from a curated event with no prior epoch and no staged flows", async () => {
    await registerAccount();
    await harness.dispatch(supplied({ adapter: COMPOUND_ADAPTER, collateral: UNI, txHash: TX, logIndex: 0 }));
    await harness.dispatch({
      name: "MarginRouter:PositionIncreased",
      args: {
        owner: OWNER,
        account: ACCOUNT,
        collateral: UNI,
        debt: USDC,
        equity: E18,
        collateralBought: E18,
        debtDrawn: 1000n * E6,
        collateralTotal: 2n * E18,
        debtTotal: 1000n * E6,
        currentLtv: 500000000000000000n,
        maxLtv: 860000000000000000n,
        healthFactorWad: 2n * E18,
      },
      ...at(TX, 1),
    });

    expect(await venueOf(UNI, USDC, TX)).toBe("COMPOUND_V3");
  });
});

describe("the hint is refused when the transaction touched two adapters", () => {
  // Two pairs on one clone, each with its own adapter. An account-wide key would hand one pair's
  // venue to the other; each pair must resolve from its own currencies.
  it("attributes each pair separately when both legs name their own currencies", async () => {
    await registerAccount();
    await harness.dispatch(supplied({ adapter: COMPOUND_ADAPTER, collateral: UNI, txHash: TX, logIndex: 0 }));
    await harness.dispatch(snapshot({ collateral: UNI, debt: USDC, txHash: TX, logIndex: 1 }));
    await harness.dispatch(supplied({ adapter: AAVE_ADAPTER, collateral: WETH, txHash: TX, logIndex: 2 }));
    await harness.dispatch(snapshot({ collateral: WETH, debt: USDC, txHash: TX, logIndex: 3 }));

    expect(await venueOf(UNI, USDC, TX)).toBe("COMPOUND_V3");
    expect(await venueOf(WETH, USDC, TX)).toBe("AAVE_V3");
  });

  // The latch compares adapter ADDRESSES. A venue-keyed latch would not fire here — an unmapped
  // adapter yields no second venue — and would wrongly stamp COMPOUND_V3.
  it("refuses when a second, unmapped adapter touched the same currency", async () => {
    await registerAccount();
    await harness.dispatch(supplied({ adapter: COMPOUND_ADAPTER, collateral: UNI, txHash: TX, logIndex: 0 }));
    await harness.dispatch(borrowed({ adapter: UNMAPPED_ADAPTER, debt: USDC, txHash: TX, logIndex: 1 }));
    await harness.dispatch(snapshot({ collateral: UNI, debt: USDC, txHash: TX, logIndex: 2 }));

    expect(await venueOf(UNI, USDC, TX)).toBe("UNKNOWN");
  });
});

describe("an unattributed epoch is repaired by a later transaction", () => {
  it("upgrades UNKNOWN to the observed venue, and never rewrites a known one", async () => {
    await registerAccount();
    // Opened with no clone event at all, so it lands UNKNOWN.
    await harness.dispatch(snapshot({ collateral: UNI, debt: USDC, txHash: TX, logIndex: 0 }));
    expect(await venueOf(UNI, USDC, TX)).toBe("UNKNOWN");

    // A later transaction on the live epoch names the adapter.
    await harness.dispatch(supplied({ adapter: COMPOUND_ADAPTER, collateral: UNI, txHash: TX_2, logIndex: 0 }));
    await harness.dispatch(snapshot({ collateral: UNI, debt: USDC, txHash: TX_2, logIndex: 1, collateralTotal: 3n * E18 }));
    expect(await venueOf(UNI, USDC, TX)).toBe("COMPOUND_V3");

    // A third transaction on a different adapter must not move it.
    await harness.dispatch(supplied({ adapter: AAVE_ADAPTER, collateral: UNI, txHash: ("0x" + "c3".repeat(32)) as Hex, logIndex: 0 }));
    await harness.dispatch(
      snapshot({ collateral: UNI, debt: USDC, txHash: ("0x" + "c3".repeat(32)) as Hex, logIndex: 1, collateralTotal: 4n * E18 })
    );
    expect(await venueOf(UNI, USDC, TX)).toBe("COMPOUND_V3");
  });

  // A terminal snapshot can arrive with no adapter-bearing clone event of its own, so the hint in
  // scope may belong to another leg of the transaction. It must not be adopted.
  it("does not stamp a venue on a terminal snapshot", async () => {
    await registerAccount();
    await harness.dispatch(snapshot({ collateral: UNI, debt: USDC, txHash: TX, logIndex: 0 }));
    expect(await venueOf(UNI, USDC, TX)).toBe("UNKNOWN");

    // Another pair's Aave leg supplies the only sighting in this transaction.
    await harness.dispatch(supplied({ adapter: AAVE_ADAPTER, collateral: WETH, txHash: TX_2, logIndex: 0 }));
    await harness.dispatch(
      snapshot({ collateral: UNI, debt: USDC, txHash: TX_2, logIndex: 1, collateralTotal: 0n, debtTotal: 0n })
    );

    expect(await venueOf(UNI, USDC, TX)).toBe("UNKNOWN");
  });
});
