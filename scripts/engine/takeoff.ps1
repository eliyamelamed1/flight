<#
.SYNOPSIS
    TAKEOFF (external side, internet). The everyday one-command export: reads the
    GitHub repo URL from repos.json (prompting if unset), keeps .\repo\external as a bare
    relay clone of it, and writes a full bundle into a per-run folder
    .\toUpload\<repo>-<timestamp>\app.bundle. Carry that folder across the air gap
    into the internal kit's toUpload\ and run landing there.

.DESCRIPTION
    This script lives in engine\; the kit root is one level up (the folder holding
    '1 - takeoff.cmd'). Folder convention - everything lives in the kit root:
        repo\external\        bare relay clone of the URL (created on first run;
                              repo\internal\ belongs to landing - one kit can run both)
        toUpload\<name>\      one folder per takeoff run (<repo>-<yyyy-MM-dd_HH-mm-ss>)
                              holding app.bundle - the thing you carry across; landing
                              moves it to its doneUpload\ once the push succeeded
        repos.json            per-kit remote URLs - a JSON object with an
                              "externalRepoUrl" key (this side) and/or "internalRepoUrl"
                              (landing's side)

    The repo URL resolves in this order: -RepoUrl parameter, then repos.json key
    "externalRepoUrl", then an interactive prompt. The URL becomes origin, so the
    bundle always reflects exactly that repo.

    The relay clone is bare with a heads-mirroring fetch refspec, so every run's
    refresh updates branch tips in place - the bundle is always as fresh as the server.

.EXAMPLE
    & '.\1 - takeoff.cmd'
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

# This script lives in engine\ - the kit root (repo\, toUpload\, repos.json) is one level up.
$here      = Split-Path -Parent $PSScriptRoot
# Each side keeps its own repo (takeoff: repo\external, landing: repo\internal) so ONE kit
# can run both commands without them fighting over the same folder (ADR-0021).
$repo      = Join-Path $here 'repo\external'
$reposFile = Join-Path $here 'repos.json'

# Older kits kept the relay clone directly in repo\ (bare: HEAD + objects at top level,
# no .git) - move it into repo\external once, transparently. Move only the relay's own
# entries: repo\internal may already exist beside it (landing ran first) and must stay.
$legacy = Join-Path $here 'repo'
if ((Test-Path (Join-Path $legacy 'HEAD')) -and (Test-Path (Join-Path $legacy 'objects')) -and -not (Test-Path $repo)) {
    New-Item -ItemType Directory -Path $repo | Out-Null
    Get-ChildItem -Force $legacy | Where-Object { $_.Name -notin @('external', 'internal') } |
        Move-Item -Destination $repo
    Write-Host "One-time migration: moved the relay clone from repo\ to repo\external."
}
# The bundle path ($bundle) is derived AFTER the URL is known - its folder is named
# after the repo: toUpload\<repo>-<timestamp>\app.bundle.

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
    if ($cfg -and "$($cfg.externalRepoUrl)".Trim()) {
        $RepoUrl = "$($cfg.externalRepoUrl)".Trim()
        Write-Host "Using external repo URL from repos.json: $RepoUrl"
    }
}

$prompted = $false
while (-not $RepoUrl) {
    # try/catch: under a non-interactive host Read-Host raises a NON-terminating error,
    # which would spin this loop forever - fail cleanly instead.
    try { $RepoUrl = (Read-Host 'GitHub repo URL (e.g. https://github.com/org/app.git)').Trim(); $prompted = $true }
    catch { throw "Cannot prompt for input (non-interactive host) and no -RepoUrl was given. Re-run with -RepoUrl <url> or fill the ""externalRepoUrl"" key in repos.json." }
}
if ($prompted) { Write-Host "Tip: to skip this prompt, create repos.json next to the launchers: { ""externalRepoUrl"": ""<this URL>"" }" }

# Per-run bundle folder, named after the repo: toUpload\<repo>-<yyyy-MM-dd_HH-mm-ss>\.
# GetFileName handles URLs, scp-style remotes and local paths alike.
$repoName = [System.IO.Path]::GetFileName($RepoUrl.TrimEnd('/', '\')) -replace '\.git$', ''
if (-not $repoName) { $repoName = 'repo' }
$runName = '{0}-{1}' -f $repoName, (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
$bundle  = Join-Path $here ('toUpload\{0}\app.bundle' -f $runName)

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
    Write-Host "repo\external found - pointing origin at $RepoUrl"
    git -C $repo remote get-url origin 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Invoke-Git -C $repo remote set-url origin $RepoUrl | Out-Null }
    else                     { Invoke-Git -C $repo remote add    origin $RepoUrl | Out-Null }
    if (Test-Path (Join-Path $repo '.git')) {
        # Never apply the relay refspecs here: fetching into refs/heads of a working
        # clone would be refused for the checked-out branch.
        Write-Host "note: repo\external is a working clone, so its LOCAL branch tips are what gets bundled"
        Write-Host "      (pull to refresh them - or delete repo\external and re-run takeoff to get a"
        Write-Host "      bare relay clone that refreshes itself)."
    } else {
        Set-RelayRefspecs
    }
} else {
    if (Test-Path $repo) {
        if (@(Get-ChildItem -Force $repo).Count -gt 0) { throw "$repo exists but is not a git repo. Remove it and re-run." }
        Remove-Item $repo -Force   # empty leftover (e.g. from a failed clone)
    }
    Write-Host "First run - creating bare relay clone of $RepoUrl -> repo\external"
    Invoke-Git clone --bare $RepoUrl $repo | Out-Null
    Set-RelayRefspecs
}

& (Join-Path $PSScriptRoot 'export-bundle.ps1') -RepoPath $repo -Out $bundle -Refresh

Write-Host ""
Write-Host "Takeoff complete. Carry the toUpload\$runName folder to the internal kit's"
Write-Host "toUpload\ folder and run landing there (it moves to doneUpload\ once landed)."
