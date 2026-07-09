<#
.SYNOPSIS
    INTERNAL CI/CD build stage. Render the runtime config file from a source-owned template
    plus internal-only values. Output is a BUILD ARTIFACT and must never be committed.

.DESCRIPTION
    Implements ADR-0008. The template ships in the application source (owned by upstream).
    The values file is internal-only (in .internal-paths, preserved across syncs).
    This step substitutes ${VAR} / $VAR placeholders in the template with values, producing
    the runtime config. No application source is modified.

    Values file format: KEY=VALUE lines (# comments and blank lines ignored).

.EXAMPLE
    .\render-config.ps1 -Template config.template.json -Values deploy\internal.values.env -Out config.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Template,
    [Parameter(Mandatory)][string]$Values,
    [Parameter(Mandatory)][string]$Out
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Template)) { throw "Template not found: $Template" }
if (-not (Test-Path $Values))   { throw "Values file not found: $Values" }

# Parse KEY=VALUE pairs.
$map = @{}
Get-Content $Values | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    $i = $line.IndexOf('=')
    if ($i -lt 1) { throw "Malformed line in ${Values}: $line" }
    $map[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
}

$content = Get-Content $Template -Raw

# Substitute ${VAR} then $VAR (longest form first to avoid partial matches).
foreach ($k in ($map.Keys | Sort-Object Length -Descending)) {
    $content = $content.Replace('${' + $k + '}', $map[$k]).Replace('$' + $k, $map[$k])
}

# Fail loudly on any unresolved ${...} placeholder — prevents shipping a half-rendered config.
$unresolved = [regex]::Matches($content, '\$\{[A-Za-z_][A-Za-z0-9_]*\}') |
    ForEach-Object { $_.Value } | Sort-Object -Unique
if ($unresolved) { throw "Unresolved placeholders (missing values): $($unresolved -join ', ')" }

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# UTF-8 without BOM so downstream JSON/env parsers don't choke.
[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $outDir).Path + '\' + (Split-Path -Leaf $Out), $content, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Rendered $Out from $Template + $Values ($($map.Count) values)."
Write-Host "Reminder: $Out is a build artifact - add it to .gitignore, never commit it."
