# Android + WASM Node Scaffolding (WIP)

This document describes the *scaffold only* work for running ZiggyStarClaw as an **OpenClaw node** on:

- Android
- WASM (browser / WebWorker)

The current project already supports:

- Desktop node-mode via `ziggystarclaw-cli --node-mode`
- Android + WASM **client** builds (UI/operator)

## What this scaffold provides

- A stable place to put platform-specific node glue code:
  - `src/node/ports/android_scaffold.zig`
  - `src/node/ports/wasm_scaffold.zig`
- A build step that compiles these port stubs as static libraries (no NDK / emsdk required):

```sh
zig build node-ports
```

## What this scaffold does *not* provide (yet)

- A working Android/WASM node runtime
- Transport (WebSocket) for these targets
- Capability implementations (screen/camera/location/etc)

## Next steps (planned)

- Define a small `NodePlatform` interface used by node-mode handlers:
  - filesystem access
  - notifications
  - process execution (if allowed)
  - screen/camera/location APIs
- Implement platform bindings:
  - Android: JNI bridge, permissions model, background execution constraints
  - WASM: WebWorker runtime, browser permission APIs, postMessage integration

