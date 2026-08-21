import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { graphql } from "ponder";

const app = new Hono();

// GraphQL at /graphql (and SQL over HTTP at /sql via @ponder/client, enabled by default)
app.use("/graphql", graphql({ db, schema }));

export default app;
