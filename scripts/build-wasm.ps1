param(
    [string]$BashPath = "C:\Program Files\Git\bin\bash.exe"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BashPath)) {
    throw "Git Bash not found at $BashPath"
}

. (Join-Path $PSScriptRoot "patch-zemscripten.ps1")

& $BashPath -lc "source ./scripts/emsdk-env.sh && ./.tools/zig-0.15.2/zig.exe build -Dwasm=true"
