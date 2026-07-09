<#
.SYNOPSIS
    One-time INTERNAL setup. Clone the first bundle, run the first sync (creates `pre-dev`),
    and create the promotion branches develop/staging/main from it (main is the deploy branch).

.EXAMPLE
    .\bootstrap-internal.ps1 -RepoPath C:\src\app-internal -Bundle D:\transfer\app.bundle `
        -Dictionary C:\tools\airgap\dictionary.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$Dictionary
)

# Continue (not Stop): git writes normal progress to stderr, which PS 5.1 can turn into a
# fatal NativeCommandError under Stop (notably `git clone`). We gate on $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Invoke-Git {
    $out = git @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)`n$out" }
    return $out
}

if (Test-Path $RepoPath) { throw "Target already exists: $RepoPath (bootstrap expects a fresh path)." }
if (-not (Test-Path $Bundle))     { throw "Bundle not found: $Bundle" }
if (-not (Test-Path $Dictionary)) { throw "Dictionary not found: $Dictionary" }

Write-Host "[1/3] Cloning bundle -> $RepoPath"
Invoke-Git clone $Bundle $RepoPath | Out-Null

Write-Host "[2/3] First sync (creates pre-dev)..."
& (Join-Path $here 'sync-from-bundle.ps1') -RepoPath $RepoPath -Bundle $Bundle -Dictionary $Dictionary

Write-Host "[3/3] Creating promotion branches from pre-dev..."
# The clone created a raw (untransformed) 'main'; force all promotion branches to pre-dev
# so they start from the transformed content. (pre-dev is HEAD after the sync, so -f is safe.)
foreach ($b in @('develop','staging','main')) {
    Invoke-Git -C $RepoPath branch -f $b pre-dev | Out-Null
    Write-Host "      set $b -> pre-dev"
}
Invoke-Git -C $RepoPath switch pre-dev | Out-Null

Write-Host ""
Write-Host "Bootstrap complete. Branches: pre-dev, develop, staging, main (deploy)."
Write-Host "NEXT STEPS (on your internal git server / clones):"
Write-Host "  1. Enable BRANCH PROTECTION on develop, staging, main (reject direct/force pushes)."
Write-Host "  2. Keep the scripts + dictionary OUTSIDE the repo (e.g. C:\tools\airgap\)."
Write-Host "  3. For the rendered config.json build artifact: add 'config.json' to .git/info/exclude."
