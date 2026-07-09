<#
.SYNOPSIS
    Full end-to-end test of the takeoff/landing kit against real git, entirely local
    (path remotes - no network). Run: .\tests\test-kit.ps1
    Covers: config resolution (repos.json / -RepoUrl / prompt fallbacks), the
    toUpload/doneUpload bundle handoff, bootstrap + steady-state sync, the dictionary
    transform + backup/restore, and every refusal path (empty/multiple pending, stale
    bundle, failed push). Exits 0 when all assertions pass.
#>
$ErrorActionPreference = 'Continue'
$kitSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
$root = Join-Path $env:TEMP 'flight-kit-test'
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Force $root | Out-Null
Write-Host "Testing kit at $kitSource (work dir: $root)"

$script:pass = 0; $script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++; Write-Host "PASS: $name" }
    else       { $script:fail++; Write-Host "FAIL: $name" -ForegroundColor Red }
}
function RunCmd([string]$cmdFile) {
    # < nul defeats the launcher's `pause` and makes any unexpected prompt fail fast
    (cmd /c "`"$cmdFile`" < nul" 2>&1 | Out-String)
}
function NewKit([string]$name) {
    $kit = Join-Path $root $name
    robocopy $kitSource $kit /E /XD repo toUpload doneUpload /XF dictionary.json repos.json /NFL /NDL /NJH /NJS | Out-Null
    return $kit
}
function Pending([string]$kit)  { @(Get-ChildItem (Join-Path $kit 'toUpload')   -Directory -ErrorAction SilentlyContinue) }
function Landed([string]$kit)   { @(Get-ChildItem (Join-Path $kit 'doneUpload') -Directory -ErrorAction SilentlyContinue) }

# ---------- setup: fake external GitHub + fake internal server ----------
$extSrc = Join-Path $root 'ext-src'
$extSrv = Join-Path $root 'ext-server.git'
$intSrv = Join-Path $root 'int-server.git'
git init -q --initial-branch=main $extSrc
Set-Content (Join-Path $extSrc 'app.txt') "hello eliya this is the app" -Encoding Ascii
git -C $extSrc add -A; git -C $extSrc -c user.email=t@t -c user.name=t commit -q -m initial
git clone -q --bare $extSrc $extSrv
git init -q --bare $intSrv
$extUrl = $extSrv -replace '\\','/'
$intUrl = $intSrv -replace '\\','/'

$kitExt = NewKit 'kit-ext'
$kitInt = NewKit 'kit-int'
Set-Content (Join-Path $kitExt 'repos.json') ('{ "externalRepoUrl": "' + $extUrl + '", "internalRepoUrl": "" }') -Encoding Ascii
Set-Content (Join-Path $kitInt 'repos.json') ('{ "externalRepoUrl": "", "internalRepoUrl": "' + $intUrl + '" }') -Encoding Ascii

# ---------- T1: takeoff first run (creates relay clone) ----------
$out = RunCmd (Join-Path $kitExt 'takeoff.cmd')
Assert 'T1 takeoff reads repos.json (externalRepoUrl)' ($out -match 'Using external repo URL from repos\.json')
Assert 'T1 first run creates bare relay clone'          ($out -match 'First run - creating bare relay clone')
$p = Pending $kitExt
Assert 'T1 exactly one toUpload run folder'             ($p.Count -eq 1)
Assert 'T1 folder named <repo>-<timestamp>'             ($p[0].Name -match '^ext-server-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$')
Assert 'T1 app.bundle inside the run folder'            (Test-Path (Join-Path $p[0].FullName 'app.bundle'))

# ---------- T2: landing without dictionary -> creates from sample and STOPS ----------
New-Item -ItemType Directory -Force (Join-Path $kitInt 'toUpload') | Out-Null
Copy-Item $p[0].FullName (Join-Path $kitInt 'toUpload') -Recurse
$out = RunCmd (Join-Path $kitInt 'landing.cmd')
Assert 'T2 missing dictionary -> created from sample + stop' ($out -match 'Created dictionary\.json from the sample')
Assert 'T2 nothing pushed yet'                               ((git -C $intSrv branch 2>&1 | Out-String).Trim() -eq '')
Assert 'T2 bundle folder still pending'                      ((Pending $kitInt).Count -eq 1)

# ---------- T3: first real landing -> bootstrap, transform, push, move to doneUpload ----------
Set-Content (Join-Path $kitInt 'dictionary.json') '{ "eliya": "dori" }' -Encoding Ascii
$out = RunCmd (Join-Path $kitInt 'landing.cmd')
Assert 'T3 landing reads repos.json (internalRepoUrl)' ($out -match 'Using internal repo URL from repos\.json')
Assert 'T3 bootstrap path taken'                       ($out -match 'first-run bootstrap')
Assert 'T3 pushed'                                     ($out -match 'Pushed\.')
Assert 'T3 folder moved to doneUpload'                 ($out -match 'Moved toUpload\\.+ -> doneUpload\\')
Assert 'T3 toUpload empty, doneUpload has 1'           (((Pending $kitInt).Count -eq 0) -and ((Landed $kitInt).Count -eq 1))
$branches = (git -C $intSrv for-each-ref --format='%(refname:short)' 2>&1 | Out-String)
Assert 'T3 server has all 5 branches' (('pre-dev','develop','staging','main','airgap-config' | Where-Object { $branches -notmatch $_ }).Count -eq 0)
Assert 'T3 transform applied (eliya->dori)' ((git -C $intSrv show pre-dev:app.txt 2>&1 | Out-String) -match 'hello dori' )

# ---------- T4: steady-state round trip -> only pre-dev advances ----------
Add-Content (Join-Path $extSrc 'app.txt') "second line from eliya"
git -C $extSrc add -A; git -C $extSrc -c user.email=t@t -c user.name=t commit -q -m update
git -C $extSrc push -q $extSrv main
$before = git -C $intSrv for-each-ref --format='%(refname:short)=%(objectname)' 2>&1 | Out-String
RunCmd (Join-Path $kitExt 'takeoff.cmd') | Out-Null
$p2 = Pending $kitExt | Sort-Object Name | Select-Object -Last 1
Copy-Item $p2.FullName (Join-Path $root 'kept-old-bundle') -Recurse   # kept for the T8 stale test
Copy-Item $p2.FullName (Join-Path $kitInt 'toUpload') -Recurse
$out = RunCmd (Join-Path $kitInt 'landing.cmd')
Assert 'T4 steady-state path taken' ($out -match 'steady-state sync')
Assert 'T4 moved to doneUpload'     ($out -match 'Moved toUpload')
$after = git -C $intSrv for-each-ref --format='%(refname:short)=%(objectname)' 2>&1 | Out-String
$changed = @(Compare-Object ($before -split "`n") ($after -split "`n") | Where-Object { $_.InputObject -match '=' } | ForEach-Object { ($_.InputObject -split '=')[0].Trim() } | Sort-Object -Unique)
Assert 'T4 only pre-dev (+config backup ref at most) advanced' (($changed | Where-Object { $_ -notin 'pre-dev','airgap-config' }).Count -eq 0)
Assert 'T4 new content transformed' ((git -C $intSrv show pre-dev:app.txt 2>&1 | Out-String) -match 'second line from dori')

# ---------- T5: empty toUpload -> clear refusal ----------
$out = RunCmd (Join-Path $kitInt 'landing.cmd')
Assert 'T5 empty toUpload refused with guidance' ($out -match 'No bundle folder in .*toUpload')

# ---------- T6: multiple pending -> refuse and list ----------
Add-Content (Join-Path $extSrc 'app.txt') "third line eliya"
git -C $extSrc add -A; git -C $extSrc -c user.email=t@t -c user.name=t commit -q -m third
git -C $extSrc push -q $extSrv main
RunCmd (Join-Path $kitExt 'takeoff.cmd') | Out-Null
Start-Sleep -Seconds 2
RunCmd (Join-Path $kitExt 'takeoff.cmd') | Out-Null
$newTwo = @(Pending $kitExt | Sort-Object Name | Select-Object -Last 2)
$newTwo | ForEach-Object { Copy-Item $_.FullName (Join-Path $kitInt 'toUpload') -Recurse }
$out = RunCmd (Join-Path $kitInt 'landing.cmd')
Assert 'T6 multiple pending refused' ($out -match 'holds 2 bundle folders')
Assert 'T6 nothing moved'            (((Pending $kitInt).Count -eq 2) -and ((Landed $kitInt).Count -eq 2))

# ---------- T7: push failure -> folder stays; retry after fix -> moves ----------
$older = (Pending $kitInt | Sort-Object Name)[0]
Move-Item $older.FullName (Join-Path $root 'parked-stale')   # keep newest only for now
Set-Content (Join-Path $kitInt 'repos.json') '{ "externalRepoUrl": "", "internalRepoUrl": "C:/nonexistent/server.git" }' -Encoding Ascii
$out = RunCmd (Join-Path $kitInt 'landing.cmd')
Assert 'T7 failed push warns'            ($out -match 'push failed')
Assert 'T7 folder stays pending'         ($out -match 'stays in toUpload' -and (Pending $kitInt).Count -eq 1)
Set-Content (Join-Path $kitInt 'repos.json') ('{ "externalRepoUrl": "", "internalRepoUrl": "' + $intUrl + '" }') -Encoding Ascii
$out = RunCmd (Join-Path $kitInt 'landing.cmd')
Assert 'T7 retry lands and moves'        ($out -match 'Pushed\.' -and $out -match 'Moved toUpload' -and (Pending $kitInt).Count -eq 0)

# ---------- T8: genuinely STALE bundle (older than last synced main) refused, stays pending ----------
# parked-stale from T7 was an EQUAL bundle (same tip) - equal is allowed; land it to keep the queue clean
Move-Item (Join-Path $root 'parked-stale') (Join-Path $kitInt 'toUpload\equal-run')
RunCmd (Join-Path $kitInt 'landing.cmd') | Out-Null
# kept-old-bundle is from BEFORE the third commit -> strictly older than the synced main
Move-Item (Join-Path $root 'kept-old-bundle') (Join-Path $kitInt 'toUpload\stale-run')
$out = RunCmd (Join-Path $kitInt 'landing.cmd')
Assert 'T8 stale bundle refused'   ($out -match 'Stale bundle: its main .* is OLDER')
Assert 'T8 stale folder not moved' ((Pending $kitInt).Count -eq 1)
Remove-Item (Join-Path $kitInt 'toUpload\stale-run') -Recurse -Force

# ---------- T9: doneUpload name collision -> -2 suffix ----------
$doneOne = (Landed $kitInt | Sort-Object Name)[-1]
Copy-Item $doneOne.FullName (Join-Path $kitInt ('toUpload\' + $doneOne.Name)) -Recurse   # same name, same (equal, not stale) bundle
$out = RunCmd (Join-Path $kitInt 'landing.cmd')
Assert 'T9 relanding equal bundle succeeds' ($out -match 'Pushed\.')
Assert 'T9 collision got -2 suffix'         ($out -match ('doneUpload\\' + [regex]::Escape($doneOne.Name) + '-2'))

# ---------- T10: -RepoUrl override (no repos.json) ----------
Rename-Item (Join-Path $kitExt 'repos.json') 'repos.json.bak'
$out = (cmd /c "`"$(Join-Path $kitExt 'takeoff.cmd')`" -RepoUrl $extUrl < nul" 2>&1 | Out-String)
Assert 'T10 -RepoUrl works without repos.json' ($out -match 'Takeoff complete' -and $out -notmatch 'Using external repo URL from repos\.json')

# ---------- T11: unedited sample (empty values) -> prompt fallback ----------
Copy-Item (Join-Path $kitExt 'repos.sample.json') (Join-Path $kitExt 'repos.json')
$out = ($extUrl | powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kitExt 'engine\takeoff.ps1') 2>&1 | Out-String)
Assert 'T11 empty keys -> prompt, run succeeds' ($out -match 'Takeoff complete')
Assert 'T11 tip mentions externalRepoUrl key'   ($out -match '"externalRepoUrl" key')

# ---------- T12: invalid JSON -> warning + prompt fallback ----------
Set-Content (Join-Path $kitExt 'repos.json') '{ not json !!' -Encoding Ascii
$out = ($extUrl | powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kitExt 'engine\takeoff.ps1') 2>&1 | Out-String)
Assert 'T12 invalid JSON warns and falls back' ($out -match 'not valid JSON' -and $out -match 'Takeoff complete')

