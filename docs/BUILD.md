# Build

## Requirements

- Zig 0.15.2+
- Linux native: OpenGL + X11 dev packages (see below)
- For WASM: Emscripten SDK installed under `.tools/emsdk`

### Linux system packages (Ubuntu/Debian)

```bash
sudo apt-get install -y \
  libgl1-mesa-dev libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev
```

## Native Build

```bash
zig build
zig build run
```

## Tests

```bash
zig build test
```

## WASM Build (Emscripten via zemscripten)

```bash
# Install emsdk once (if not already installed)
./.tools/emsdk/emsdk install latest
./.tools/emsdk/emsdk activate latest

# Build
zig build -Dwasm=true
```

Outputs are installed under `zig-out/web/` (HTML/JS/WASM).

## WASM Node Runtime (connect-only skeleton; no emsdk)

This is **not** the browser UI build. It produces a standalone `.wasm` module
intended for a future node runtime (likely hosted by JS, e.g. WebWorker).

```bash
zig build node-wasm
```

Output:
- `zig-out/bin/ziggystarclaw-node.wasm`

## Node Port Stubs (Android + WASM; no NDK/emsdk)

Compile-only port stubs that establish a place for platform-specific node glue.

```bash
zig build node-ports
```

Outputs:
- `zig-out/lib/libzsc_node_wasm_scaffold.a`
- `zig-out/lib/libzsc_node_android_scaffold.a`

## Android Node Runtime (connect-only skeleton; no NDK)

This produces a static library for an **Android** node runtime skeleton.
It does not link libc and does not require the Android NDK on CI.

```bash
zig build node-android
```

Output:
- `zig-out/lib/libzsc_node_android.a`
