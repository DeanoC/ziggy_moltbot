# ZiggyStarClaw - Build & Run

This repo uses the pinned Zig toolchain at `./.tools/zig-0.15.2/zig`.

Always run all platform builds before final responses:
- Native: `./.tools/zig-0.15.2/zig build`
- Windows: `./.tools/zig-0.15.2/zig build -Dtarget=x86_64-windows-gnu`
- WASM: `source ./scripts/emsdk-env.sh && ./.tools/zig-0.15.2/zig build -Dwasm=true`
- Android: `./.tools/zig-0.15.2/zig build -Dandroid=true`

When handling PRs, always check review subcomments (inline threads), not just top-level reviews.

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
