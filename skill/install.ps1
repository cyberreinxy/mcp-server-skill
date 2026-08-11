param(
    [switch]$Global,
    [string]$Destination
)

$ErrorActionPreference = "Stop"
$Repo = "https://github.com/cyberreinxy/mcp-server-skill.git"

Write-Host "Building MCP Servers — Skill Install" -ForegroundColor Cyan
Write-Host ""

if ($Destination) {
    $SkillsDir = $Destination
} elseif ($Global) {
    $SkillsDir = "$env:USERPROFILE\.copilot\skills"
} elseif (Test-Path ".git") {
    $SkillsDir = "$(Get-Location)\.github\skills"
} else {
    $SkillsDir = "$env:USERPROFILE\.copilot\skills"
}

New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null

$TempDir = New-Item -ItemType Directory -Force -Path "$env:TEMP\mcp-skill-$(Get-Random)" | Select-Object -ExpandProperty FullName
try {
    Write-Host "Fetching from $Repo ..."
    git clone --depth 1 --filter=blob:none --sparse $Repo $TempDir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE). Check network access and that the repo is public." }

    git -C $TempDir sparse-checkout set skill/building-mcp-servers
    if ($LASTEXITCODE -ne 0) { throw "Failed to set sparse-checkout path 'skill/building-mcp-servers'." }

    $src = "$TempDir\skill\building-mcp-servers"
    $dst = "$SkillsDir\building-mcp-servers"

    if (Test-Path $src) {
        if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
        Copy-Item -Recurse $src $dst
        $LockFile = [System.IO.Path]::GetFullPath((Join-Path $SkillsDir "..\skills-lock.json"))
        $Hash = (Get-FileHash "$dst\SKILL.md" -Algorithm SHA256).Hash.ToLower()
        $Entry = @{
            source       = "cyberreinxy/mcp-server-skill"
            sourceType   = "github"
            skillPath    = "skill/building-mcp-servers/SKILL.md"
            computedHash = $Hash
        }
        if (Test-Path $LockFile) {
            $Lock = Get-Content $LockFile -Raw | ConvertFrom-Json
            $Lock.skills | Add-Member -Name "building-mcp-servers" -Value $Entry -MemberType NoteProperty -Force
            $Lock | ConvertTo-Json -Depth 4 | Set-Content $LockFile
        } else {
            @{
                version = 1
                skills  = @{ "building-mcp-servers" = $Entry }
            } | ConvertTo-Json -Depth 4 | Set-Content $LockFile
        }
        Write-Host "  Updated: $LockFile"
        Write-Host "  Installed: building-mcp-servers"
        Write-Host ""
        Write-Host "Installed to: $SkillsDir"
        Write-Host "Reload your editor to activate."
    } else {
        throw "Skill folder not found after clone."
    }
} finally {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
