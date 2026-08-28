/**
 * MarginAccount clone events. They carry two things nothing else does: both of a pair's currencies,
 * and the ADAPTER each action ran through.
 *
 * An Aave event names a single reserve. `resolvePair` recovers the pair from the market registry, and
 * when several registered markets share that reserve in the same role it falls back to "which pair does
 * this account already hold?" — which finds nothing on a first-ever open. Those flows stage with a null
 * pair for a router event later in the transaction to complete. An owner who calls `supplyCollateral` /
 * `borrow` on the clone directly (MarginAccount authorizes owner as well as manager) routes around the
 * router entirely, so no router event ever arrives and nothing completes them.
 *
 * The clone's own events name both currencies: `CollateralSupplied` the collateral, `Borrowed` the debt.
 * Together they identify the pair with no registry lookup and no prior position.
 *
 * The adapter is what identifies the VENUE for a position the flow layer cannot attribute. Compound
 * has no flow-truth layer, so a Compound transaction stages no lendingEvent rows and `drainFlows`
 * leaves the venue UNKNOWN; the clone names its adapter on every path, including the owner escape
 * hatch. The router calls the account and only then emits its snapshot (MarginRouter._emitPosition),
 * so the observation is always in hand before the handler that needs it runs.
 *
 * AMOUNTS ARE DELIBERATELY IGNORED HERE. `recordFlow` is the single writer of position balances, driven
 * by the venue events; reading amounts here would double-count every operation. These events are also
 * not a complete source of truth on their own — `MarginAccount.execute` emits only `Executed`, naming
 * neither currency.
 */
import { ponder } from "ponder:registry";
import { lendingMarket } from "ponder:schema";
import { and, eq } from "ponder";
import type { Context } from "ponder:registry";

import { applyStagedFlows } from "./lendingFlows";
import { lower } from "./helpers";
import { VENUE_BY_ADAPTER } from "./markets";

// Per-account observations within ONE transaction. Held in memory rather than a table: it is scratch
// state that never outlives a transaction. Ponder awaits handlers one at a time and pages events
// block-aligned, so a crash or reorg replays the whole transaction and rebuilds this alongside the staged
// rows it reads.
//
// Scoped to a single txHash and reset when a new one appears, so entries cannot accumulate — a
// collateral-only add, a borrow-only op, or an unregistered pair all leave an observation that nothing
// consumes, and without the reset those would grow without bound for the process lifetime.
type Observed = { collateral?: `0x${string}`; debt?: `0x${string}` };
let pendingTxHash: `0x${string}` | undefined;
let pending = new Map<string, Observed>();

function observe(txHash: `0x${string}`, account: string, update: Observed): void {
  if (pendingTxHash !== txHash) {
    pendingTxHash = txHash;
    pending = new Map();
  }
  pending.set(account, { ...(pending.get(account) ?? {}), ...update });
}

/**
 * Adapter sightings, keyed by the CURRENCY and ROLE each event names — supply/withdraw name the
 * collateral, borrow/repay the debt. Per-currency rather than per-account because one transaction can
 * drive one clone through two adapters for two different pairs, and an account-wide key would hand
 * one pair's venue to the other. Kept beside `pending` rather than on it: `tryResolve` deletes its
 * entry, which would take the sighting with it.
 */
type Sighting = { adapter: `0x${string}`; logIndex: number };
let venueTxHash: `0x${string}` | undefined;
let sightings = new Map<string, Sighting[]>();

const sightingKey = (account: string, currency: string, role: "collateral" | "debt"): string =>
  `${lower(account)}-${lower(currency)}-${role}`;

function observeAdapter(args: {
  txHash: `0x${string}`;
  account: string;
  currency: `0x${string}`;
  role: "collateral" | "debt";
  adapter: `0x${string}`;
  logIndex: number;
}): void {
  if (venueTxHash !== args.txHash) {
    venueTxHash = args.txHash;
    sightings = new Map();
  }
  const key = sightingKey(args.account, args.currency, args.role);
  sightings.set(key, [...(sightings.get(key) ?? []), { adapter: args.adapter, logIndex: args.logIndex }]);
}

