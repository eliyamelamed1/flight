<#
.SYNOPSIS
    LANDING (internal side, air-gapped). The everyday one-command import: takes the
    bundle from .\transfer\app.bundle, bootstraps the internal repo on first run
    (clone + first sync + promotion branches) or advances pre-dev on later runs,
    then pushes to the internal git server URL you type.

.DESCRIPTION
    Folder convention - everything lives beside this script (the "kit"):
        transfer\app.bundle   drop the bundle from takeoff here
        repo\                 the internal repo (created automatically on first run)
        dictionary.tsv        your from<TAB>to transform pairs - create it ONCE from
                              dictionary.sample.tsv, then edit freely. Every run backs
                              it up to the server's 'airgap-config' branch, and a kit
                              that lost it restores the backup automatically.

    Every run prompts for the internal repo URL (nothing is stored between runs); it
    becomes origin and receives the synced branches:
        first run : pre-dev, develop, staging, main   (seeds the internal server)
        later runs: pre-dev only                      (promotion moves the rest up)

.EXAMPLE
    .\landing.ps1
    #   Internal repo URL: https://git.internal.local/team/app.git
#>
[CmdletBinding()]
param(
    # Skips the interactive prompt (automation/tests); interactive runs always ask.
    [string]$RepoUrl
)

# Continue (not Stop): same rationale as bootstrap-internal.ps1 - git writes progress
# to stderr, which PS 5.1 can turn fatal under Stop. We gate on $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'
$here   = $PSScriptRoot
$repo   = Join-Path $here 'repo'
$bundle = Join-Path $here 'transfer\app.bundle'
$dict   = Join-Path $here 'dictionary.tsv'

function Invoke-Git {
    $out = git @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)`n$out" }
    return $out
}

if (-not (Test-Path $bundle)) { throw "No bundle at $bundle - copy app.bundle from the takeoff kit into transfer\ and re-run." }
$dictHelp = "No dictionary at $dict - copy dictionary.sample.tsv to dictionary.tsv (same folder) and edit in your real from<TAB>to pairs."

function Backup-Dictionary {
    # Version dictionary.tsv onto the orphan 'airgap-config' branch so the internal
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
        git -C $repo update-index --add --cacheinfo "100644,$blob,dictionary.tsv" 2>&1 | Out-Null
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

while (-not $RepoUrl) {
    # try/catch: under a non-interactive host Read-Host raises a NON-terminating error,
    # which would spin this loop forever - fail cleanly instead.
    try { $RepoUrl = (Read-Host 'Internal repo URL (git server this kit pushes to)').Trim() }
    catch { throw "Cannot prompt for input (non-interactive host) and no -RepoUrl was given. Re-run with -RepoUrl <url>." }
}

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
        throw ("The server at $RepoUrl already has pre-dev, but this kit has no repo\ (fresh kit copy?). " +
               "Do NOT bootstrap - reconnect first:`n" +
               "    git clone $RepoUrl `"$repo`"`n" +
               "    git -C `"$repo`" switch pre-dev`n" +
               "then re-run landing.")
    }
    if (-not (Test-Path $dict)) { throw $dictHelp }
    Write-Host "No internal repo yet -> first-run bootstrap (clone + first sync + promotion branches)."
    try {
        & (Join-Path $here 'bootstrap-internal.ps1') -RepoPath $repo -Bundle $bundle -Dictionary $dict
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
        throw "$repo looks half-bootstrapped (no develop branch, locally or on origin). Delete repo\ and re-run landing."
    }
    if (-not (Test-Path $dict)) {
        # Self-heal: every landing backs the dictionary up to the server's airgap-config
        # branch - restore the last backed-up copy instead of failing.
        git -C $repo fetch origin 2>&1 | Out-Null
        $restored = git -C $repo show refs/remotes/origin/airgap-config:dictionary.tsv 2>&1
        if ($LASTEXITCODE -eq 0) {
            [System.IO.File]::WriteAllText($dict, (($restored -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "dictionary.tsv was missing - restored the last backed-up copy from origin/airgap-config."
        }
    }
    if (-not (Test-Path $dict)) { throw $dictHelp }
    Write-Host "Internal repo found -> steady-state sync (advance pre-dev)."
    & (Join-Path $here 'sync-from-bundle.ps1') -RepoPath $repo -Bundle $bundle -Dictionary $dict
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
} else {
    Write-Host "Pushed."
    if ($firstRun) { Write-Host "Remember: enable BRANCH PROTECTION on develop/staging/main on the server." }
}
