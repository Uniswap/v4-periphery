/**
 * Types for the deep import of ponder's drizzle-kit DDL generator
 * (node_modules/ponder/dist/esm/drizzle/kit/index.js — the package exports
 * map blocks the path, so vitest.config.ts aliases it to `ponder-internal-kit`).
 */
declare module "ponder-internal-kit" {
  interface SqlBundle {
    sql: string[];
    json: unknown[];
  }
  export function getSql(schema: Record<string, unknown>): {
    tables: SqlBundle;
    views: SqlBundle;
    enums: SqlBundle;
    indexes: SqlBundle;
  };
}
