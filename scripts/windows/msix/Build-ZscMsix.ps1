param(
  [Parameter(Mandatory=$true)][string]$Version,
  [Parameter(Mandatory=$true)][string]$BaseUrl,
  [string]$PackageName = 'DeanoC.ZiggyStarClaw',
  [string]$Publisher = 'CN=DeanoC',
  [string]$DisplayName = 'ZiggyStarClaw',
  [string]$AppId = 'ZiggyStarClaw',
  [Parameter(Mandatory=$true)][string]$PfxPath,
  [Parameter(Mandatory=$true)][string]$CerPath,
  [string]$OutDir = 'dist/msix-out'
)

$ErrorActionPreference = 'Stop'

function Find-Tool($name) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

$makeappx = Find-Tool 'makeappx.exe'
$signtool = Find-Tool 'signtool.exe'
if (-not $makeappx) { throw 'makeappx.exe not found (install Windows SDK and ensure it is on PATH)' }
if (-not $signtool) { throw 'signtool.exe not found (install Windows SDK and ensure it is on PATH)' }

if (-not (Test-Path $PfxPath)) { throw "PFX not found: $PfxPath" }
if (-not (Test-Path $CerPath)) { throw "CER not found: $CerPath" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$bin = Join-Path $root 'zig-out\bin'
$clientExe = Join-Path $bin 'ziggystarclaw-client.exe'
$cliExe = Join-Path $bin 'ziggystarclaw-cli.exe'
$trayExe = Join-Path $bin 'ziggystarclaw-tray.exe'

if (-not (Test-Path $clientExe)) { throw "Missing artifact: $clientExe (run scripts/build-windows.ps1 first)" }

$staging = Join-Path $OutDir 'staging'
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

Copy-Item $clientExe (Join-Path $staging 'ziggystarclaw-client.exe')
if (Test-Path $cliExe) { Copy-Item $cliExe (Join-Path $staging 'ziggystarclaw-cli.exe') }
if (Test-Path $trayExe) {
  Copy-Item $trayExe (Join-Path $staging 'ziggystarclaw-tray.exe')
} else {
  Write-Warning "Missing artifact: $trayExe (tray profile controls will be unavailable)"
}

# Assets
$assetsDir = Join-Path $staging 'Assets'
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

$icon = Join-Path $root 'assets\ZiggyStarClaw.png'
if (Test-Path $icon) {
  Copy-Item $icon (Join-Path $assetsDir 'StoreLogo.png')
  Copy-Item $icon (Join-Path $assetsDir 'Square44x44Logo.png')
  Copy-Item $icon (Join-Path $assetsDir 'Square150x150Logo.png')
} else {
  Write-Warning "Missing icon at $icon; MSIX may fail validation"
}

# Render AppxManifest.xml from template
$tpl = Join-Path $PSScriptRoot 'templates\AppxManifest.xml.template'
if (-not (Test-Path $tpl)) { throw "Missing template: $tpl" }

$manifest = Get-Content -Raw $tpl
$manifest = $manifest.Replace('@@PACKAGE_NAME@@', $PackageName)
$manifest = $manifest.Replace('@@PUBLISHER@@', $Publisher)
$manifest = $manifest.Replace('@@VERSION@@', $Version)
$manifest = $manifest.Replace('@@DISPLAY_NAME@@', $DisplayName)
$manifest = $manifest.Replace('@@APP_ID@@', $AppId)
Set-Content -Path (Join-Path $staging 'AppxManifest.xml') -Value $manifest -Encoding utf8

$msixName = "ZiggyStarClaw_${Version}_x64.msix"
$msixPath = Join-Path $OutDir $msixName

Write-Host "Packing MSIX: $msixPath" -ForegroundColor Cyan
& $makeappx pack /d $staging /p $msixPath | Out-Host

$pwd = Read-Host -AsSecureString "PFX password"
$plain = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd))

Write-Host "Signing MSIX" -ForegroundColor Cyan
& $signtool sign /fd SHA256 /a /f $PfxPath /p $plain $msixPath | Out-Host

# Emit .appinstaller
$appTpl = Join-Path $PSScriptRoot 'templates\ZiggyStarClaw.appinstaller.template'
if (-not (Test-Path $appTpl)) { throw "Missing template: $appTpl" }

$appinstaller = Get-Content -Raw $appTpl
$appinstaller = $appinstaller.Replace('@@PACKAGE_NAME@@', $PackageName)
$appinstaller = $appinstaller.Replace('@@PUBLISHER@@', $Publisher)
$appinstaller = $appinstaller.Replace('@@VERSION@@', $Version)
$appinstaller = $appinstaller.Replace('@@BASE_URL@@', $BaseUrl.TrimEnd('/'))
$appinstaller = $appinstaller.Replace('@@MSIX_NAME@@', $msixName)

$appinstallerPath = Join-Path $OutDir 'ZiggyStarClaw.appinstaller'
Set-Content -Path $appinstallerPath -Value $appinstaller -Encoding utf8

# Copy CER alongside outputs
Copy-Item $CerPath (Join-Path $OutDir 'DeanoC.cer') -Force

# Emit local bootstrap installer helper (installs cert + appinstaller, then launches profile-only mode).
$bootstrapTpl = Join-Path $PSScriptRoot 'templates\Install-ZiggyStarClaw.ps1.template'
if (-not (Test-Path $bootstrapTpl)) { throw "Missing template: $bootstrapTpl" }

$bootstrap = Get-Content -Raw $bootstrapTpl
$bootstrap = $bootstrap.Replace('@@PACKAGE_NAME@@', $PackageName)
$bootstrap = $bootstrap.Replace('@@APP_ID@@', $AppId)
$bootstrapPath = Join-Path $OutDir 'Install-ZiggyStarClaw.ps1'
Set-Content -Path $bootstrapPath -Value $bootstrap -Encoding utf8

Write-Host "Done." -ForegroundColor Green
Write-Host "Outputs:" -ForegroundColor Green
Write-Host "  $msixPath"
Write-Host "  $appinstallerPath"
Write-Host "  $(Join-Path $OutDir 'DeanoC.cer')"
Write-Host "  $bootstrapPath"
