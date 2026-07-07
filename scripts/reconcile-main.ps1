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
    # dry run - review the diff first
    .\reconcile-main.ps1 -RepoPath C:\src\app-internal
    # then actually do it
    .\reconcile-main.ps1 -RepoPath C:\src\app-internal -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [string]$MainBranch    = 'main',
    [string]$StagingBranch = 'staging',
    [string]$Stamp,            # backup-tag timestamp; caller may pass one, else derived
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
function Invoke-Git {
    $out = git -C $RepoPath @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)`n$out" }
    return $out
}
function Try-Git { git -C $RepoPath @args 2>&1 | Out-Null; return $LASTEXITCODE }

if (-not (Test-Path (Join-Path $RepoPath '.git'))) { throw "Not a git repo: $RepoPath" }
foreach ($b in @($MainBranch,$StagingBranch)) {
    if ((Try-Git rev-parse --verify --quiet "refs/heads/$b") -ne 0) { throw "Branch '$b' not found." }
}

$status = Invoke-Git status --porcelain
if ($status) { throw "Working tree is not clean. Commit/stash before reconciling.`n$status" }

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
