param(
  [string]$Version = '',
  [string]$OutDir = 'dist/inno-out',
  [string]$SourceBin = 'zig-out/bin'
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'inno\Build-ZscInnoInstaller.ps1'

function Resolve-VersionFromBuildZon([string]$repoRoot) {
  $buildZon = Join-Path $repoRoot 'build.zig.zon'
  if (-not (Test-Path $buildZon)) {
    throw "Version not provided and build file was not found: $buildZon"
  }

  $text = Get-Content -Raw $buildZon
  $match = [regex]::Match($text, '\.version\s*=\s*"([^"]+)"')
  if (-not $match.Success) {
    throw "Failed to parse .version from $buildZon"
  }
  return $match.Groups[1].Value
}

if (-not (Test-Path $script)) {
  throw "Installer build script not found: $script"
}

if (-not $Version -or $Version.Trim().Length -eq 0) {
  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
  $Version = Resolve-VersionFromBuildZon $repoRoot
}

& $script -Version $Version -OutDir $OutDir -SourceBin $SourceBin
if ($LASTEXITCODE -ne 0) {
  throw "Installer build failed with exit code $LASTEXITCODE"
}
