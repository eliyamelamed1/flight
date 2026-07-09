<#
.SYNOPSIS
    LANDING (internal side, air-gapped). The everyday one-command import: takes the
    bundle folder from .\toUpload\, bootstraps the internal repo on first run
    (clone + first sync + promotion branches) or advances pre-dev on later runs,
    pushes to the internal git server URL from repos.json (prompting if unset), and
    moves the landed bundle folder to .\doneUpload\ once the push succeeded.

.DESCRIPTION
    This script lives in engine\; the kit root is one level up (the folder holding
    '2 - landing.cmd'). Folder convention - everything lives in the kit root:
        toUpload\<name>\      drop the folder produced by takeoff here (exactly one
                              pending folder per run - landing refuses if it finds more)
        doneUpload\<name>\    where the folder is moved after a SUCCESSFUL push - the
                              record of what has already been landed
        repo\internal\        the internal repo (created automatically on first run;
                              repo\external\ belongs to takeoff - one kit can run both)
        dictionary.json       your "find": "replace" transform pairs - the first run
                              writes a starter file and stops so you can fill it in.
                              Every run backs it up to the server's 'airgap-config'
                              branch, and a kit that lost it restores the backup
                              automatically.
        repos.json            per-kit remote URLs - a JSON object with an
                              "internalRepoUrl" key (this side) and/or "externalRepoUrl"
                              (takeoff's side)

    The internal repo URL resolves in this order: -RepoUrl parameter, then repos.json
    key "internalRepoUrl", then an interactive prompt. It becomes origin and receives
    the synced branches:
        first run : pre-dev, develop, staging, main   (seeds the internal server)
        later runs: pre-dev only                      (promotion moves the rest up)

.EXAMPLE
    & '.\2 - landing.cmd'
    #   Using internal repo URL from repos.json: https://git.internal.local/team/app.git
#>
[CmdletBinding()]
param(
    # Overrides repos.json and the prompt (automation/tests).
    [string]$RepoUrl
)

# Continue (not Stop): same rationale as bootstrap-internal.ps1 - git writes progress
# to stderr, which PS 5.1 can turn fatal under Stop. We gate on $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git was not found on PATH. Install Git for Windows (https://git-scm.com/download/win), reopen this terminal, and re-run."
}

# This script lives in engine\ - the kit root (repo\, toUpload\, the dictionary and
# repos.json) is one level up.
$here       = Split-Path -Parent $PSScriptRoot
# Each side keeps its own repo (takeoff: repo\external, landing: repo\internal) so ONE kit
# can run both commands without them fighting over the same folder (ADR-0021).
$repo       = Join-Path $here 'repo\internal'
$toUpload   = Join-Path $here 'toUpload'
$doneUpload = Join-Path $here 'doneUpload'
$dict       = Join-Path $here 'dictionary.json'
$reposFile  = Join-Path $here 'repos.json'

# Older kits kept the internal working clone directly in repo\ (has a .git folder) -
# move it into repo\internal once, transparently. Move only the clone's own entries:
# repo\external may already exist beside it (takeoff ran first) and must stay.
$legacy = Join-Path $here 'repo'
if ((Test-Path (Join-Path $legacy '.git')) -and -not (Test-Path $repo)) {
    New-Item -ItemType Directory -Path $repo | Out-Null
    Get-ChildItem -Force $legacy | Where-Object { $_.Name -notin @('external', 'internal') } |
        Move-Item -Destination $repo
    Write-Host "One-time migration: moved the internal repo from repo\ to repo\internal."
}

