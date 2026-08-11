# Debugging MCP Servers

Common failure modes, roughly in order of how often they actually occur.

## "The server doesn't show up in Claude Desktop / Claude Code at all"

- Config file has a JSON syntax error — validate it (trailing commas are the usual culprit).
- Path in `command`/`args` is relative, not absolute.
- The server crashes on startup before completing the MCP handshake — run it directly (`node build/index.js`) and watch stderr; a crash there won't surface in the Claude Desktop UI, only in its logs.
- Node version mismatch — check the client's bundled Node vs. the syntax/APIs your build target.

## "Tools don't appear, or the model never calls them"

- Confirm `server.connect(transport)` actually completed — a server that hangs before this point looks "present but empty" to the client.
- Vague tool descriptions: if the model has a very similar built-in capability or another tool with overlapping description, it may just not pick yours. Sharpen the "when to use this vs. X" language.
- Input schema using a JSON Schema feature the client doesn't support (some complex `oneOf`/`anyOf` nesting) — simplify and retest via MCP Inspector first.

## "Tool calls fail silently or return empty results"

- Check you're returning the correct MCP content shape — a tool handler that returns a bare object instead of `{ content: [...] }` will often fail silently rather than throwing.
- Pool exhaustion: if calls succeed individually but fail/hang under a burst of calls in one turn, check `pool.max` and confirm clients are released in a `finally`.
- Read-only role rejecting an unexpected write: if a "read" tool internally does something like an `UPDATE` for logging/auditing, it'll fail against a `mcp_readonly` role — this is usually the role working correctly, not a bug; give logging its own path/role instead of loosening the main grant.

## "Works in MCP Inspector, breaks with the actual model in the loop"

- The model is constructing inputs Inspector never exercised (edge-case strings, unicode, very long params) — check your validation handles those, not just the happy path you tested by hand.
- The model is chaining tool calls in an order you didn't anticipate (e.g., calling `run_query` before `describe_table`) — make sure error messages from the unprepared path guide it back (see the `postgres-database-servers.md` error-handling pattern), rather than assuming a fixed call order.

## "Schema/data looks stale"

Almost always a caching issue — see the Cache Invalidation section in `references/postgres-database-servers.md`. Add (or use) a manual refresh tool as the fastest diagnostic: if refreshing fixes it, you've confirmed it's a cache-invalidation gap, not a query bug.
