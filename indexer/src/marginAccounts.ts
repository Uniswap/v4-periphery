/**
 * MarginAccount clone events, used for ONE thing: resolving an Aave flow's (collateral, debt) pair.
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
  await tryResolve(context, { txHash: event.transaction.hash, account });
});

ponder.on("MarginAccounts:Borrowed", async ({ event, context }) => {
  const account = event.log.address as `0x${string}`;
  observe(event.transaction.hash, lower(account), { debt: event.args.debt });
  await tryResolve(context, { txHash: event.transaction.hash, account });
});
