/**
 * In-memory replay harness: real ponder.schema.ts DDL applied to PGlite, a
 * thin `context.db` adapter over drizzle matching the ponder store surface the
 * handlers use, a recorded `readContract` stub, and an event dispatcher that
 * replays decoded logs through the handlers recorded by the registry stub.
 */
import { PGlite } from "@electric-sql/pglite";
import { and, eq, getTableColumns, is } from "drizzle-orm";
import { PgTable } from "drizzle-orm/pg-core";
import { drizzle } from "drizzle-orm/pglite";
import { getSql } from "ponder-internal-kit";

import * as schema from "ponder:schema";

// handler registration side effects: every src module records into the registry stub
import "../../src/aave";
import "../../src/lendingFlows";
import { _resetObservationsForTests } from "../../src/marginAccounts";
import "../../src/markets";
import "../../src/morpho";
import "../../src/pools";
import "../../src/router";

import { getHandler } from "./ponderRegistry";

type Hex = `0x${string}`;

// ---------------------------------------------------------------------------
// database
// ---------------------------------------------------------------------------

const onchainTables = Object.values(schema).filter((exported) => is(exported, PgTable)) as unknown as PgTable[];
if (onchainTables.length === 0) throw new Error("schema exports produced no tables — reset would be a no-op");

async function applyDdl(client: PGlite): Promise<void> {
  const ddl = getSql(schema as Record<string, unknown>);
  const statements = [
    ...ddl.enums.sql,
    // reorg bookkeeping tables reference ponder-managed sequences; tests don't reorg
    ...ddl.tables.sql.filter((statement) => !statement.includes("_reorg__")),
    ...ddl.indexes.sql,
  ];
  for (const statement of statements) {
    await client.exec(statement);
  }
}

// ---------------------------------------------------------------------------
// context.db adapter (ponder store surface used by src/)
// ---------------------------------------------------------------------------

type Row = Record<string, unknown>;
type Key = Record<string, unknown>;
type Drizzle = ReturnType<typeof drizzle>;

function keyWhere(table: PgTable, key: Key) {
  const columns = getTableColumns(table);
  const clauses = Object.entries(key).map(([name, value]) => {
    const column = columns[name];
    if (!column) throw new Error(`unknown key column "${name}"`);
    return eq(column, value);
  });
  return clauses.length === 1 ? clauses[0]! : and(...clauses);
}

function primaryKeyOf(table: PgTable, row: Row): Key {
  const pkColumns = Object.entries(getTableColumns(table)).filter(([, column]) => column.primary);
  if (pkColumns.length === 0) throw new Error("table has no single-column primary key");
  return Object.fromEntries(pkColumns.map(([name]) => [name, row[name]]));
}

function makeStore(db: Drizzle) {
  async function find(table: PgTable, key: Key): Promise<Row | null> {
    const rows = await db
      .select()
      .from(table as never)
      .where(keyWhere(table, key))
      .limit(1);
    return (rows[0] as Row | undefined) ?? null;
  }

  function insert(table: PgTable, values: Row | Row[]) {
    const rows = Array.isArray(values) ? values : [values];

    const plain = async (): Promise<void> => {
      await db.insert(table as never).values(rows as never);
    };

    return {
      then(onFulfilled?: (value: void) => unknown, onRejected?: (reason: unknown) => unknown) {
        return plain().then(onFulfilled, onRejected);
      },
      onConflictDoNothing: async (): Promise<void> => {
        await db
          .insert(table as never)
          .values(rows as never)
          .onConflictDoNothing();
      },
      onConflictDoUpdate: async (update: Row | ((row: Row) => Row)): Promise<void> => {
        for (const row of rows) {
          const key = primaryKeyOf(table, row);
          const existing = await find(table, key);
          if (existing) {
            const set = typeof update === "function" ? update(existing) : update;
            await db
              .update(table as never)
              .set(set as never)
              .where(keyWhere(table, key));
          } else {
            await db.insert(table as never).values(row as never);
          }
        }
      },
    };
  }

  return {
    find,
    insert: (table: PgTable) => ({ values: (values: Row | Row[]) => insert(table, values) }),
    update: (table: PgTable, key: Key) => ({
      set: async (update: Row | ((row: Row) => Row)): Promise<Row> => {
        const existing = await find(table, key);
        if (!existing) throw new Error(`update on missing row: ${JSON.stringify(key)}`);
        const set = typeof update === "function" ? update(existing) : update;
        const updated = await db
          .update(table as never)
          .set(set as never)
          .where(keyWhere(table, key))
          .returning();
        return updated[0] as Row;
      },
    }),
    delete: async (table: PgTable, key: Key): Promise<boolean> => {
      const deleted = (await db
        .delete(table as never)
        .where(keyWhere(table, key))
        .returning()) as unknown as Row[];
      return deleted.length > 0;
    },
    sql: db,
  };
}

