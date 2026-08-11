param(
    [string]$Repo = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = "Stop"
$script:Failed = $false

function Ok([string]$Msg) { Write-Host ("ok  : {0}" -f $Msg) -ForegroundColor Green }
function Fail([string]$Msg) { Write-Host ("FAIL: {0}" -f $Msg) -ForegroundColor Red; $script:Failed = $true }

$Skill = Join-Path $Repo "skill"
$Folder = Join-Path $Skill "building-mcp-servers"
$Zip = Join-Path $Skill "building-mcp-servers.skill"
$Sums = Join-Path $Skill "SHA256SUMS"
$SumsAsc = Join-Path $Skill "SHA256SUMS.asc"
$PubKey = Join-Path $Skill "mcp-server-skill-signing.asc"
$InstallPs = Join-Path $Skill "install.ps1"
$InstallSh = Join-Path $Skill "install.sh"

Write-Host "Validating skill in $Skill" -ForegroundColor Cyan

foreach ($f in @($Folder, $Zip, $Sums, $SumsAsc, $PubKey, $InstallPs, $InstallSh)) {
    if (Test-Path $f) { Ok "exists: $([System.IO.Path]::GetFileName($f))" } else { Fail "missing: $f" }
}

$md = [System.IO.File]::ReadAllText((Join-Path $Folder "SKILL.md"))
if ($md -match '(?s)^---[ \t]*\r?\n(.*?)\r?\n---') {
    $fm = $Matches[1]
    $name = [regex]::Match($fm, '(?m)^name:[ \t]*(.+?)[ \t]*$').Groups[1].Value
    $desc = [regex]::Match($fm, '(?m)^description:[ \t]*(.+?)[ \t]*$').Groups[1].Value
    if ($name) { Ok ("frontmatter name: {0}" -f $name) } else { Fail "frontmatter missing name" }
    if ($desc) { Ok "frontmatter description present" } else { Fail "frontmatter missing description" }
    if ($name -ceq "building-mcp-servers") { Ok "frontmatter name matches folder" } else { Fail ("frontmatter name '{0}' != folder 'building-mcp-servers'" -f $name) }
} else {
    Fail "SKILL.md has no valid frontmatter"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$arc = [System.IO.Compression.ZipFile]::OpenRead($Zip)
try {
    $entries = @($arc.Entries | Where-Object { -not $_.FullName.EndsWith("/") })
    $zipRel = @{}
    foreach ($e in $entries) {
        $rel = $e.FullName.Substring("building-mcp-servers/".Length)
        $zipRel[$rel] = $true
        $fp = [System.IO.Path]::Combine($Folder, $rel)
        if (-not (Test-Path $fp)) { Fail ("zip entry missing from folder: {0}" -f $rel); continue }
        $sr = New-Object System.IO.StreamReader($e.Open())
        try { $zc = $sr.ReadToEnd() } finally { $sr.Dispose() }
        $fc = [System.IO.File]::ReadAllText($fp)
        if ($zc -cne $fc) { Fail ("zip != folder: {0}" -f $rel) }
    }
    $folderFiles = Get-ChildItem $Folder -Recurse -File
    foreach ($ff in $folderFiles) {
        $rel = $ff.FullName.Substring($Folder.Length + 1) -replace '\\', '/'
        if (-not $zipRel.ContainsKey($rel)) { Fail ("folder file missing from zip: {0}" -f $rel) }
    }
    if ($entries.Count -eq 0) { Fail "zip is empty" }
    if (-not $script:Failed) { Ok ("zip matches folder ({0} files)" -f $entries.Count) }
} finally {
    $arc.Dispose()
}

$mis = 0
foreach ($line in Get-Content $Sums) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split '\s+', 2
    $h = $parts[0].ToLower()
    $rel = $parts[1].Trim()
    $fp = [System.IO.Path]::Combine($Skill, $rel)
    if (-not (Test-Path $fp)) { Fail ("manifest lists missing file: {0}" -f $rel); $mis++; continue }
    $actual = (Get-FileHash $fp -Algorithm SHA256).Hash.ToLower()
    if ($actual -ceq $h) { Ok ("hash ok: {0}" -f $rel) } else { Fail ("hash mismatch: {0}" -f $rel); $mis++ }
}
if ($mis -eq 0) { Ok "SHA256SUMS matches all listed files" }

$gpg = Get-Command gpg -ErrorAction SilentlyContinue
if ($gpg) {
    & $gpg.Source --batch --import $PubKey 2>&1 | Out-Null
    $v = & $gpg.Source --verify $SumsAsc $Sums 2>&1
    if ($LASTEXITCODE -eq 0 -and (($v | Out-String) -match "Good signature")) { Ok "GPG signature good" } else { Fail "GPG signature invalid" }
} else {
    Write-Host "skip: gpg not installed (signature check skipped)" -ForegroundColor Yellow
}

$tokens = $null; $errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($InstallPs, [ref]$tokens, [ref]$errs) | Out-Null
if ($errs.Count -eq 0) { Ok "install.ps1 parses" } else { Fail ("install.ps1 parse errors: {0}" -f $errs.Count) }

$candidates = @()
if ($env:OS -eq "Windows_NT") {
    $candidates += "C:\Program Files\Git\bin\bash.exe", "C:\Program Files\Git\usr\bin\bash.exe"
}
$found = Get-Command bash -ErrorAction SilentlyContinue
if ($found) { $candidates += $found.Source }
$bashPath = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($bashPath) {
    $sh = $InstallSh -replace '\\', '/'
    & $bashPath -n $sh 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "install.sh syntax ok" } else { Fail "install.sh syntax error" }
} else {
    Write-Host "skip: bash not installed (install.sh check skipped)" -ForegroundColor Yellow
}

Write-Host ""
if ($script:Failed) {
    Write-Host "VALIDATION FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "VALIDATION PASSED" -ForegroundColor Green
exit 0
