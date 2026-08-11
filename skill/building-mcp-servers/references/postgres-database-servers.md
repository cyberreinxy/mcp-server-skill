# Postgres (and general SQL) MCP Servers

Read this whenever the MCP server touches a SQL database — this is where the real-world failures cluster.

## Schema introspection

Don't hand-maintain a schema description; pull it live from `information_schema` / `pg_catalog`, and cache it (see Caching below).

```sql
-- columns for a table — always parameterize schema/table, never string-concat
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = $1 and table_name = $2
order by ordinal_position;
```

For a `list_tables` tool, filter out system schemas explicitly rather than trying to allow-list every user schema:

```sql
select table_schema, table_name
from information_schema.tables
where table_schema not in ('pg_catalog', 'information_schema')
  and table_type = 'BASE TABLE';
```

Expose foreign keys too if the model will be joining across tables — a `describe_table` that only returns columns forces the model to guess at relationships, which produces wrong joins more often than you'd expect:

```sql
select
  tc.constraint_name, kcu.column_name,
  ccu.table_name as foreign_table, ccu.column_name as foreign_column
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name
join information_schema.constraint_column_usage ccu
  on tc.constraint_name = ccu.constraint_name
where tc.constraint_type = 'FOREIGN KEY' and tc.table_name = $1;
```

## The "run_query" escape hatch — how to make it safe

If you're offering free-form querying at all (rather than only task-shaped tools), constrain it hard:

1. **Read-only at the role level, not just in application code.** Connect with a Postgres role that literally cannot write:
   ```sql
   create role mcp_readonly with login password '...';
   grant connect on database appdb to mcp_readonly;
   grant usage on schema public to mcp_readonly;
   grant select on all tables in schema public to mcp_readonly;
   alter default privileges in schema public grant select on tables to mcp_readonly;
   ```
   This is your actual security boundary. Any query-text validation (blocking `DROP`, `DELETE`, etc.) is a UX nicety on top of it, not a substitute for it — string-matching for dangerous keywords is trivially bypassed (comments, case, `;`-chaining) and should never be the only defense. Past incidents in real MCP servers have involved hand-rolled SQL parsers meant to "detect and block" write statements; treat that as a code smell, not a security control — replace it with the role grant, and keep the parser (if any) only as a fast client-side hint.
2. **Always run inside a transaction you control and roll back / set read-only explicitly**, as defense in depth even with a read-only role:
   ```ts
   const client = await pool.connect();
   try {
     await client.query("BEGIN TRANSACTION READ ONLY");
     const result = await client.query(sql, params);
     return result.rows;
   } finally {
     // ROLLBACK discards any writes (none should be possible given the
     // role grants above) and always runs, success or failure.
     await client.query("ROLLBACK").catch(() => {});
     client.release();
   }
   ```
3. **Set a statement timeout.** An agent-constructed query can be an accidental cross join or unbounded scan; don't let it take down the connection pool. `SET LOCAL` only applies for the current transaction, so issue it right after `BEGIN`, before the actual query:
   ```ts
   await client.query("BEGIN TRANSACTION READ ONLY");
   await client.query("SET LOCAL statement_timeout = '5s'");
   const result = await client.query(sql, params);
   ```
4. **Cap and label result size.** `LIMIT` server-side regardless of what the model's query specifies, and tell it you did:
   ```ts
   const capped = rows.slice(0, MAX_ROWS);
   return { rows: capped, truncated: rows.length > MAX_ROWS, rowCountBeforeTruncation: rows.length };
   ```
5. **Never accept table/column names as raw string interpolation, even for a "safe" read-only path.** If a tool takes a table name as a parameter, validate it against the live `information_schema` allow-list from step above before building the query — this is the difference between "user picks from a known set" and "user writes arbitrary identifiers into your SQL."

## Connection pooling

Use a pool (`pg.Pool` in `node-postgres`), not one connection per request — an MCP server can receive bursts of tool calls in a single agent turn (e.g., `describe_table` × 5 followed by a join query).

```ts
import { Pool } from "pg";
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});
```

- Set `max` based on your DB's `max_connections` and how many concurrent server instances might run (Claude Desktop may spawn one process per session).
- Always release clients back to the pool in a `finally` block — a leaked client under load is the most common cause of "server works fine in testing, hangs in real use."
- Don't hold a client checked out across an `await` that calls back into the model or does non-DB work — checkout only for the duration of the actual query.

## Cache invalidation

If you cache `describe_table` / `list_tables` output for latency:

- **TTL is the simple default** (e.g., 60s) — fine for most agent sessions, since schemas rarely change mid-session.
- **DDL-triggered invalidation** is better if the server is long-lived: listen for schema changes via a Postgres event trigger + `NOTIFY`, or simply invalidate the specific table's cache entry whenever a tool call in this same server performs a DDL statement.
- **Always provide a manual `refresh_schema_cache` tool** as an escape hatch — when in doubt, let the model (or the user) force a refresh rather than debugging a stale-cache report blind.
- A cache with no invalidation path at all is worse than no cache — it converts "slow" into "silently wrong," and wrong schema info makes the model write confidently broken queries.

## Error handling pattern

```ts
try {
  const result = await pool.query(sql, params);
  return { content: [{ type: "text", text: JSON.stringify(result.rows) }] };
} catch (err) {
  if (process.env.NODE_ENV === "production") {
    // model-facing: enough to self-correct, nothing internal
    return {
      content: [{ type: "text", text: friendlyMessage(err) }],
      isError: true,
    };
  }
  // dev: full detail
  throw err;
}

function friendlyMessage(err: unknown): string {
  const code = (err as { code?: string })?.code;
  if (code === "42703") return "One of the referenced columns doesn't exist — try describe_table first.";
  if (code === "42P01") return "That table doesn't exist in this schema — try list_tables first.";
  return "The query failed. Try describe_table to confirm the schema, or simplify the query.";
}
```

Never let a raw driver error (which can include the query text, connection details, or server version) pass straight through to the tool response in production.
