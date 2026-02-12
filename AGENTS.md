# ZiggyStarClaw - Build & Run

This repo uses the pinned Zig toolchain at `./.tools/zig-0.15.2/zig`.

Always run all platform builds before final responses:
- Native: `./.tools/zig-0.15.2/zig build`
- Windows: `./.tools/zig-0.15.2/zig build -Dtarget=x86_64-windows-gnu`
- WASM: `source ./scripts/emsdk-env.sh && ./.tools/zig-0.15.2/zig build -Dwasm=true`
- Android: `./.tools/zig-0.15.2/zig build -Dandroid=true`

When handling PRs, always check review subcomments (inline threads), not just top-level reviews.

## Release Instructions

For releases, always follow this order:
- Increment the least significant version number only: `X.Y.Z -> X.Y.(Z+1)` (patch bump).
- Update `README.md` for the new release version/highlights.
- Rebuild all platforms after the version bump:
  ```bash
  ./.tools/zig-0.15.2/zig build
  ./.tools/zig-0.15.2/zig build -Dtarget=x86_64-windows-gnu
  source ./scripts/emsdk-env.sh && ./.tools/zig-0.15.2/zig build -Dwasm=true
  ./.tools/zig-0.15.2/zig build -Dandroid=true
  ```
- After platform builds complete, check whether the host is Windows or WSL and build the Windows installer:
  ```bash
  if [[ "$OS" == "Windows_NT" ]] || grep -qi microsoft /proc/version 2>/dev/null; then
    if command -v pwsh >/dev/null 2>&1; then
      pwsh -File ./scripts/windows/Build-ZscInstaller.ps1 -Version X.Y.Z
    else
      /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/windows/Build-ZscInstaller.ps1 -Version X.Y.Z
    fi
  fi
  ```
- Verify installer output exists: `dist/inno-out/ZiggyStarClaw_Setup_X.Y.Z_x64.exe`.
- Package release artifacts without rebuilding: `./scripts/package-release.sh --no-build --version=X.Y.Z --require-windows-installer`.
- Create and publish GitHub release `vX.Y.Z`, uploading all artifacts from `dist/ziggystarclaw_X.Y.Z_<date>/`, including the installer `.exe`, release archives, `checksums.txt`, and `update.json`.

## Native (Linux)

Build:
```bash
./.tools/zig-0.15.2/zig build
```

Run:
```bash
./zig-out/bin/ziggystarclaw-client
```

CLI:
```bash
./zig-out/bin/ziggystarclaw-cli
```

## Windows (cross-compile from Linux)

Build:
```bash
./.tools/zig-0.15.2/zig build -Dtarget=x86_64-windows-gnu
```

Artifacts:
```
zig-out/bin/ziggystarclaw-client.exe
zig-out/bin/ziggystarclaw-cli.exe
```

## WASM (Emscripten)

Load emsdk env (once per shell):
```bash
source ./scripts/emsdk-env.sh
```

Build:
```bash
./.tools/zig-0.15.2/zig build -Dwasm=true
```

Serve locally:
```bash
./scripts/serve-web.sh 8080
```

Open:
```
http://localhost:8080/ziggystarclaw-client.html
```

## Android (SDL + OpenGL ES)

Build APK:
```bash
./.tools/zig-0.15.2/zig build -Dandroid=true
```

APK output:
```
zig-out/bin/ziggystarclaw_android.apk
```

Install + run (from Windows PowerShell or any adb shell):
```powershell
adb install -r zig-out\bin\ziggystarclaw_android.apk
adb shell am start -S -W -n com.deanoc.ziggystarclaw/org.libsdl.app.SDLActivity
```

Logcat filter:
```powershell
adb logcat -v time ZiggyStarClaw:D *:S
```
