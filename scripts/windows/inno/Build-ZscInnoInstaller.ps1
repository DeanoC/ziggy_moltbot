param(
  [Parameter(Mandatory=$true)][string]$Version,
  [string]$OutDir = 'dist/inno-out',
  [string]$SourceBin = 'zig-out/bin',
  [string]$TemplatePath = 'scripts/windows/inno/templates/ZiggyStarClaw.iss',
  [string]$IsccPath = ''
)

$ErrorActionPreference = 'Stop'

function Resolve-InputPath([string]$root, [string]$path) {
  if ([System.IO.Path]::IsPathRooted($path)) {
    return (Resolve-Path $path).ProviderPath
  }
  return (Resolve-Path (Join-Path $root $path)).ProviderPath
}

function Find-Iscc {
  $candidates = @()
  if ($env:ProgramFiles -and $env:ProgramFiles.Trim().Length -gt 0) {
    $candidates += (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
  }
  if (${env:ProgramFiles(x86)} -and ${env:ProgramFiles(x86)}.Trim().Length -gt 0) {
    $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
  }

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
      return $candidate
    }
  }

  $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) { return $cmd.Source }

  $cmd = Get-Command iscc -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) { return $cmd.Source }

  return $null
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).ProviderPath
$template = Resolve-InputPath $root $TemplatePath
$sourceBinPath = Resolve-InputPath $root $SourceBin
$outDirPath = if ([System.IO.Path]::IsPathRooted($OutDir)) {
  $OutDir
} else {
  Join-Path $root $OutDir
}

New-Item -ItemType Directory -Force -Path $outDirPath | Out-Null
$outDirPath = (Resolve-Path $outDirPath).ProviderPath

$iscc = if ($IsccPath -and $IsccPath.Trim().Length -gt 0) {
  $resolved = (Resolve-Path $IsccPath -ErrorAction SilentlyContinue)
  if (-not $resolved) {
    throw "Provided ISCC path does not exist: $IsccPath"
  }
  $resolved.ProviderPath
} else {
  Find-Iscc
}
if (-not $iscc) {
  throw 'ISCC.exe not found. Install Inno Setup 6 and ensure ISCC.exe is on PATH.'
}

$clientExe = Join-Path $sourceBinPath 'ziggystarclaw-client.exe'
$cliExe = Join-Path $sourceBinPath 'ziggystarclaw-cli.exe'
$trayExe = Join-Path $sourceBinPath 'ziggystarclaw-tray.exe'
$iconPath = Join-Path $root 'assets\icons\ziggystarclaw.ico'
$licensePath = Join-Path $root 'LICENSE'
$readmePath = Join-Path $root 'README.md'

if (-not (Test-Path $clientExe)) {
  throw "Missing artifact: $clientExe (run scripts/build-windows.ps1 first)"
}
if (-not (Test-Path $cliExe)) {
  throw "Missing artifact: $cliExe (run scripts/build-windows.ps1 first)"
}
if (-not (Test-Path $trayExe)) {
  Write-Warning "Missing artifact: $trayExe (installer will still build without tray)"
}
if (-not (Test-Path $iconPath)) {
  throw "Missing installer icon: $iconPath"
}
if (-not (Test-Path $licensePath)) {
  throw "Missing LICENSE file: $licensePath"
}
if (-not (Test-Path $readmePath)) {
  throw "Missing README file: $readmePath"
}

$isccArgs = @(
  '/Qp',
  "/DAppVersion=$Version",
  "/DSourceBin=$sourceBinPath",
  "/DRepoRoot=$root",
  "/DOutputDir=$outDirPath",
  "/DSetupIcon=$iconPath",
  "/DLicenseFile=$licensePath",
  "/DReadmeFile=$readmePath",
  $template
)

Write-Host "Building Inno Setup installer..." -ForegroundColor Cyan
& $iscc @isccArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw "ISCC failed with exit code $LASTEXITCODE"
}

$installerPath = Join-Path $outDirPath "ZiggyStarClaw_Setup_${Version}_x64.exe"
if (-not (Test-Path $installerPath)) {
  throw "Expected installer output was not found: $installerPath"
}

Write-Host "Done." -ForegroundColor Green
Write-Host "Output:" -ForegroundColor Green
Write-Host "  $installerPath"
