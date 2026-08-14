import { resolve } from "node:path";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      // ponder virtual modules, stubbed for tests
      "ponder:registry": resolve(__dirname, "test/support/ponderRegistry.ts"),
      "ponder:schema": resolve(__dirname, "ponder.schema.ts"),
      // deep import blocked by ponder's exports map; used for schema DDL
      "ponder-internal-kit": resolve(__dirname, "node_modules/ponder/dist/esm/drizzle/kit/index.js"),
    },
  },
  test: {
    include: ["test/**/*.test.ts"],
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
