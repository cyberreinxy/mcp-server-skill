# Building MCP Servers

**How to build a Model Context Protocol (MCP) server, the right way.** Protocol fundamentals, tool/resource design, transport choice, testing, packaging, and PR review — everything you need for *any* MCP server, plus a deep, security-first dive into database servers (Postgres especially), because that's where MCP servers most often break in production: SQL injection, connection leaks, stale schema caches, and error messages that leak internals.

This isn't a toy `add(a, b)` tutorial. It's built from real production and PR-review experience, and it's meant to leave you with a server that stays correct once a real AI agent — not just a hand-typed test call — is driving it.

By [cyberreinxy](https://github.com/cyberreinxy). MIT licensed.

## Who this is for

- Building your first MCP server and want to avoid the mistakes that don't show up until real usage (agent-constructed queries, prompt-injected tool calls, connection pool exhaustion under bursty load).
- Building a database-backed server — Postgres, MySQL, SQLite — where query safety and schema drift are the main risks.
- Reviewing a contributor's PR to an existing MCP server and want a checklist for scope creep and security gaps, not just a vibe check.
- Debugging a server that won't show up in a client, or whose tools the model won't call.

## What you'll learn

- **Protocol fundamentals** — tools vs. resources vs. prompts, and when to use each
- **Tool surface design** — task-shaped tools vs. one-tool-per-SQL-verb, writing descriptions the *model* can act on
- **A working server skeleton** — TypeScript + `@modelcontextprotocol/sdk`, stdio vs. Streamable HTTP transport
- **The non-negotiables** — parameterized queries, least-privilege DB roles, pinned install scripts, masked production errors, cache invalidation, scoped PRs
- **Postgres deep dive** — schema introspection queries, a safe free-form `run_query` pattern (read-only role + transaction + statement timeout, not a hand-rolled SQL parser), connection pooling, cache invalidation strategies
- **PR/security review** — a scope-creep-first checklist for reviewing contributions to an MCP server
- **Testing & shipping** — MCP Inspector, Claude Desktop/Code config, npm packaging
- **Debugging** — the actual failure modes: server invisible to the client, tools the model won't call, silent failures under load, stale schema

## What's in this repo

```
.gitattributes                # LF line endings — keeps checksums & signatures stable
skill/
├── building-mcp-servers/     # Claude Skill — full version with reference files
│   ├── SKILL.md
│   └── references/
│       ├── postgres-database-servers.md
│       ├── security-review-checklist.md
│       ├── testing-and-distribution.md
│       └── debugging.md
├── building-mcp-servers.skill    # the same skill, packaged for one-click install in Claude
├── MCP_SERVER_GUIDE.md           # condensed, single-file version for any tool or model
├── install.ps1 / install.sh      # one-command installers for Copilot / VS Code
├── SHA256SUMS / SHA256SUMS.asc   # GPG-signed checksum manifest (verify before running)
├── mcp-server-skill-signing.asc  # GPG public key used to verify the manifest
├── SIGNING.md                    # verification & re-signing instructions
├── validate.ps1 / validate.sh    # local integrity checks (frontmatter, zip, hashes, signature)
└── LICENSE
```

Two formats, same underlying guidance, because there's no single install mechanism that works across every AI tool yet:

| | Format | Where it works |
|---|---|---|
| **Claude Skill** | `building-mcp-servers.skill` (or the unzipped folder) | Claude.ai, Claude Code |
| **Guide file** | `MCP_SERVER_GUIDE.md` | Any tool that reads a plain instructions file — Copilot, Cursor, or pasted into any model |

## Installing as a Copilot / VS Code skill

One command — works on any OS:

**Windows:**
```powershell
irm https://raw.githubusercontent.com/cyberreinxy/mcp-server-skill/main/skill/install.ps1 | iex
```

**macOS / Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/cyberreinxy/mcp-server-skill/main/skill/install.sh | bash
```

This clones only the skill folder (not the whole repo) and copies it to your Copilot skills directory. Run it from inside a project to install per-project, with `-Global` (Windows) to install globally, or with `-Destination <path>` (PowerShell) / a path argument (bash) to choose any install folder.
 The installer also records the installed skill (name + content hash) in a `skills-lock.json` file placed beside the install location.
After install, reload your editor. The skill activates automatically when you ask about MCP servers.

**Verify before you run (recommended).** The one-liners above fetch from `main` and execute immediately — convenient, but they trust HTTPS plus repo ownership with no integrity check. Every distributable file is covered by a GPG-signed checksum manifest (`skill/SIGNING.md`). For higher assurance, download, verify the signature, then run — the steps are in `skill/SIGNING.md` and start with checking the key fingerprint `4332 ECC4 BBDB DA53 44F5 DA83 0EEC 06B4 4785 6DBB`.

**Manual install:** Copy `skill/building-mcp-servers/` into `.github/skills/` (project) or `~/.copilot/skills/` (global).

## Installing the Claude Skill

There's no auto-install from a GitHub repo — download the file, then add it in the Claude app yourself:

1. Download `building-mcp-servers.skill` from this repo (or a release, if you cut one).
2. In Claude.ai or Claude Code, use the skill upload/import option and select the file — or drag it into a chat where Claude offers a **Save skill** button.
3. For Claude Code specifically, you can instead unzip `building-mcp-servers.skill` (it's a standard zip) and place the `building-mcp-servers/` folder directly into your skills directory.

To edit it: unzip the `.skill` file (rename to `.zip` if your OS doesn't recognize the extension, or run `unzip building-mcp-servers.skill`), edit `SKILL.md` / the `references/*.md` files, then re-zip.

## Using the guide file with other tools

No install step — just copy `MCP_SERVER_GUIDE.md` into your project under whichever name your tool expects:

| Tool | Path |
|---|---|
| GitHub Copilot | `.github/copilot-instructions.md` |
| Claude Code | `CLAUDE.md` (repo root) |
| Cursor | `.cursor/rules/mcp-servers.mdc` |
| Anything else | paste directly into the model's context |

## Why two files instead of one

`MCP_SERVER_GUIDE.md` is self-contained — no links to a `references/` folder — because most of the tools above only ever read one file per convention, with no ability to follow a pointer to a second one. The Claude Skill version keeps things split across reference files instead, since Claude only loads each one when it's actually relevant to the task, keeping the always-in-context part small.

If you improve one, port the change to the other — they're meant to stay in sync content-wise even though they're structured differently.

## Local validation

The repo ships a validator that checks the skill stays intact: frontmatter present and correct, the `.skill` zip matches the `building-mcp-servers/` folder, `SHA256SUMS` matches the files, and the GPG signature verifies.

```powershell
# Windows
powershell -File skill/validate.ps1
```

```bash
# macOS / Linux
bash skill/validate.sh
```

The same checks run automatically on every push via GitHub Actions (`.github/workflows/validate.yml`).

## Contributing

PRs welcome. If you're submitting a fix framed as "security" or "hardening," please keep it scoped to that — see the scope-creep checklist in `skill/building-mcp-servers/references/security-review-checklist.md` for what reviewers here will be checking for before merge.

## License

MIT — see `LICENSE`.
