# Testing, Running, and Distributing an MCP Server

## Local testing with MCP Inspector

Before wiring a server into Claude Desktop/Code, test it standalone:

```bash
npx @modelcontextprotocol/inspector node build/index.js
```

This opens a browser UI that lists your tools/resources/prompts and lets you call them directly with hand-built inputs — use it to confirm schemas, error messages, and output shapes before an LLM is in the loop. Check each tool for:
- Does the description alone (no other context) make it obvious when to call it?
- Does a malformed input produce a message a model could self-correct from?
- Does a large result get truncated with a visible flag rather than silently cut off?

## Wiring into Claude Desktop

Add to the Claude Desktop config (`claude_desktop_config.json` — location is OS-specific; check current docs if unsure, this changes):

```json
{
  "mcpServers": {
    "pg-mcp-server": {
      "command": "node",
      "args": ["/absolute/path/to/build/index.js"],
      "env": {
        "DATABASE_URL": "postgres://mcp_readonly:...@host:5432/appdb"
      }
    }
  }
}
```

- Use absolute paths — relative paths resolve against Claude Desktop's working directory, not the project.
- Put credentials in `env`, not hardcoded in source or committed config.
- Restart Claude Desktop fully (not just close the window) after config changes — it doesn't hot-reload MCP server config.

## Wiring into Claude Code

```bash
claude mcp add pg-mcp-server -- node /absolute/path/to/build/index.js
```

Or via project-level `.mcp.json` if the server should be shared with a team via the repo.

## Packaging and publishing (npm)

1. Ensure `bin` is set in `package.json` if it should be runnable via `npx`:
   ```json
   { "bin": { "pg-mcp-server": "./build/index.js" } }
   ```
   and the entry file starts with `#!/usr/bin/env node`.
2. Pin dependency versions in `package.json` (avoid loose `^`/`~` ranges for anything security-sensitive, like the DB driver).
3. If there's a `postinstall`/`prepare` script, make sure it's pinned and doesn't fetch-and-execute — this is the single most common supply-chain hole in published MCP servers, since people copy tutorial `postinstall` snippets without checking what they pull.
4. `npm publish` as normal. Document the required env vars (`DATABASE_URL`, etc.) prominently in the README — an MCP server with an undocumented required env var just looks broken to whoever installs it.

## Versioning and breaking changes

Tool name and input schema changes are breaking changes for anyone with the server already configured — bump the major version and call it out in release notes, the same as you would for a public API, because from the model's perspective the tool signature *is* the API.
