param(
    [string]$JavaHome = "C:\Program Files\Eclipse Adoptium\jdk-17.0.17.10-hotspot",
    [string]$AndroidSdkRoot = "$env:LOCALAPPDATA\Android\Sdk"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $JavaHome)) {
    throw "JAVA_HOME not found at $JavaHome"
}
if (-not (Test-Path $AndroidSdkRoot)) {
    throw "ANDROID_SDK_ROOT not found at $AndroidSdkRoot"
}

$env:JAVA_HOME = $JavaHome
$env:ANDROID_SDK_ROOT = $AndroidSdkRoot
$env:ANDROID_HOME = $AndroidSdkRoot
$env:PATH = "$env:JAVA_HOME\bin;$env:ANDROID_SDK_ROOT\platform-tools;$env:PATH"

Write-Host "JAVA_HOME=$env:JAVA_HOME"
Write-Host "ANDROID_SDK_ROOT=$env:ANDROID_SDK_ROOT"
