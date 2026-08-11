#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/skill"
FOLDER="$SKILL/building-mcp-servers"
ZIP="$SKILL/building-mcp-servers.skill"
FAIL=0

ok() { echo "ok  : $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

echo "Validating skill in $SKILL"

for f in "$FOLDER/SKILL.md" "$ZIP" "$SKILL/SHA256SUMS" "$SKILL/SHA256SUMS.asc" "$SKILL/mcp-server-skill-signing.asc" "$SKILL/install.ps1" "$SKILL/install.sh"; do
    if [ -f "$f" ]; then ok "exists: $(basename "$f")"; else fail "missing: $f"; fi
done

if grep -q '^name: building-mcp-servers$' "$FOLDER/SKILL.md"; then ok "frontmatter name matches folder"; else fail "frontmatter name missing/mismatch"; fi
if grep -q '^description:' "$FOLDER/SKILL.md"; then ok "frontmatter description present"; else fail "frontmatter description missing"; fi

if command -v unzip >/dev/null 2>&1; then
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    unzip -q "$ZIP" -d "$TMP"
    if diff -rq "$TMP/building-mcp-servers" "$FOLDER" >/dev/null 2>&1; then ok "zip matches folder"; else fail "zip differs from folder"; fi
else
    echo "skip: unzip not found (zip check skipped)"
fi

if command -v sha256sum >/dev/null 2>&1; then
    SUMCMD="sha256sum"
else
    SUMCMD="shasum -a 256"
fi
if (cd "$SKILL" && $SUMCMD -c SHA256SUMS >/dev/null 2>&1); then ok "SHA256SUMS matches all listed files"; else fail "SHA256SUMS mismatch"; fi

if command -v gpg >/dev/null 2>&1; then
    gpg --batch --import "$SKILL/mcp-server-skill-signing.asc" >/dev/null 2>&1
    if gpg --verify "$SKILL/SHA256SUMS.asc" "$SKILL/SHA256SUMS" >/dev/null 2>&1; then ok "GPG signature good"; else fail "GPG signature invalid"; fi
else
    echo "skip: gpg not found (signature check skipped)"
fi

if bash -n "$SKILL/install.sh" 2>/dev/null; then ok "install.sh syntax ok"; else fail "install.sh syntax error"; fi

if command -v pwsh >/dev/null 2>&1; then
    if pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('$SKILL/install.ps1',[ref]\$null,[ref]\$e) | Out-Null; if(\$e.Count -eq 0){exit 0}else{exit 1}" 2>/dev/null; then
        ok "install.ps1 parses"
    else
        fail "install.ps1 parse error"
    fi
else
    echo "skip: pwsh not found (install.ps1 check skipped)"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then echo "VALIDATION PASSED"; exit 0; fi
echo "VALIDATION FAILED"
exit 1
