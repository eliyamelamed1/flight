<#
.SYNOPSIS
    EXTERNAL side (internet). Produce a full, self-contained git bundle of ALL refs.
    Carry the resulting .bundle file across the air gap to the internal side.

.DESCRIPTION
    Implements ADR-0007: always ship a full `--all` bundle. No incremental base tracking,
    no state, no ack. Every bundle is a complete snapshot, so a lost/duplicated/out-of-order
    bundle is harmless.

    Run this against a repo that already has all the refs you want to mirror. If your
    external repo is a working clone, refresh it from its origin first (see -Refresh).

.EXAMPLE
    .\export-bundle.ps1 -RepoPath C:\src\app -Out D:\bundles\app.bundle -Refresh
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$Out,
    # Fetch all branches/tags from the external origin before bundling.
    [switch]$Refresh
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    # Local SilentlyContinue: git writes normal progress/status to stderr (e.g. bundle
    # verify's "...is okay"), and under Continue PS 5.1 paints every such line on the
    # console as a red NativeCommandError even though it is harmless and captured.
    # SilentlyContinue suppresses that display; the lines still land in $out via 2>&1,
    # and real failures are caught by gating on $LASTEXITCODE.
    $ErrorActionPreference = 'SilentlyContinue'
    $out = git -C $RepoPath @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)`n$out" }
    return $out
}

# Accept a working clone (.git dir) or a bare relay clone (HEAD + objects at top level,
# as created by takeoff.ps1).
$isRepo = (Test-Path (Join-Path $RepoPath '.git')) -or
          ((Test-Path (Join-Path $RepoPath 'HEAD')) -and (Test-Path (Join-Path $RepoPath 'objects')))
if (-not $isRepo) { throw "Not a git repo: $RepoPath" }

if ($Refresh) {
    Write-Host "Refreshing all refs from origin..."
    Invoke-Git fetch --all --tags --prune
    # Make sure local branch tips match origin so --all bundles the freshest state.
    # (Only touches tracking; does not rewrite your working branch content.)
}

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

Write-Host "Creating full bundle -> $Out"
Invoke-Git bundle create $Out --all

Write-Host "Verifying bundle..."
Invoke-Git bundle verify $Out

$size = (Get-Item $Out).Length / 1MB
Write-Host ("Done. Bundle is {0:N1} MB. Carry it to the internal side and run sync-from-bundle.ps1." -f $size)
