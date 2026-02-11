param(
  [Parameter(Mandatory=$true)][string]$Version,
  [string]$OutDir = 'dist/inno-out',
  [string]$SourceBin = 'zig-out/bin'
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'inno\Build-ZscInnoInstaller.ps1'

if (-not (Test-Path $script)) {
  throw "Installer build script not found: $script"
}

& $script -Version $Version -OutDir $OutDir -SourceBin $SourceBin
if ($LASTEXITCODE -ne 0) {
  throw "Installer build failed with exit code $LASTEXITCODE"
}