# ---------- T13: OLD keys (external/internal) read as empty -> prompt fallback ----------
Set-Content (Join-Path $kitExt 'repos.json') ('{ "external": "' + $extUrl + '", "internal": "" }') -Encoding Ascii
$out = ($extUrl | powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kitExt 'engine\takeoff.ps1') 2>&1 | Out-String)
Assert 'T13 old keys ignored -> prompt fallback works' ($out -match 'Takeoff complete' -and $out -notmatch 'Using external repo URL from repos\.json')

# ---------- T14: lost dictionary restored from airgap-config backup ----------
Remove-Item (Join-Path $kitInt 'dictionary.json') -Force
# fresh bundle so there is something to land
Add-Content (Join-Path $extSrc 'app.txt') "fourth line eliya"
git -C $extSrc add -A; git -C $extSrc -c user.email=t@t -c user.name=t commit -q -m fourth
git -C $extSrc push -q $extSrv main
Set-Content (Join-Path $kitExt 'repos.json') ('{ "externalRepoUrl": "' + $extUrl + '", "internalRepoUrl": "" }') -Encoding Ascii
RunCmd (Join-Path $kitExt 'takeoff.cmd') | Out-Null
$newest = Pending $kitExt | Sort-Object Name | Select-Object -Last 1
Copy-Item $newest.FullName (Join-Path $kitInt 'toUpload') -Recurse
$out = RunCmd (Join-Path $kitInt 'landing.cmd')
Assert 'T14 dictionary auto-restored from backup' ($out -match 'restored the last backed-up copy')
Assert 'T14 landing completed after restore'      ($out -match 'Pushed\.' -and $out -match 'Moved toUpload')
Assert 'T14 restored pairs applied'               ((git -C $intSrv show pre-dev:app.txt 2>&1 | Out-String) -match 'fourth line dori')

# ---------- T15: reconcile-main default RepoPath resolves to the kit's repo ----------
$out = (powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kitInt 'engine\reconcile-main.ps1') 2>&1 | Out-String)
Assert 'T15 reconcile-main finds kit repo (no path arg)' ($out -notmatch 'not a git repo|cannot find|does not exist' )

Write-Host ""
Write-Host "================  $script:pass passed, $script:fail failed  ================"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
