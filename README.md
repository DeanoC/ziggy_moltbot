# ZiggyStarClaw
![ZiggyStarClaw](assets/ZiggyStarClaw.png)


ZiggyStarClaw and the Lobsters From Mars.

A clean, performant MoltBot client built in Zig with an ImGui-based UI. Targets native desktop and optional WASM.

## Status
Planning → initial scaffolding in progress.

## Quick Start

```bash
# Fetch dependencies
zig build --fetch

# Build native target
zig build

# Run
zig build run
```

## WASM (Emscripten via zemscripten)

```bash
# Install emsdk once (if not already installed)
./.tools/emsdk/emsdk install latest
./.tools/emsdk/emsdk activate latest

# Build
zig build -Dwasm=true
```

Outputs are installed under `zig-out/web/`.

## Layout
See `docs/MOLTBOT_ZIG_CLIENT_IMPLEMENTATION_PLAN.md` for the full design and roadmap.
