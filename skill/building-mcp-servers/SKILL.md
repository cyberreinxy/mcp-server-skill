---
name: building-mcp-servers
description: Use this skill whenever the user wants to design, build, harden, review, or debug an MCP (Model Context Protocol) server — including "build me an MCP server for X", connecting an AI agent/Claude to a database or API, adding tools/resources to an existing MCP server, reviewing a contributor PR against an MCP server, or fixing security issues (SQL injection, unpinned install scripts, error leakage) in one. Especially strong for database MCP servers (Postgres, MySQL, SQLite) — schema introspection, connection pooling, read-only guardrails, and query safety. Trigger this even if the user just says "MCP server" without saying "skill," and even for smaller tasks like adding a single tool or fixing a transport bug.
license: MIT
metadata:
  author: cyberreinxy
  author-url: https://github.com/cyberreinxy
  version: "1.0.0"
---

# Building MCP Servers

A practical, security-first guide to building Model Context Protocol (MCP) servers — servers that expose tools, resources, and prompts to AI agents like Claude. Written with a database-first lens (Postgres especially), because that's where most of the sharp edges live, but the architecture section applies to any MCP server.

This skill exists because most "MCP server tutorials" stop at `npx create-mcp-server` and a toy `add(a, b)` tool. Real MCP servers — the kind that touch a production database — fail in specific, recurring ways: unparameterized SQL, stale schema caches, install scripts that aren't pinned, stack traces leaked to the client, and scope creep in PRs that bundle an unrequested dashboard into a "security fix." This skill encodes the fixes for all of those.

## Step 0: Figure out what's actually being asked

Before writing code, classify the task — it changes what you read next:

