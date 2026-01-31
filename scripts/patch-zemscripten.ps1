param(
    [string]$ZigCacheRoot = "$env:LOCALAPPDATA\\zig\\p"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ZigCacheRoot)) {
    throw "Zig cache root not found at $ZigCacheRoot"
}

$candidates = Get-ChildItem -Directory -Path $ZigCacheRoot -Filter "zemscripten-*"
if (-not $candidates) {
    throw "No zemscripten packages found in $ZigCacheRoot. Run 'zig build --fetch' first."
}

$target = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$buildPath = Join-Path $target.FullName "build.zig"

if (-not (Test-Path $buildPath)) {
    throw "build.zig not found in $($target.FullName)"
}

$content = Get-Content -Raw $buildPath
if ($content -match "emcc\\.bat") {
    Write-Host "zemscripten already patched at $buildPath"
    return
}

$pattern = '"emcc\.py",'
$replacement = @"
        switch (builtin.target.os.tag) {
            .windows => "emcc.bat",
            else => "emcc.py",
        },
"@

if ($content -notmatch $pattern) {
    throw "Could not find emcc.py path in $buildPath"
}

$content = $content -replace $pattern, $replacement
Set-Content -Path $buildPath -Value $content -NoNewline
Write-Host "Patched zemscripten at $buildPath"
