import type { Context } from "ponder:registry";
import { account, activePosition, lendingEvent, position, token } from "ponder:schema";
import { and, eq } from "ponder";
import { erc20Abi, getAddress } from "viem";

export const WAD = 10n ** 18n;

export const clamp0 = (x: bigint): bigint => (x < 0n ? 0n : x);

export const lower = (a: string): string => a.toLowerCase();

/** Deterministic pointer key for the live position of an (account, pair). */
export const pairKey = (accountAddr: string, collateral: string, debt: string): string =>
  `${lower(accountAddr)}-${lower(collateral)}-${lower(debt)}`;

/** Position row id: one epoch per (account, pair, opening tx). */
export const positionId = (accountAddr: string, collateral: string, debt: string, openTxHash: string): string =>
  `${pairKey(accountAddr, collateral, debt)}-${lower(openTxHash)}`;

export const eventId = (txHash: string, logIndex: number): string => `${lower(txHash)}-${logIndex}`;

/** The log index encoded in a `${txHash}-${logIndex}` row id. Ordering by the id string is lexical,
 *  which sorts logIndex 12 before 8; parse it out to compare numerically. */
export const logIndexOf = (id: string): number => Number(id.slice(id.lastIndexOf("-") + 1));

/** Id for the flow-layer synthetic CLOSE action, so a curated router close in
 *  the same tx can find and supersede it (router.ts). */
export const syntheticCloseId = (txHash: string, positionRowId: string): string =>
  `${lower(txHash)}-${positionRowId}-close`;

/** Id for the flow-layer synthetic ADJUST action (execute-driven op with no
 *  router event); a curated router event in the same tx supersedes it. */
export const adjustId = (txHash: string, positionRowId: string): string =>
  `${lower(txHash)}-${positionRowId}-adjust`;

/** Lazily persist ERC-20 metadata so consumers can scale raw amounts. */
export async function ensureToken(context: Context, address: `0x${string}`): Promise<void> {
  const existing = await context.db.find(token, { address });
  if (existing) return;

  let symbol = "UNKNOWN";
  let decimals = 18;
  try {
    decimals = await context.client.readContract({ abi: erc20Abi, address, functionName: "decimals" });
    symbol = await context.client.readContract({ abi: erc20Abi, address, functionName: "symbol" });
  } catch {
    // non-standard token (bytes32 symbol, missing metadata); keep defaults
  }
  await context.db.insert(token).values({ address: getAddress(address), symbol, decimals }).onConflictDoNothing();
}

/** True if `addr` is a known MarginAccount clone. */
export async function isMarginAccount(context: Context, addr: `0x${string}`): Promise<boolean> {
  return (await context.db.find(account, { address: addr })) !== null;
}

/** The live position row for an (account, pair), or null. A pointer to a non-OPEN epoch (left
 *  behind when a router-less close terminated the epoch without clearing the pointer) is treated
 *  as no live position, so the next opening flow starts a fresh epoch and overwrites the pointer. */
export async function findActivePosition(
  context: Context,
  accountAddr: `0x${string}`,
  collateral: `0x${string}`,
  debt: `0x${string}`
) {
  const pointer = await context.db.find(activePosition, { id: pairKey(accountAddr, collateral, debt) });
  if (!pointer) return null;
  const row = await context.db.find(position, { id: pointer.positionId });
  return row && row.status === "OPEN" ? row : null;
}

/** Every lending flow staged for a (tx, account), applied or not. */
export async function txLendingEvents(context: Context, txHash: `0x${string}`, accountAddr: `0x${string}`) {
  const rows = await context.db.sql
    .select()
    .from(lendingEvent)
    .where(and(eq(lendingEvent.txHash, txHash), eq(lendingEvent.account, accountAddr)));
  // All rows share this tx; order by numeric log index (the id sorts lexically — 12 before 8).
  return rows.sort((a, b) => logIndexOf(a.id) - logIndexOf(b.id));
}
