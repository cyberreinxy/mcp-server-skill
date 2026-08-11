# Signing & Verification

The distributable artifacts in this repo are authenticated with a single GPG-signed
checksum manifest, so you can verify they are genuine and unmodified before running
them. A signature is only as good as the key you trust, so confirm the fingerprint
below out-of-band (published here, in the README, and on the repo owner's profile).

## Key

- **Fingerprint:** `4332 ECC4 BBDB DA53 44F5 DA83 0EEC 06B4 4785 6DBB`
- **UID:** `mcp-server-skill Release Signing <cyberreinxy@users.noreply.github.com>`
- **Type / expiry:** RSA 4096, sign-only, expires 2028-08-10
- **Public key:** `skill/mcp-server-skill-signing.asc`

## Files

- `skill/SHA256SUMS` — SHA-256 of every distributable artifact, relative to `skill/`
- `skill/SHA256SUMS.asc` — the GPG signature over `SHA256SUMS`
- `skill/mcp-server-skill-signing.asc` — the public key used to verify

## Verify before you run

### Windows (PowerShell)

```powershell
# 1. Download the manifest, its signature, and the public key
Invoke-WebRequest "https://raw.githubusercontent.com/cyberreinxy/mcp-server-skill/main/skill/SHA256SUMS" -OutFile SHA256SUMS
Invoke-WebRequest "https://raw.githubusercontent.com/cyberreinxy/mcp-server-skill/main/skill/SHA256SUMS.asc" -OutFile SHA256SUMS.asc
Invoke-WebRequest "https://raw.githubusercontent.com/cyberreinxy/mcp-server-skill/main/skill/mcp-server-skill-signing.asc" -OutFile mcp-server-skill-signing.asc

# 2. Import the key once, then confirm the fingerprint
gpg --import mcp-server-skill-signing.asc
gpg --fingerprint 4332ECC4BBDBDA5344F5DA830EEC06B447856DBB

# 3. Verify the manifest — must report "Good signature"
gpg --verify SHA256SUMS.asc SHA256SUMS

# 4. Download the artifacts, then confirm their hashes match the manifest
Get-FileHash install.ps1 -Algorithm SHA256   # compare against SHA256SUMS
```

### macOS / Linux (bash)

```bash
# 1. Download the manifest, its signature, and the public key
curl -fsSL -O https://raw.githubusercontent.com/cyberreinxy/mcp-server-skill/main/skill/SHA256SUMS
curl -fsSL -O https://raw.githubusercontent.com/cyberreinxy/mcp-server-skill/main/skill/SHA256SUMS.asc
curl -fsSL -O https://raw.githubusercontent.com/cyberreinxy/mcp-server-skill/main/skill/mcp-server-skill-signing.asc

# 2. Import the key once, then confirm the fingerprint
gpg --import mcp-server-skill-signing.asc
gpg --fingerprint 4332ECC4BBDBDA5344F5DA830EEC06B447856DBB

# 3. Verify the manifest — must report "Good signature"
gpg --verify SHA256SUMS.asc SHA256SUMS

# 4. Download the artifacts into this folder, then verify every hash:
sha256sum -c SHA256SUMS   # macOS: shasum -a 256 -c SHA256SUMS
```

## Re-signing after changes

Any edit to a signed artifact changes its hash, so update the manifest and re-sign it:

```bash
# from the skill/ directory
sha256sum install.ps1 install.sh building-mcp-servers.skill MCP_SERVER_GUIDE.md building-mcp-servers/SKILL.md > SHA256SUMS
gpg --armor --detach-sign --local-user 4332ECC4BBDBDA5344F5DA830EEC06B447856DBB SHA256SUMS
```

## Security notes

- The signing key was created with **no passphrase** (`%no-protection`) so it can be
  used in scripts/CI. Keep the secret key on disk protected, and back up the
  revocation certificate generated at key creation time (GnuPG `openpgp-revocs.d`).
- Text files are normalized to LF (see `.gitattributes`) so hashes are stable across
  platforms and match the bytes GitHub serves.
- The one-line `irm | iex` / `curl | bash` install path bypasses verification by
  design. Use the download → verify → run flow above for anything sensitive.
