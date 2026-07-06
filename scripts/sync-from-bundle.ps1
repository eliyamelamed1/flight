<#
.SYNOPSIS
    INTERNAL side (air-gapped). Bring external master into internal `pre-dev` ONLY, applying
    the dictionary transform. Forward-advancing: adds ONE commit to pre-dev each sync.
    Does NOT touch develop/staging/master (ADR-0013).

.DESCRIPTION
    Your promotion pipeline is:  pre-dev -> develop -> staging -> master.
    This script only feeds the bottom of that pipeline. It never rewrites pre-dev's history
    (so merges up the pipeline stay clean) and never touches the promotion branches.

    Each sync:
      1. verify bundle
      2. fetch all refs into refs/upstream/* (mirror; --prune)
      3. switch to pre-dev (create it from external master on first run)
      4. set pre-dev's tree to external master's content (read-tree; keeps pre-dev HEAD)
      5. apply dictionary transform (text files only; skip binaries; UTF-8 no BOM)
      6. commit -> one new forward commit on pre-dev (skip if nothing changed)

    Then promote pre-dev up the pipeline with your normal process (PRs/CI gates).

    Self-healing: an accidental commit to pre-dev is content-overwritten next sync (external
    is re-applied), with no conflict. Accidental commits to develop/staging/master are NOT
    handled here - protect those with branch protection on your internal server.

.EXAMPLE
    .\sync-from-bundle.ps1 -RepoPath C:\src\app-internal -Bundle D:\transfer\app.bundle `
        -Dictionary C:\tools\airgap\dictionary.tsv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$Dictionary,
    [string]$PreDevBranch    = 'pre-dev',
    [string]$UpstreamMainRef = 'refs/upstream/heads/master',
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    $out = git -C $RepoPath @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)`n$out" }
    return $out
}
function Try-Git { git -C $RepoPath @args 2>&1 | Out-Null; return $LASTEXITCODE }

if (-not (Test-Path (Join-Path $RepoPath '.git'))) { throw "Not a git repo: $RepoPath" }
if (-not (Test-Path $Bundle))                      { throw "Bundle not found: $Bundle" }
if (-not (Test-Path $Dictionary))                  { throw "Dictionary not found: $Dictionary" }

$status = Invoke-Git status --porcelain
if ($status) { throw "Working tree is not clean. Commit/stash before syncing.`n$status" }

# --- Load dictionary (from<TAB>to), longest 'from' first ---
$pairs = @()
foreach ($line in (Get-Content $Dictionary)) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $i = $line.IndexOf("`t")
    if ($i -lt 1) { throw "Malformed dictionary line (need <from>TAB<to>): $line" }
    $pairs += [pscustomobject]@{ From = $line.Substring(0,$i); To = $line.Substring($i+1) }
}
if (-not $pairs) { throw "Dictionary is empty: $Dictionary" }
$pairs = $pairs | Sort-Object { $_.From.Length } -Descending

Write-Host "[1/6] Verifying bundle..."
Invoke-Git bundle verify $Bundle | Out-Null

Write-Host "[2/6] Fetching all refs into refs/upstream/* (with prune)..."
Invoke-Git fetch --prune $Bundle `
    'refs/heads/*:refs/upstream/heads/*' `
    '+refs/tags/*:refs/upstream/tags/*' | Out-Null

if ((Try-Git rev-parse --verify --quiet $UpstreamMainRef) -ne 0) {
    throw "Bundle has no $UpstreamMainRef - is the external default branch really 'master'? Adjust -UpstreamMainRef."
}

Write-Host "[3/6] Switching to $PreDevBranch (forward-advancing; NOT rewriting history)..."
if ((Try-Git rev-parse --verify --quiet "refs/heads/$PreDevBranch") -eq 0) {
    Invoke-Git switch $PreDevBranch | Out-Null
} else {
    Write-Host "      $PreDevBranch does not exist - creating it from external master."
    Invoke-Git switch -c $PreDevBranch $UpstreamMainRef | Out-Null
}

Write-Host "[4/6] Setting pre-dev tree to external master's content..."
# Updates index + working tree to external master, but leaves HEAD on pre-dev,
# so the next commit is a normal forward commit (parent = current pre-dev tip).
Invoke-Git read-tree -u --reset $UpstreamMainRef | Out-Null

Write-Host "[5/6] Applying dictionary transform..."
$counts = @{}; foreach ($p in $pairs) { $counts[$p.From] = 0 }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$files = Get-ChildItem -Path $RepoPath -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -eq 0) { continue }
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { continue }   # binary -> skip
    $text = $utf8NoBom.GetString($bytes); $orig = $text
    foreach ($p in $pairs) {
        if ($p.From -and $text.Contains($p.From)) {
            $counts[$p.From] += ([regex]::Matches($text, [regex]::Escape($p.From))).Count
            $text = $text.Replace($p.From, $p.To)
        }
    }
    if ($text -ne $orig) { [System.IO.File]::WriteAllText($f.FullName, $text, $utf8NoBom) }
}
foreach ($p in $pairs) {
    $n = $counts[$p.From]
    Write-Host ("      '{0}' -> '{1}': {2} replacement(s)" -f $p.From, $p.To, $n)
    if ($n -eq 0) {
        $msg = "Dictionary key '$($p.From)' matched 0 files - upstream may have renamed/removed it."
        if ($Strict) { throw $msg } else { Write-Warning $msg }
    }
}

Write-Host "[6/6] Committing forward commit on $PreDevBranch..."
Invoke-Git add -A | Out-Null
if (Invoke-Git status --porcelain) {
    Invoke-Git commit -m "sync: external master + dictionary transform" | Out-Null
    Write-Host "      committed."
} else {
    Write-Host "      no changes since last sync - nothing to commit."
}

Write-Host ""
Write-Host "Upstream master : $((Invoke-Git rev-parse --short $UpstreamMainRef).Trim())"
Write-Host "$PreDevBranch   : $((Invoke-Git rev-parse --short $PreDevBranch).Trim())"
Write-Host "Next: promote $PreDevBranch -> develop -> staging -> master via your normal process."