| Task | Go to |
|---|---|
| Building a new MCP server from scratch | Sections 1–4, then the relevant reference file |
| Adding a tool/resource to an existing server | Section 2 |
| Server touches a SQL database | `references/postgres-database-servers.md` (do this even if the user didn't ask about security — read it first) |
| Reviewing a PR or contributor patch to an MCP server | `references/security-review-checklist.md` |
| Testing, packaging, or getting the server into Claude Desktop/Claude Code | `references/testing-and-distribution.md` |
| Something's failing silently or the client can't see the server | `references/debugging.md` |

Don't skip the security reference just because the user only asked for a feature. Database MCP servers are agent-facing and internet-facing in ways normal backend code isn't — an LLM will construct arbitrary queries against your tools, including adversarial ones from prompt-injected content it read elsewhere.

## 1. Core protocol model

MCP servers expose three primitive types over a JSON-RPC transport. Get this taxonomy right before writing any code — most bad MCP servers are bad because they use the wrong primitive.

- **Tools** — actions with side effects or computation, invoked by the model (`run_query`, `create_task`). The model decides when to call them. Each tool needs a name, a description the *model* reads to decide relevance (write it like documentation, not a code comment), and a JSON Schema for inputs.
- **Resources** — addressable, mostly-static data the client/user attaches to context (`schema://public/users`, a file, a doc). Not invoked by the model mid-reasoning; think "attachable context," not "callable function."
- **Prompts** — reusable, user-triggered templates (slash-command-like). Rarely needed for database servers; skip unless asked.

Rule of thumb for a Postgres server: `list_schemas`, `describe_table`, `run_query` are tools (the model chooses when to call them and acts on the result). A live ER diagram of the whole database is closer to a resource. Don't make everything a tool just because it's easier to wire up — an overloaded tool list degrades the model's tool-selection accuracy.

## 2. Designing the tool surface

This is the part people rush and regret.

1. **Start from the task, not the schema.** Don't emit one tool per SQL verb (`select`, `insert`, `update`, `delete`) — that's just SQL-over-JSON-RPC and forces the model to write raw SQL, which is where injection risk and query-correctness problems both live. Prefer task-shaped tools (`find_customer_orders`, `update_inventory_count`) that internally build parameterized queries, *plus* one tightly-scoped `run_read_query` escape hatch if free-form querying is genuinely needed (see reference file for how to make that one safe).
2. **Write tool descriptions for the model, not for a teammate.** Include: what it does, when to use it vs. a sibling tool, what the parameters mean, and what failure looks like. A vague description causes the model to either avoid the tool or misuse it — both show up as bug reports against your server, not against the model.
3. **Return structured, bounded output.** Cap row counts by default (with a documented way to raise the cap), truncate huge text fields, and return an explicit `truncated: true` flag rather than silently dropping data — a model that doesn't know it got a partial result will confidently reason from it.
4. **Validate input server-side even though the model "already validated" it via the schema.** JSON Schema on the tool definition is a hint to the model, not a security boundary — treat every tool call exactly like an untrusted HTTP request, because that's what it is once anything in the model's context could have been influenced by external content (a fetched webpage, a file, another tool's output).
5. **Fail loud in dev, quiet in prod.** Tool errors should tell the *model* enough to self-correct (`"column 'usr_id' does not exist — did you mean 'user_id'?"`) without leaking internals to an untrusted caller in production (connection strings, stack traces, internal hostnames). See `references/postgres-database-servers.md` for the specific pattern.

## 3. Minimal server skeleton (TypeScript + `@modelcontextprotocol/sdk`)

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
    // implementation — see references/postgres-database-servers.md
    // for parameterized information_schema queries + caching
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
```

Two transport choices in practice:
- **stdio** — default for local servers launched by Claude Desktop/Claude Code as a subprocess. Simplest, no auth needed (the parent process owns the child).
- **Streamable HTTP** — needed for remote/hosted servers. Requires you to handle auth yourself (OAuth or a bearer token) — MCP does not give you auth for free.

Don't build an HTTP transport "for flexibility" if the server only needs to run locally — it's the single biggest source of unrequested scope creep in MCP server PRs (adding a whole Express app + auth layer when stdio would've done the job).

## 4. The non-negotiables

Pull these into any server regardless of database or language:

- **Parameterize everything.** No string-built SQL, ever — not even for identifiers the model "shouldn't" be able to influence. Use your driver's parameterized query API for values, and an allow-list (fetched from `information_schema`, never from the model's free text) for identifiers like table/column names.
- **Least-privilege DB role.** The connection the server uses should be a role scoped to exactly what the tools need — read-only role for a read-only server, no `DROP`/`ALTER` grants unless a tool explicitly needs them. This is your real security boundary, not the query-validation code.
- **Pin your install/build scripts.** If your server ships a `postinstall` or setup script, pin versions and checksums — an unpinned install script is a supply-chain hole, and it's an easy thing for a reviewer to miss in an otherwise-legitimate-looking PR.
- **Mask errors in production, keep them rich in dev.** Wrap the boundary between "internal error" and "what the model sees" — a raw driver error can contain schema details, IPs, or partial query text you don't want an agent (possibly relaying to an untrusted user) to see.
- **Invalidate caches, don't just add them.** If you cache schema/introspection data for performance, you need an explicit invalidation path (DDL change, TTL, or manual refresh tool) — a stale schema cache causes the model to write queries against columns that no longer exist, which is a worse failure mode than no cache at all.
- **Keep PRs scoped.** If reviewing or writing a PR described as "security fix," it should not also add a dashboard, delete `CONTRIBUTING.md`, or touch build output (`dist/*.bundle.*`) — flag scope creep explicitly rather than accepting a bundle because parts of it are good.

## Reference files

- `references/postgres-database-servers.md` — schema introspection, connection pooling, safe free-form querying, the read-only-role pattern, cache invalidation strategies. Read this for any Postgres/MySQL/SQL server work.
- `references/security-review-checklist.md` — a checklist for reviewing PRs/contributions to an MCP server, phrased as things to check for, not just things to avoid.
- `references/testing-and-distribution.md` — testing with the MCP Inspector, wiring into Claude Desktop / Claude Code config, packaging and publishing to npm.
- `references/debugging.md` — common "server doesn't show up" / "tool call silently fails" failure modes and how to isolate them.
