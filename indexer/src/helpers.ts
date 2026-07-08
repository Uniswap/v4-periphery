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

/** The live position row for an (account, pair), or null. */
export async function findActivePosition(
  context: Context,
  accountAddr: `0x${string}`,
  collateral: `0x${string}`,
  debt: `0x${string}`
) {
  const pointer = await context.db.find(activePosition, { id: pairKey(accountAddr, collateral, debt) });
  if (!pointer) return null;
  return await context.db.find(position, { id: pointer.positionId });
}

/** Every lending flow staged for a (tx, account), applied or not. */
export async function txLendingEvents(context: Context, txHash: `0x${string}`, accountAddr: `0x${string}`) {
  return await context.db.sql
    .select()
    .from(lendingEvent)
    .where(and(eq(lendingEvent.txHash, txHash), eq(lendingEvent.account, accountAddr)))
    .orderBy(lendingEvent.id);
}
