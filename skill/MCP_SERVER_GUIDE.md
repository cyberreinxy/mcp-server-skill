# Building MCP Servers — Guide for AI Coding Agents

Author: cyberreinxy (https://github.com/cyberreinxy)
License: MIT

You are helping build, review, or debug an MCP (Model Context Protocol) server — a server that exposes tools, resources, and prompts to AI agents. This guide is security-first and database-first (Postgres especially), because that's where MCP servers most often break in production. Apply it whenever the task involves MCP servers, connecting an agent to a database or API, or reviewing a PR against one.

## 1. Core protocol model

MCP servers expose three primitive types:

- **Tools** — actions with side effects or computation, invoked by the model (`run_query`, `create_task`). The model decides when to call them based on the tool's description — write descriptions like documentation for the model, not code comments.
- **Resources** — addressable, mostly-static data attached to context (a file, a schema doc). Not invoked mid-reasoning like a tool.
- **Prompts** — reusable, user-triggered templates. Rarely needed for database servers.

Don't make everything a tool just because it's easier to wire up. An overloaded tool list degrades the model's tool-selection accuracy.

## 2. Designing the tool surface

1. **Start from the task, not the schema.** Don't emit one tool per SQL verb (`select`/`insert`/`update`/`delete`) — that forces the model to write raw SQL, which is where injection risk lives. Prefer task-shaped tools (`find_customer_orders`, `update_inventory_count`) that build parameterized queries internally, plus at most one tightly-scoped `run_read_query` escape hatch if free-form querying is genuinely needed (see §5).
2. **Write tool descriptions for the model.** State what it does, when to use it vs. a sibling tool, what parameters mean, and what failure looks like.
3. **Return structured, bounded output.** Cap row counts by default, truncate huge fields, and return an explicit `truncated: true` flag rather than silently dropping data.
4. **Validate input server-side even though the schema "already validated" it.** JSON Schema on a tool definition is a hint to the model, not a security boundary — treat every tool call like an untrusted request, because it can be influenced by content the model read elsewhere (a fetched page, a file, another tool's output — i.e. prompt injection).
5. **Fail loud in dev, quiet in prod.** Errors should help the model self-correct (`"column 'usr_id' does not exist — did you mean 'user_id'?"`) without leaking internals (connection strings, stack traces, hostnames) in production.

## 3. Minimal server skeleton (TypeScript, `@modelcontextprotocol/sdk` v1.x)

```ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const server = new McpServer({ name: "pg-mcp-server", version: "1.0.0" });

server.registerTool(
  "describe_table",
  {
    title: "Describe table",
    description:
      "Returns column names, types, nullability, and constraints for a table. " +
      "Call this before writing any query against a table you haven't inspected " +
      "this session — column names are not guessable from the table name alone.",
    inputSchema: {
      schema: z.string().describe("Postgres schema name, e.g. 'public'"),
      table: z.string().describe("Table name, without schema prefix"),
    },
  },
  async ({ schema, table }) => {
    // implementation — see §6 for parameterized information_schema queries
    return { content: [{ type: "text", text: "..." }] };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
```

Transport choice: **stdio** for local servers launched as a subprocess by an IDE/desktop client (simplest, no auth needed — the parent process owns the child). **Streamable HTTP** only if the server must be remote/hosted — this requires you to handle auth yourself (OAuth or bearer token); MCP does not provide auth for free. Don't add an HTTP transport "for flexibility" if stdio would do the job — it's the most common source of unrequested scope creep in MCP server PRs (a whole Express app + auth layer nobody asked for).

## 4. The non-negotiables

- **Parameterize everything.** No string-built SQL, ever — not even for identifiers you assume the model "shouldn't" influence. Use your driver's parameterized query API for values, and a live allow-list (from `information_schema`, never from model free text) for identifiers like table/column names.
- **Least-privilege DB role.** The connection should use a role scoped to exactly what the tools need. This is the real security boundary — not application-level query validation.
- **Pin install/build scripts.** If the server ships a `postinstall`/`prepare` script, pin exact versions and checksums, and never fetch-and-execute from a URL. This is the most common supply-chain hole in published MCP servers.
- **Mask errors in production, keep them rich in dev.** A raw driver error can leak schema details, IPs, or partial query text.
- **Invalidate caches, don't just add them.** If you cache schema/introspection data, provide an explicit invalidation path (DDL trigger, TTL, or manual refresh tool). A stale schema cache makes the model write confidently broken queries — worse than no cache.
- **Keep PRs scoped.** A PR titled "security fix" should not also add a dashboard, delete `CONTRIBUTING.md`, or hand-edit build output (`dist/*.bundle.*`). Flag scope creep explicitly rather than accepting the whole bundle because part of it is good.

## 5. Postgres: safe free-form querying (`run_query` escape hatch)

If offering free-form querying at all, constrain it hard:

1. **Read-only at the role level, not just in application code:**
   ```sql
   create role mcp_readonly with login password '...';
   grant connect on database appdb to mcp_readonly;
   grant usage on schema public to mcp_readonly;
   grant select on all tables in schema public to mcp_readonly;
   alter default privileges in schema public grant select on tables to mcp_readonly;
   ```
   This is the actual security boundary. Query-text validation (blocking `DROP`/`DELETE` via string matching or a hand-rolled parser) is a UX nicety on top of it, never a substitute — string/keyword matching is trivially bypassed (comments, case, `;`-chaining). Treat a "SQL parser rewrite" that isn't paired with role-level restriction as not actually having fixed anything.
2. **Run inside a transaction you control, even with a read-only role (defense in depth):**
   ```ts
   const client = await pool.connect();
   try {
     await client.query("BEGIN TRANSACTION READ ONLY");
     await client.query("SET LOCAL statement_timeout = '5s'");
     const result = await client.query(sql, params);
     return result.rows;
   } finally {
     await client.query("ROLLBACK").catch(() => {});
     client.release();
   }
   ```
3. **Cap and label result size:**
   ```ts
   const capped = rows.slice(0, MAX_ROWS);
   return { rows: capped, truncated: rows.length > MAX_ROWS, rowCountBeforeTruncation: rows.length };
   ```
4. **Never accept table/column names as raw string interpolation, even here.** Validate against a live `information_schema` allow-list before building the query.

## 6. Postgres: schema introspection

```sql
-- columns for a table — always parameterize schema/table, never string-concat
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = $1 and table_name = $2
order by ordinal_position;

-- list user tables, excluding system schemas
select table_schema, table_name
from information_schema.tables
where table_schema not in ('pg_catalog', 'information_schema')
  and table_type = 'BASE TABLE';

-- foreign keys, so the model can join correctly instead of guessing
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

Cache this output for latency, with an invalidation path: TTL (e.g. 60s) is the simple default; DDL-triggered invalidation is better for long-lived servers; always also provide a manual `refresh_schema_cache` tool as an escape hatch.

## 7. Connection pooling

```ts
import { Pool } from "pg";
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});
```

Always release clients back to the pool in a `finally` block — a leaked client under load is the most common cause of "works in testing, hangs in real use." Don't hold a client checked out across an `await` for non-DB work.

## 8. Error handling pattern

```ts
try {
  const result = await pool.query(sql, params);
  return { content: [{ type: "text", text: JSON.stringify(result.rows) }] };
} catch (err) {
  if (process.env.NODE_ENV === "production") {
    return { content: [{ type: "text", text: friendlyMessage(err) }], isError: true };
  }
  throw err; // full detail in dev
}

