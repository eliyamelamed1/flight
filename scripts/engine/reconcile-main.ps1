<#
.SYNOPSIS
    Reconcile internal `main` after an emergency hotfix was committed to it (ADR-0014).
    Realigns `main` to `staging` once the external-authored fix has flowed up the pipeline,
    discarding the temporary hotfix commit.

.DESCRIPTION
    Use ONLY after:
      1. you committed an urgent fix to `main` and deployed it,
      2. you re-authored the SAME fix in external main,
      3. a normal sync + promotion carried it up to `staging`.

    This script tags a backup of `main`, then `git reset --hard staging`, so `main` equals
    the promoted pipeline content. It rewrites `main` history -> force-push afterward.

    SAFETY: without -Force it only PRINTS what it would do (dry run) and shows the
    main<->staging diff so you can confirm the fix is present in staging and the only thing
    being dropped is your temporary hotfix.

.EXAMPLE
    # From the internal kit (defaults to the kit's repo\internal folder, one level up from engine\):
    .\engine\reconcile-main.ps1           # dry run - review the diff first
    .\engine\reconcile-main.ps1 -Force    # then actually do it

.EXAMPLE
    # Explicit repo path (engine-style invocation):
    .\engine\reconcile-main.ps1 -RepoPath C:\src\app-internal
    .\engine\reconcile-main.ps1 -RepoPath C:\src\app-internal -Force
#>
[CmdletBinding()]
param(
    # Defaults to the kit convention: the kit's repo\internal folder (one level up from engine\).
    [string]$RepoPath,
    [string]$MainBranch    = 'main',
    [string]$StagingBranch = 'staging',
    [string]$Stamp,            # backup-tag timestamp; caller may pass one, else derived
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# This script lives in the kit's engine\ subfolder; the kit's internal repo is one level
# up in repo\internal (with a fallback for pre-ADR-0021 kits that still use repo\).
if (-not $RepoPath) {
    $kitRoot  = Split-Path -Parent $PSScriptRoot
    $RepoPath = Join-Path $kitRoot 'repo\internal'
    if (-not (Test-Path (Join-Path $RepoPath '.git')) -and (Test-Path (Join-Path $kitRoot 'repo\.git'))) {
        $RepoPath = Join-Path $kitRoot 'repo'
    }
}
function Invoke-Git {
    # Local Continue: git writes normal progress to stderr, and with the caller's output
    # captured (2>&1) PS 5.1 would turn that into a fatal NativeCommandError under the
    # script-level Stop. We gate on $LASTEXITCODE instead.
    $ErrorActionPreference = 'Continue'
    $out = git -C $RepoPath @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)`n$out" }
    return $out
}
function Try-Git { $ErrorActionPreference = 'Continue'; git -C $RepoPath @args 2>&1 | Out-Null; return $LASTEXITCODE }

if (-not (Test-Path (Join-Path $RepoPath '.git'))) { throw "Not a git repo: $RepoPath" }
foreach ($b in @($MainBranch,$StagingBranch)) {
    if ((Try-Git rev-parse --verify --quiet "refs/heads/$b") -ne 0) { throw "Branch '$b' not found." }
}

$status = Invoke-Git status --porcelain
if ($status) { throw "Working tree is not clean. Commit/stash before reconciling.`n$status" }

# If this clone tracks a server (the kit's repo\ does - landing points origin at it),
# refuse to reconcile against STALE local copies of main/staging: promotions happen on
# the server, so the dry-run diff must reflect the server's pipeline, not bootstrap-time
# snapshots. Reconcile is destructive - fail loud, tell the user how to refresh.
if ((Try-Git remote get-url origin) -eq 0) {
    Invoke-Git fetch origin | Out-Null
    foreach ($b in @($MainBranch, $StagingBranch)) {
        if ((Try-Git rev-parse --verify --quiet "refs/remotes/origin/$b") -ne 0) { continue }
        $localTip  = "$(Invoke-Git rev-parse "refs/heads/$b")".Trim()
        $originTip = "$(Invoke-Git rev-parse "refs/remotes/origin/$b")".Trim()
        if ($localTip -ne $originTip) {
            throw "Local '$b' does not match origin/$b - a stale copy would make the reconcile diff lie. Refresh it first: git -C `"$RepoPath`" branch -f $b origin/$b   (then re-run)"
        }
    }
}

# Commits on main that are NOT on staging = the temporary hotfix(es) about to be dropped.
$onlyOnMain = Invoke-Git log --oneline "$StagingBranch..$MainBranch"
# Commits on staging not yet on main = the incoming authoritative content.
$onlyOnStaging = Invoke-Git log --oneline "$MainBranch..$StagingBranch"

Write-Host "=== Reconcile plan: $MainBranch := $StagingBranch ==="
Write-Host "`nCommits currently on $MainBranch but NOT on $StagingBranch (WILL BE DROPPED):"
Write-Host ($(if ($onlyOnMain) { $onlyOnMain -join "`n" } else { "  (none)" }))
Write-Host "`nCommits on $StagingBranch not yet on $MainBranch (incoming):"
Write-Host ($(if ($onlyOnStaging) { $onlyOnStaging -join "`n" } else { "  (none)" }))
Write-Host "`nContent diff ($MainBranch -> $StagingBranch) summary:"
$stat = Invoke-Git diff --stat "$MainBranch" "$StagingBranch"
Write-Host ($(if ($stat) { $stat -join "`n" } else { "  (identical - nothing to reconcile)" }))
if ($stat) {
    Write-Host "`nLine-level diff (what MAIN will look like after reconcile = the '+' side):"
    $full = Invoke-Git diff "$MainBranch" "$StagingBranch"
    Write-Host ($full -join "`n")
    Write-Host "`nEyeball the '+' lines above: that is external's fix, which will become main."
}

if (-not $Force) {
    Write-Host "`n[DRY RUN] Re-run with -Force to: tag a backup of $MainBranch, then reset it hard to $StagingBranch."
    Write-Host "Confirm above that the fix IS present in $StagingBranch before proceeding."
    return
}

if (-not $Stamp) { $Stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') }
$backupTag = "backup/main-before-reconcile-$Stamp"
Write-Host "`nTagging backup: $backupTag"
Invoke-Git tag $backupTag $MainBranch | Out-Null

Write-Host "Resetting $MainBranch to $StagingBranch..."
Invoke-Git switch $MainBranch | Out-Null
Invoke-Git reset --hard $StagingBranch | Out-Null

Write-Host ""
Write-Host "Done. $MainBranch now equals $StagingBranch."
Write-Host "Backup of the pre-reconcile main is at tag '$backupTag' (delete once you're happy)."
Write-Host "NOTE: main history was rewritten -> force-push it, then have clones re-sync:"
Write-Host "      git push --force origin $MainBranch"