/**
 * The venue this transaction drove the pair through, or undefined when it cannot be told.
 *
 * The pair's two currency slots are read together and the LATEST sighting wins: `_emitPosition`
 * always immediately follows the account call that caused it, so the most recent adapter is the one
 * whose action the snapshot describes. Two distinct adapter ADDRESSES across the pair means the
 * transaction touched two venues and neither can be attributed — compared by address, not by mapped
 * venue, so an adapter missing from the registry still forces the ambiguous answer rather than
 * silently leaving one venue standing.
 */
export function observedVenue(args: {
  txHash: `0x${string}`;
  account: string;
  collateral: `0x${string}`;
  debt: `0x${string}`;
}): "MORPHO" | "AAVE_V3" | "AAVE_V4" | "COMPOUND_V3" | undefined {
  if (venueTxHash !== args.txHash) return undefined;
  const seen = [
    ...(sightings.get(sightingKey(args.account, args.collateral, "collateral")) ?? []),
    ...(sightings.get(sightingKey(args.account, args.debt, "debt")) ?? []),
  ];
  if (seen.length === 0) return undefined;
  if (new Set(seen.map((s) => lower(s.adapter))).size > 1) return undefined;
  const latest = seen.reduce((a, b) => (b.logIndex > a.logIndex ? b : a));
  return VENUE_BY_ADAPTER[lower(latest.adapter)];
}

/** Test-only: the module-level scratch maps outlive a replay harness's per-test reset. */
export function _resetObservationsForTests(): void {
  pendingTxHash = undefined;
  pending = new Map();
  venueTxHash = undefined;
  sightings = new Map();
}

/**
 * Complete the transaction's staged flows once both currencies are known — but only for a pair the
 * registry actually registered. A clone can be driven through any adapter by its owner, so an
 * unregistered pair is refused rather than invented.
 */
async function tryResolve(
  context: Context,
  { txHash, account }: { txHash: `0x${string}`; account: `0x${string}` }
): Promise<void> {
  const seen = pending.get(lower(account));
  if (!seen?.collateral || !seen.debt) {
    return;
  }
  const registered = await context.db.sql
    .select()
    .from(lendingMarket)
    .where(
      and(
        eq(lendingMarket.collateral, lower(seen.collateral) as `0x${string}`),
        eq(lendingMarket.debt, lower(seen.debt) as `0x${string}`)
      )
    );
  if (registered.length === 0) {
    return;
  }
  await applyStagedFlows(context, { txHash, account, collateral: seen.collateral, debt: seen.debt });
  pending.delete(lower(account));
}

ponder.on("MarginAccounts:CollateralSupplied", async ({ event, context }) => {
  const account = event.log.address as `0x${string}`;
  observe(event.transaction.hash, lower(account), { collateral: event.args.collateral });
  observeAdapter({
    txHash: event.transaction.hash,
    account,
    currency: event.args.collateral,
    role: "collateral",
    adapter: event.args.adapter,
    logIndex: event.log.logIndex,
  });
  await tryResolve(context, { txHash: event.transaction.hash, account });
});

ponder.on("MarginAccounts:Borrowed", async ({ event, context }) => {
  const account = event.log.address as `0x${string}`;
  observe(event.transaction.hash, lower(account), { debt: event.args.debt });
  observeAdapter({
    txHash: event.transaction.hash,
    account,
    currency: event.args.debt,
    role: "debt",
    adapter: event.args.adapter,
    logIndex: event.log.logIndex,
  });
  await tryResolve(context, { txHash: event.transaction.hash, account });
});

// Exit legs: adapter only. They name no new currency the pair layer needs, but a transaction that
// only withdraws or repays still has to be attributable.
ponder.on("MarginAccounts:CollateralWithdrawn", async ({ event }) => {
  observeAdapter({
    txHash: event.transaction.hash,
    account: event.log.address as `0x${string}`,
    currency: event.args.collateral,
    role: "collateral",
    adapter: event.args.adapter,
    logIndex: event.log.logIndex,
  });
});

ponder.on("MarginAccounts:Repaid", async ({ event }) => {
  observeAdapter({
    txHash: event.transaction.hash,
    account: event.log.address as `0x${string}`,
    currency: event.args.debt,
    role: "debt",
    adapter: event.args.adapter,
    logIndex: event.log.logIndex,
  });
});
