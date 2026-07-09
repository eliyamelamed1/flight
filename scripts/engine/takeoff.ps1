<#
.SYNOPSIS
    TAKEOFF (external side, internet). The everyday one-command export: reads the
    GitHub repo URL from repos.json (prompting if unset), keeps .\repo as a bare relay
    clone of it, and writes a full bundle to .\transfer\app.bundle. Carry that file
    across the air gap and run landing there.

.DESCRIPTION
    This script lives in engine\; the kit root is one level up (the folder holding
    takeoff.cmd). Folder convention - everything lives in the kit root:
        repo\                 bare relay clone of the URL (created on first run)
        transfer\app.bundle   the produced bundle (the only thing you carry across)
        repos.json            per-kit remote URLs - copy repos.sample.json and fill
                              the "external" key (leave "internal" empty on this side)

    The repo URL resolves in this order: -RepoUrl parameter, then repos.json key
    "external", then an interactive prompt. The URL becomes origin, so the bundle
    always reflects exactly that repo.

    The relay clone is bare with a heads-mirroring fetch refspec, so every run's
    refresh updates branch tips in place - the bundle is always as fresh as the server.

.EXAMPLE
    .\takeoff.cmd
    #   Using external repo URL from repos.json: https://github.com/org/app.git
#>
[CmdletBinding()]
param(
    # Overrides repos.json and the prompt (automation/tests).
    [string]$RepoUrl
)

# Continue (not Stop): git clone/fetch write normal progress to stderr, which PS 5.1
# can turn into a fatal NativeCommandError under Stop. We gate on $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git was not found on PATH. Install Git for Windows (https://git-scm.com/download/win), reopen this terminal, and re-run."
}

# This script lives in engine\ - the kit root (repo\, transfer\, repos.json) is one level up.
$here      = Split-Path -Parent $PSScriptRoot
$repo      = Join-Path $here 'repo'
$bundle    = Join-Path $here 'transfer\app.bundle'
$reposFile = Join-Path $here 'repos.json'

function Invoke-Git {
    $out = git @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)`n$out" }
    return $out
}

if (-not $RepoUrl -and (Test-Path $reposFile)) {
    # Config is a convenience: bad JSON or an empty/missing key just falls through to
    # the prompt, exactly as if the file were not there.
    $cfg = $null
    try   { $cfg = Get-Content $reposFile -Raw | ConvertFrom-Json }
    catch { Write-Warning "repos.json is not valid JSON - ignoring it and prompting instead." }
    if ($cfg -and "$($cfg.external)".Trim()) {
        $RepoUrl = "$($cfg.external)".Trim()
        Write-Host "Using external repo URL from repos.json: $RepoUrl"
    }
}

$prompted = $false
while (-not $RepoUrl) {
    # try/catch: under a non-interactive host Read-Host raises a NON-terminating error,
    # which would spin this loop forever - fail cleanly instead.
    try { $RepoUrl = (Read-Host 'GitHub repo URL (e.g. https://github.com/org/app.git)').Trim(); $prompted = $true }
    catch { throw "Cannot prompt for input (non-interactive host) and no -RepoUrl was given. Re-run with -RepoUrl <url> or fill the ""external"" key in repos.json." }
}
if ($prompted) { Write-Host "Tip: put this URL in repos.json (""external"" key, copy repos.sample.json) to skip this prompt." }

# A repo either has a .git dir (working clone) or is bare (HEAD + objects at top level).
$isRepo = (Test-Path (Join-Path $repo '.git')) -or
          ((Test-Path (Join-Path $repo 'HEAD')) -and (Test-Path (Join-Path $repo 'objects')))

function Set-RelayRefspecs {
    # Idempotent on every run: also heals a first run that died between clone and
    # config, and prunes leftovers when a DIFFERENT URL is typed. With these refspecs
    # in config, the -Refresh fetch force-mirrors branch tips AND tags and --prune
    # drops refs that no longer exist on the (current) remote.
    git -C $repo config --unset-all remote.origin.fetch 2>&1 | Out-Null
    Invoke-Git -C $repo config --add remote.origin.fetch '+refs/heads/*:refs/heads/*' | Out-Null
    Invoke-Git -C $repo config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'   | Out-Null
}

if ($isRepo) {
    Write-Host "repo\ found - pointing origin at $RepoUrl"
    git -C $repo remote get-url origin 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Invoke-Git -C $repo remote set-url origin $RepoUrl | Out-Null }
    else                     { Invoke-Git -C $repo remote add    origin $RepoUrl | Out-Null }
    if (Test-Path (Join-Path $repo '.git')) {
        # Never apply the relay refspecs here: fetching into refs/heads of a working
        # clone would be refused for the checked-out branch.
        Write-Host "note: repo\ is a working clone, so its LOCAL branch tips are what gets bundled"
        Write-Host "      (pull to refresh them - or delete repo\ and re-run takeoff to get a"
        Write-Host "      bare relay clone that refreshes itself)."
    } else {
        Set-RelayRefspecs
    }
} else {
    if (Test-Path $repo) {
        if (@(Get-ChildItem -Force $repo).Count -gt 0) { throw "$repo exists but is not a git repo. Remove it and re-run." }
        Remove-Item $repo -Force   # empty leftover (e.g. from a failed clone)
    }
    Write-Host "First run - creating bare relay clone of $RepoUrl -> repo\"
    Invoke-Git clone --bare $RepoUrl $repo | Out-Null
    Set-RelayRefspecs
}

& (Join-Path $PSScriptRoot 'export-bundle.ps1') -RepoPath $repo -Out $bundle -Refresh

Write-Host ""
Write-Host "Takeoff complete. Carry transfer\app.bundle to the internal kit's transfer\ folder"
Write-Host "and run landing there."
