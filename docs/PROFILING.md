# Profiling (Tracy + Browser Devtools)

This repo already has profiling zones (`utils/profiler.zig`) throughout the UI and render loop. This document describes the repeatable workflow to capture profiles across platforms.

## One-Time Setup

### Ensure `.tools` is available in your worktree

All scripts assume the pinned Zig is at:
- `./.tools/zig-0.15.2/zig`

If you are in a git worktree that doesn’t have `./.tools`, run:
```bash
./scripts/ensure-tools.sh
```

### Fetch Zig deps (if your Zig cache was trimmed)
```bash
./.tools/zig-0.15.2/zig build --fetch
```

## Native (Linux/macOS) Tracy Capture

### Capture a `.tracy` file (automated)
```bash
./scripts/profile/native-capture.sh --duration 15
```

Optional: enable callstacks (helps show actual function names when you click a zone):
```bash
./.tools/zig-0.15.2/zig build -Denable_ztracy=true -Dtracy_on_demand=true -Dtracy_callstack=8
```

Outputs:
- `profiles/<timestamp>/native.tracy`
- `profiles/<timestamp>/meta.json`

### View the capture

Install/download Tracy UI for your platform (GUI). `scripts/tools/ensure-tracy.sh` currently only ensures `tracy-capture` (CLI) is available on Linux/macOS.

```bash
TracyProfiler profiles/<timestamp>/native.tracy
```

## Windows (cross-compile) + Capture

Cross-compile with Tracy markers enabled:
```bash
./scripts/profile/windows-build.sh
```

Then run the `.exe` on a Windows machine and capture using Tracy tools on that machine (or from another machine that can connect to the Windows host’s Tracy port).

## Android Tracy Capture (USB + adb)

### Capture a `.tracy` file (automated)
```bash
./scripts/profile/android-capture.sh --install --duration 15
```

This will:
1. Build an APK with Tracy enabled (Android opt-in flag is required).
2. Install + launch it.
3. `adb forward tcp:8086 tcp:8086`
4. Run `tracy-capture` on the host to save a `.tracy` file.

Outputs:
- `profiles/<timestamp>/android.tracy`
- `profiles/<timestamp>/meta.json`

## WASM (Browser) Profiling

WASM builds do not use Tracy. Instead, you can optionally emit `performance.mark/measure` entries so your existing `profiler.zone("...")` names show up in Chrome/Firefox traces.

Build with markers:
```bash
./scripts/profile/wasm-build.sh
```

Serve locally:
```bash
./scripts/serve-web.sh 8080
```

Record a trace:
1. Open devtools -> Performance
2. Record, interact with the UI, stop
3. Search for `zsc:` entries (for example `zsc:frame.ui`, `zsc:ui.draw`, etc.)

## What To Look For (Click Latency)

Common patterns when a “new backend” makes the UI feel sluggish:
- `frame.net` dominates: server messages are being processed on the UI thread and blocking input/render.
- `frame.ui` dominates: UI layout or per-frame allocations are too heavy.
- `frame.render` dominates: GPU submission or resource churn.

Native captures already include zones for:
- `frame.events`
- `frame.net`
- `frame.ui`
- `frame.render`

WASM traces should show the same names prefixed with `zsc:`.

## Offline Summary (Automated)

You can generate a quick "top zones" report from a `.tracy` file (useful for CI artifacts or when the problem is not obvious):

```bash
./scripts/profile/analyze-tracy.sh profiles/<timestamp>/native.tracy
./scripts/profile/analyze-tracy.sh profiles/<timestamp>/native.tracy --self
./scripts/profile/analyze-tracy.sh profiles/<timestamp>/native.tracy --filter text.
```

This uses Tracy's `tracy-csvexport` tool to extract zone statistics and then prints the worst offenders by total/max/mean time.