function Invoke-Git {
    $out = git @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)`n$out" }
    return $out
}

# Exactly ONE pending bundle folder in toUpload\ per run: none -> nothing to land;
# more than one -> refuse (the operator decides the order) rather than guess.
$pending = @(if (Test-Path $toUpload) { Get-ChildItem $toUpload -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'app.bundle') } })
if ($pending.Count -eq 0) { throw "No bundle folder in $toUpload - copy the toUpload\<name> folder produced by takeoff into this kit's toUpload\ and re-run." }
if ($pending.Count -gt 1) {
    throw ("toUpload\ holds $($pending.Count) bundle folders but landing processes exactly one per run. " +
           "Keep the one to land and move the others out of toUpload\ first:`n  " + (($pending | ForEach-Object { $_.Name }) -join "`n  "))
}
$bundleFolder = $pending[0]
$bundle = Join-Path $bundleFolder.FullName 'app.bundle'
Write-Host "Landing bundle: toUpload\$($bundleFolder.Name)"
function Initialize-Dictionary {
    # Returns $true when dictionary.json is ready to use. If it is missing, write a starter
    # template and return $false so the caller STOPS - the operator fills in their real
    # pairs before the first sync (the placeholder key matches nothing, so even an
    # unedited starter can never inject wrong content).
    if (Test-Path $dict) { return $true }
    $starter = "{`r`n  ""find-this-text"": ""replace-with-this""`r`n}`r`n"
    [System.IO.File]::WriteAllText($dict, $starter, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Created a starter dictionary.json. Open it, replace the placeholder pair with"
    Write-Host "your real ""find"": ""replace"" pairs, then re-run landing."
    return $false
}

function Backup-Dictionary {
    # Version dictionary.json onto the orphan 'airgap-config' branch so the internal
    # server keeps its history (a kit that lost the file restores it automatically).
    # Plumbing only - temp index, no stdin pipes (PS 5.1 BOM-taints piped text):
    # no working-tree churn, no effect on the sync branches.
    git -C $repo fetch origin 2>&1 | Out-Null   # harmless if the server is unreachable
    git -C $repo rev-parse --verify --quiet refs/heads/airgap-config 2>&1 | Out-Null
    $hasLocal = ($LASTEXITCODE -eq 0)
    git -C $repo rev-parse --verify --quiet refs/remotes/origin/airgap-config 2>&1 | Out-Null
    $hasRemote = ($LASTEXITCODE -eq 0)
    if (-not $hasLocal -and $hasRemote) {
        git -C $repo branch airgap-config refs/remotes/origin/airgap-config 2>&1 | Out-Null
        $hasLocal = ($LASTEXITCODE -eq 0)
    } elseif ($hasLocal -and $hasRemote) {
        # Another kit may have backed up meanwhile - fast-forward so our push stays clean.
        git -C $repo merge-base --is-ancestor refs/heads/airgap-config refs/remotes/origin/airgap-config 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { git -C $repo update-ref refs/heads/airgap-config refs/remotes/origin/airgap-config 2>&1 | Out-Null }
    }
    # git chats on stderr (e.g. CRLF advice); fish the SHA out instead of trusting $out.
    function Get-Sha($gitOutput) { @($gitOutput) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9a-f]{40,64}$' } | Select-Object -First 1 }
    $blob = Get-Sha (git -C $repo hash-object -w --no-filters -- $dict 2>&1)
    if (-not $blob) { Write-Warning "dictionary backup skipped: hash-object failed"; return $false }
    $tmpIndex = Join-Path $env:TEMP ('airgap-config-index-' + [System.IO.Path]::GetRandomFileName())
    try {
        $env:GIT_INDEX_FILE = $tmpIndex
        git -C $repo update-index --add --cacheinfo "100644,$blob,dictionary.json" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "dictionary backup skipped: update-index failed"; return $false }
        $tree = Get-Sha (git -C $repo write-tree 2>&1)
    } finally {
        Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue
        Remove-Item $tmpIndex -Force -ErrorAction SilentlyContinue
    }
    if (-not $tree) { Write-Warning "dictionary backup skipped: write-tree failed"; return $false }
    if ($hasLocal -and (Get-Sha (git -C $repo rev-parse 'refs/heads/airgap-config^{tree}' 2>&1)) -eq $tree) { return $true }  # unchanged
    if ($hasLocal) { $commit = Get-Sha (git -C $repo commit-tree $tree -p refs/heads/airgap-config -m 'dictionary update' 2>&1) }
    else           { $commit = Get-Sha (git -C $repo commit-tree $tree -m 'dictionary backup' 2>&1) }
    if (-not $commit) { Write-Warning "dictionary backup skipped: commit-tree failed"; return $false }
    git -C $repo update-ref refs/heads/airgap-config $commit 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

if (-not $RepoUrl -and (Test-Path $reposFile)) {
    # Config is a convenience: bad JSON or an empty/missing key just falls through to
    # the prompt, exactly as if the file were not there.
    $cfg = $null
    try   { $cfg = Get-Content $reposFile -Raw | ConvertFrom-Json }
    catch { Write-Warning "repos.json is not valid JSON - ignoring it and prompting instead." }
    if ($cfg -and "$($cfg.internalRepoUrl)".Trim()) {
        $RepoUrl = "$($cfg.internalRepoUrl)".Trim()
        Write-Host "Using internal repo URL from repos.json: $RepoUrl"
    }
}

$prompted = $false
while (-not $RepoUrl) {
    # try/catch: under a non-interactive host Read-Host raises a NON-terminating error,
    # which would spin this loop forever - fail cleanly instead.
    try { $RepoUrl = (Read-Host 'Internal repo URL (git server this kit pushes to)').Trim(); $prompted = $true }
    catch { throw "Cannot prompt for input (non-interactive host) and no -RepoUrl was given. Re-run with -RepoUrl <url> or fill the ""internalRepoUrl"" key in repos.json." }
}
if ($prompted) { Write-Host "Tip: to skip this prompt, create repos.json next to the launchers: { ""internalRepoUrl"": ""<this URL>"" }" }

$firstRun = -not (Test-Path (Join-Path $repo '.git'))
if ($firstRun) {
    if (Test-Path $repo) {
        if (@(Get-ChildItem -Force $repo).Count -gt 0) { throw "$repo exists but is not a git repo. Remove it and re-run." }
        Remove-Item $repo -Force   # empty leftover; bootstrap expects a fresh path
    }
    # Fresh kit copy against an already-seeded server? Bootstrapping would build
    # unrelated history that can never be pushed - reconnect with a clone instead.
    $remoteHeads = git ls-remote --heads $RepoUrl 2>&1
    if ($LASTEXITCODE -eq 0 -and "$remoteHeads" -match 'refs/heads/pre-dev') {
        throw ("The server at $RepoUrl already has pre-dev, but this kit has no repo\internal (fresh kit copy?). " +
               "Do NOT bootstrap - reconnect first:`n" +
               "    git clone $RepoUrl `"$repo`"`n" +
               "    git -C `"$repo`" switch pre-dev`n" +
               "then re-run landing.")
    }
    if (-not (Initialize-Dictionary)) { return }
    Write-Host "No internal repo yet -> first-run bootstrap (clone + first sync + promotion branches)."
    try {
        & (Join-Path $PSScriptRoot 'bootstrap-internal.ps1') -RepoPath $repo -Bundle $bundle -Dictionary $dict
    } catch {
        # A partial clone would masquerade as steady state on the next run; it is fully
        # reproducible from the bundle, so drop it and let the next run bootstrap again.
        if (Test-Path $repo) { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
} else {
    # Guard against a half-finished bootstrap (e.g. killed mid-run): repo\.git exists
    # but the promotion branches were never created. A repo reconnected from the server
    # (see the fresh-kit message above) is fine - it has origin/develop.
    git -C $repo rev-parse --verify --quiet refs/heads/develop 2>&1 | Out-Null
    $hasLocalDevelop = ($LASTEXITCODE -eq 0)
    git -C $repo rev-parse --verify --quiet refs/remotes/origin/develop 2>&1 | Out-Null
    if (-not $hasLocalDevelop -and $LASTEXITCODE -ne 0) {
        throw "$repo looks half-bootstrapped (no develop branch, locally or on origin). Delete repo\internal and re-run landing."
    }
    if (-not (Test-Path $dict)) {
        # Self-heal: every landing backs the dictionary up to the server's airgap-config
        # branch - restore the last backed-up copy instead of failing.
        git -C $repo fetch origin 2>&1 | Out-Null
        $restored = git -C $repo show refs/remotes/origin/airgap-config:dictionary.json 2>&1
        if ($LASTEXITCODE -eq 0) {
            [System.IO.File]::WriteAllText($dict, (($restored -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "dictionary.json was missing - restored the last backed-up copy from origin/airgap-config."
        }
    }
    if (-not (Initialize-Dictionary)) { return }
    Write-Host "Internal repo found -> steady-state sync (advance pre-dev)."
    & (Join-Path $PSScriptRoot 'sync-from-bundle.ps1') -RepoPath $repo -Bundle $bundle -Dictionary $dict
}

# Point origin at the URL you typed (the bundle clone leaves origin = the bundle file).
git -C $repo remote get-url origin 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Invoke-Git -C $repo remote set-url origin $RepoUrl | Out-Null }
else                     { Invoke-Git -C $repo remote add    origin $RepoUrl | Out-Null }

# @() so the single-branch case stays an array — splatting a bare string would hand
# git the characters one by one.
$branches = @(if ($firstRun) { 'pre-dev','develop','staging','main' } else { 'pre-dev' })
if (Backup-Dictionary) { $branches += 'airgap-config' }
Write-Host ""
Write-Host "Pushing $($branches -join ', ') -> $RepoUrl"
$push = git -C $repo push origin @branches 2>&1
if ($LASTEXITCODE -ne 0) {
    if ("$push" -match '\[rejected\]|non-fast-forward|fetch first|protected branch') {
        Write-Warning "The sync itself SUCCEEDED locally, but the server REJECTED the push - its history has diverged from this kit (e.g. someone pushed to the server's branches directly):`n$($push -join "`n")"
        Write-Warning "Do NOT force-push blindly. Compare first: git -C `"$repo`" fetch origin; git -C `"$repo`" log --oneline pre-dev...origin/pre-dev"
    } else {
        Write-Warning "The sync itself SUCCEEDED locally, but the push failed (server unreachable?):`n$($push -join "`n")"
        Write-Warning "Push manually once the server is reachable: git -C `"$repo`" push origin $($branches -join ' ')"
    }
    Write-Warning "The bundle folder stays in toUpload\$($bundleFolder.Name) - it moves to doneUpload\ only after a successful push (re-run landing once the push issue is resolved)."
} else {
    Write-Host "Pushed."
    # Only now is the bundle fully landed - move its folder to doneUpload\ as the record.
    if (-not (Test-Path $doneUpload)) { New-Item -ItemType Directory -Path $doneUpload | Out-Null }
    $dest = Join-Path $doneUpload $bundleFolder.Name
    $n = 1
    while (Test-Path $dest) { $n++; $dest = Join-Path $doneUpload ('{0}-{1}' -f $bundleFolder.Name, $n) }
    Move-Item $bundleFolder.FullName $dest
    Write-Host "Moved toUpload\$($bundleFolder.Name) -> doneUpload\$(Split-Path -Leaf $dest)."
    if ($firstRun) { Write-Host "Remember: enable BRANCH PROTECTION on develop/staging/main on the server." }
}
