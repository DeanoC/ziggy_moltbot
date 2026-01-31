param(
    [int]$Retries = 2
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$zig = Join-Path $root '.tools\\zig-0.15.2\\zig.exe'

if (-not (Test-Path $zig)) {
    throw "Zig toolchain not found at $zig"
}

$attempt = 0
$lastExit = 0
do {
    $attempt++
    Write-Host "Windows build attempt $attempt of $($Retries + 1) ..."
    & $zig build -Dtarget=x86_64-windows-gnu
    $lastExit = $LASTEXITCODE
    if ($lastExit -eq 0) { break }
    Start-Sleep -Seconds 2
} while ($attempt -le $Retries)

if ($lastExit -ne 0) {
    throw "Windows build failed after $attempt attempt(s)."
}

$client = Join-Path $root 'zig-out\\bin\\ziggystarclaw-client.exe'
$cli = Join-Path $root 'zig-out\\bin\\ziggystarclaw-cli.exe'
if (-not (Test-Path $client)) { Write-Warning "Missing artifact: $client" }
if (-not (Test-Path $cli)) { Write-Warning "Missing artifact: $cli" }