// ---------------------------------------------------------------------------
// readContract stub
// ---------------------------------------------------------------------------

export interface ReadCall {
  address: Hex;
  functionName: string;
  args?: readonly unknown[];
  blockNumber?: bigint;
}

/** One log of a stubbed transaction receipt, as `recordTxSwaps` reads it. */
export interface ReceiptLogStub {
  address: Hex;
  topics: [Hex, ...Hex[]];
  data: Hex;
  logIndex: number;
}

interface ReadStub {
  match: (call: ReadCall) => boolean;
  result: (call: ReadCall) => unknown;
}

// ---------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------

export interface HarnessEvent {
  name: string;
  args: Record<string, unknown>;
  txHash: Hex;
  logIndex: number;
  blockNumber: bigint;
  timestamp: bigint;
  logAddress?: Hex;
}

export interface Harness {
  context: {
    db: ReturnType<typeof makeStore>;
    client: {
      readContract: (call: ReadCall) => Promise<unknown>;
      getTransactionReceipt: (args: { hash: Hex }) => Promise<{ logs: ReceiptLogStub[] }>;
    };
    chain: { id: number };
  };
  db: Drizzle;
  /** Replay one decoded event through its recorded handler. */
  dispatch: (event: HarnessEvent) => Promise<void>;
  /** Register a chain-read stub; later registrations win. */
  onRead: (match: Partial<Pick<ReadCall, "address" | "functionName">>, result: unknown | ((call: ReadCall) => unknown)) => void;
  /**
   * Add logs to a transaction's stubbed receipt. Swaps reach the indexer only through
   * `recordTxSwaps` reading the receipt, so this is how a test stages a v4 Swap.
   */
  onReceiptLogs: (txHash: Hex, logs: ReceiptLogStub[]) => void;
  readCalls: ReadCall[];
  reset: () => Promise<void>;
  close: () => Promise<void>;
}

export async function createHarness(): Promise<Harness> {
  const client = new PGlite();
  await applyDdl(client);
  const db = drizzle(client);

  const stubs: ReadStub[] = [];
  const readCalls: ReadCall[] = [];
  const receiptLogs = new Map<string, ReceiptLogStub[]>();

  const context = {
    db: makeStore(db),
    client: {
      readContract: async (call: ReadCall): Promise<unknown> => {
        readCalls.push(call);
        for (let i = stubs.length - 1; i >= 0; i--) {
          if (stubs[i]!.match(call)) return stubs[i]!.result(call);
        }
        throw new Error(`unstubbed readContract: ${call.functionName} @ ${call.address}`);
      },
      getTransactionReceipt: async ({ hash }: { hash: Hex }): Promise<{ logs: ReceiptLogStub[] }> => ({
        logs: receiptLogs.get(hash.toLowerCase()) ?? [],
      }),
    },
    chain: { id: 1 },
  };

  return {
    context,
    db,
    dispatch: async (event: HarnessEvent): Promise<void> => {
      await getHandler(event.name)({
        event: {
          args: event.args,
          log: { logIndex: event.logIndex, address: event.logAddress ?? "0x0000000000000000000000000000000000000000" },
          transaction: { hash: event.txHash, to: null },
          block: { number: event.blockNumber, timestamp: event.timestamp },
        },
        context,
      });
    },
    onRead: (match, result) => {
      stubs.push({
        match: (call) =>
          (match.address === undefined || call.address.toLowerCase() === match.address.toLowerCase()) &&
          (match.functionName === undefined || call.functionName === match.functionName),
        result: typeof result === "function" ? (result as (call: ReadCall) => unknown) : () => result,
      });
    },
    onReceiptLogs: (txHash, logs) => {
      const key = txHash.toLowerCase();
      receiptLogs.set(key, [...(receiptLogs.get(key) ?? []), ...logs]);
    },
    readCalls,
    reset: async (): Promise<void> => {
      // src module scratch state is tx-scoped, not test-scoped, so it outlives a table wipe.
      _resetObservationsForTests();
      stubs.length = 0;
      readCalls.length = 0;
      receiptLogs.clear();
      for (const table of onchainTables) {
        await db.delete(table as never);
      }
    },
    close: async (): Promise<void> => {
      await client.close();
    },
  };
}
