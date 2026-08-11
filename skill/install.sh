#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/cyberreinxy/mcp-server-skill.git"

echo "Building MCP Servers — Skill Install"
echo ""

if [ -n "${1:-}" ]; then
    SKILLS_DIR="$1"
elif [ -n "${CODESPACES:-}" ] || [ -n "${GITPOD_WORKSPACE_ID:-}" ] || [ ! -d ".git" ]; then
    SKILLS_DIR="$HOME/.copilot/skills"
else
    SKILLS_DIR="$(pwd)/.github/skills"
fi

mkdir -p "$SKILLS_DIR"

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "Fetching from $REPO ..."
git clone --depth 1 --filter=blob:none --sparse "$REPO" "$TEMP_DIR"
git -C "$TEMP_DIR" sparse-checkout set skill/building-mcp-servers

SRC="$TEMP_DIR/skill/building-mcp-servers"
DST="$SKILLS_DIR/building-mcp-servers"

if [ -d "$SRC" ]; then
    rm -rf "$DST" 2>/dev/null || true
    cp -r "$SRC" "$DST"
    if command -v sha256sum >/dev/null 2>&1; then
        HASH=$(sha256sum "$DST/SKILL.md" | awk '{print $1}')
    else
        HASH=$(shasum -a 256 "$DST/SKILL.md" | awk '{print $1}')
    fi
    LOCK_FILE="${SKILLS_DIR%/*}/skills-lock.json"
    if [ -f "$LOCK_FILE" ] && command -v jq >/dev/null 2>&1; then
        jq --arg name "building-mcp-servers" \
           --arg source "cyberreinxy/mcp-server-skill" \
           --arg sourceType "github" \
           --arg skillPath "skill/building-mcp-servers/SKILL.md" \
           --arg hash "$HASH" \
           '.skills[$name] = {source: $source, sourceType: $sourceType, skillPath: $skillPath, computedHash: $hash}' \
           "$LOCK_FILE" > "${LOCK_FILE}.tmp" && mv "${LOCK_FILE}.tmp" "$LOCK_FILE"
        echo "  Updated: $LOCK_FILE"
    elif [ -f "$LOCK_FILE" ]; then
        echo "  Warning: jq not found, skills-lock.json not updated: $LOCK_FILE"
    else
        cat > "$LOCK_FILE" <<EOF
{
  "version": 1,
  "skills": {
    "building-mcp-servers": {
      "source": "cyberreinxy/mcp-server-skill",
      "sourceType": "github",
      "skillPath": "skill/building-mcp-servers/SKILL.md",
      "computedHash": "$HASH"
    }
  }
}
EOF
        echo "  Updated: $LOCK_FILE"
    fi
    echo "  Installed: building-mcp-servers"
    echo ""
    echo "Installed to: $SKILLS_DIR"
    echo "Reload your editor to activate."
else
    echo "  Failed to find skill in repo. Check that the repo is public."
fi