function friendlyMessage(err: unknown): string {
  const code = (err as { code?: string })?.code;
  if (code === "42703") return "One of the referenced columns doesn't exist — try describe_table first.";
  if (code === "42P01") return "That table doesn't exist in this schema — try list_tables first.";
  return "The query failed. Try describe_table to confirm the schema, or simplify the query.";
}
```

## 9. Reviewing PRs / contributions to an MCP server

**Scope check first, before reading diff lines in detail:**
1. Restate what the PR claims to do, in one sentence.
2. List every file it touches; ask whether each belongs to the claimed scope.
3. Flag out-of-scope changes explicitly, even if individually good: new dependencies/subsystems not mentioned in the description (bundled dashboard, new HTTP server), deleted `CONTRIBUTING.md`/`.gitattributes`/CI config, hand-edited build output (`dist/*`, `*.bundle.*`), changes to install/postinstall scripts.
4. If scope creep exists, say so explicitly and recommend splitting the PR — don't silently accept the bundle, and don't silently strip parts without flagging it.

**Security checks once scope is confirmed:** parameterization + identifier allow-listing; no hand-rolled SQL parser as the *only* defense; production errors don't leak internals; cross-platform path handling (e.g. `pg_dump` invocation) doesn't hardcode POSIX paths; cache invalidation exists if a cache was added; install scripts remain pinned.

## 10. Testing and running

- **MCP Inspector** for standalone testing before wiring into any client: `npx @modelcontextprotocol/inspector node build/index.js`. Confirm tool descriptions are self-explanatory, error messages are self-correcting, and large results are truncated with a visible flag.
- **Claude Desktop config** (`claude_desktop_config.json`): use absolute paths, put credentials in `env`, restart fully after changes.
- **Claude Code**: `claude mcp add <name> -- node /absolute/path/to/build/index.js`, or a project-level `.mcp.json`.
- **npm packaging**: set `bin` + `#!/usr/bin/env node` shebang if runnable via `npx`; pin dependency versions, especially the DB driver; document required env vars prominently in the README.
- **Versioning**: tool name/input-schema changes are breaking changes for anyone with the server already configured — from the model's perspective, the tool signature is the API. Bump major version and note it in release notes.

## 11. Common failure modes

- **Server doesn't show up at all**: JSON syntax error in config; relative (not absolute) path; server crashes before completing the handshake — run it directly and watch stderr; Node version mismatch.
- **Tools don't appear or never get called**: `server.connect(transport)` never completed; vague/overlapping tool descriptions; a JSON Schema feature (complex nested `oneOf`/`anyOf`) the client doesn't support.
- **Calls fail silently or return empty**: wrong MCP content shape returned (must be `{ content: [...] }`); pool exhaustion under bursts of calls in one turn; a "read" tool internally attempting a write against a read-only role (usually correct behavior — give logging its own path/role instead of loosening the main grant).
- **Works in Inspector, breaks with a real model in the loop**: the model constructs inputs Inspector never exercised (edge-case strings, long params); the model chains calls in an order you didn't anticipate — make error messages guide it back rather than assuming a fixed call order.
- **Schema/data looks stale**: almost always a caching issue — add or use a manual refresh tool as the fastest diagnostic.
