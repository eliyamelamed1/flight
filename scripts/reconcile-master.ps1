<#
.SYNOPSIS
    Reconcile internal `master` after an emergency hotfix was committed to it (ADR-0014).
    Realigns `master` to `staging` once the external-authored fix has flowed up the pipeline,
    discarding the temporary hotfix commit.

.DESCRIPTION
    Use ONLY after:
      1. you committed an urgent fix to `master` and deployed it,
      2. you re-authored the SAME fix in external master,
      3. a normal sync + promotion carried it up to `staging`.

    This script tags a backup of `master`, then `git reset --hard staging`, so `master` equals
    the promoted pipeline content. It rewrites `master` history -> force-push afterward.

    SAFETY: without -Force it only PRINTS what it would do (dry run) and shows the
    master<->staging diff so you can confirm the fix is present in staging and the only thing
    being dropped is your temporary hotfix.

.EXAMPLE
    # dry run - review the diff first
    .\reconcile-master.ps1 -RepoPath C:\src\app-internal
    # then actually do it
    .\reconcile-master.ps1 -RepoPath C:\src\app-internal -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [string]$MasterBranch  = 'master',
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
foreach ($b in @($MasterBranch,$StagingBranch)) {
    if ((Try-Git rev-parse --verify --quiet "refs/heads/$b") -ne 0) { throw "Branch '$b' not found." }
}

$status = Invoke-Git status --porcelain
if ($status) { throw "Working tree is not clean. Commit/stash before reconciling.`n$status" }

# Commits on master that are NOT on staging = the temporary hotfix(es) about to be dropped.
$onlyOnMaster = Invoke-Git log --oneline "$StagingBranch..$MasterBranch"
# Commits on staging not yet on master = the incoming authoritative content.
$onlyOnStaging = Invoke-Git log --oneline "$MasterBranch..$StagingBranch"

Write-Host "=== Reconcile plan: $MasterBranch := $StagingBranch ==="
Write-Host "`nCommits currently on $MasterBranch but NOT on $StagingBranch (WILL BE DROPPED):"
Write-Host ($(if ($onlyOnMaster) { $onlyOnMaster -join "`n" } else { "  (none)" }))
Write-Host "`nCommits on $StagingBranch not yet on $MasterBranch (incoming):"
Write-Host ($(if ($onlyOnStaging) { $onlyOnStaging -join "`n" } else { "  (none)" }))
Write-Host "`nContent diff ($MasterBranch -> $StagingBranch) summary:"
$stat = Invoke-Git diff --stat "$MasterBranch" "$StagingBranch"
Write-Host ($(if ($stat) { $stat -join "`n" } else { "  (identical - nothing to reconcile)" }))
if ($stat) {
    Write-Host "`nLine-level diff (what MASTER will look like after reconcile = the '+' side):"
    $full = Invoke-Git diff "$MasterBranch" "$StagingBranch"
    Write-Host ($full -join "`n")
    Write-Host "`nEyeball the '+' lines above: that is external's fix, which will become master."
}

if (-not $Force) {
    Write-Host "`n[DRY RUN] Re-run with -Force to: tag a backup of $MasterBranch, then reset it hard to $StagingBranch."
    Write-Host "Confirm above that the fix IS present in $StagingBranch before proceeding."
    return
}

if (-not $Stamp) { $Stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') }
$backupTag = "backup/master-before-reconcile-$Stamp"
Write-Host "`nTagging backup: $backupTag"
Invoke-Git tag $backupTag $MasterBranch | Out-Null

Write-Host "Resetting $MasterBranch to $StagingBranch..."
Invoke-Git switch $MasterBranch | Out-Null
Invoke-Git reset --hard $StagingBranch | Out-Null

Write-Host ""
Write-Host "Done. $MasterBranch now equals $StagingBranch."
Write-Host "Backup of the pre-reconcile master is at tag '$backupTag' (delete once you're happy)."
Write-Host "NOTE: master history was rewritten -> force-push it, then have clones re-sync:"
Write-Host "      git push --force origin $MasterBranch"
