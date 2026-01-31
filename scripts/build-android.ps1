param(
    [string]$JavaHome = "C:\Program Files\Eclipse Adoptium\jdk-17.0.17.10-hotspot",
    [string]$AndroidSdkRoot = "$env:LOCALAPPDATA\Android\Sdk"
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "android-env.ps1") -JavaHome $JavaHome -AndroidSdkRoot $AndroidSdkRoot

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$zig = Join-Path $root ".tools\zig-0.15.2\zig.exe"
if (-not (Test-Path $zig)) {
    throw "Zig toolchain not found at $zig"
}

& $zig build -Dandroid=true
