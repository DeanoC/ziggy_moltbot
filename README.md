# Ziggy StarClaw and the Lobsters From Mars
![ZiggyStarClaw](assets/ZiggyStarClaw.png)


Ziggy StarClaw and the Lobsters From Mars (ZiggyStarClaw) is an implementation of an [OpenClaw](https://github.com/openclaw/openclaw) operator and client.

Built with Zig, it runs on Linux, Windows, Android, and WASM (web) and talks via the OpenClaw websocket interface.

The goal is to provide a lightweight alternative to the official companion apps.


## Status
Active development (latest release: v0.3.4).

Highlights:
- Cross-platform client (Linux, Windows, Android, WASM).
- Windows installer (`ZiggyStarClaw_Setup_<version>_x64.exe`) from the latest release.
- Windows node runner modes: service and scheduled task.
- WIP GUI for interactive use and onboarding.
- CLI approvals management and interactive REPL mode (`--interactive`).
- `--run` supports default node from config when `--node` is not provided.
- Auto-connect on launch toggle in Settings.

## Latest Release
Download the latest release here:

- https://github.com/DeanoC/ZiggyStarClaw/releases/latest

Windows users can install with:

- `ZiggyStarClaw_Setup_<version>_x64.exe`

## User Guide
Start here: `docs/user/README.md`

## Quick Start

```bash
# Fetch dependencies
zig build --fetch

# Build native target
zig build

# Run
zig build run

# Build node-only CLI profile (no operator surface)
zig build -Dclient=false -Dcli_operator=false --prefix ./zig-out/node-only
```

## Node install (virgin machine overview)

This is the high-level flow to bring up a new node on a fresh machine.

### 1) Get the CLI onto the machine
- Copy `ziggystarclaw-cli` (Linux/macOS) or `ziggystarclaw-cli.exe` (Windows) to the target.

### 2) Create config + pair (one-time)

**Windows**

```powershell
$cfg = Join-Path $env:APPDATA 'ZiggyStarClaw\config.json'
.\ziggystarclaw-cli.exe --node-register --wait-for-approval --config $cfg --display-name "$env:COMPUTERNAME-windows"
```

**Linux/macOS**

```bash
cfg="$HOME/.config/ziggystarclaw/config.json"
./ziggystarclaw-cli --node-register --wait-for-approval --config "$cfg" --display-name "$(hostname)-linux"
```

This will:
- create a device identity file (stable device id)
- trigger a pairing request in the gateway
- after approval, persist `nodeId` + `nodeToken` into config.json

### 3) Start node mode

```bash
./ziggystarclaw-cli --node-mode --config "$cfg" --as-node --no-operator
```

### 4) (Optional) Always-on service
- Windows: `node service install`
- Linux: use systemd (see docs/user/node-mode.md)

Docs: `docs/user/node-mode.md`

## WASM (Emscripten via zemscripten)

```bash
# Install emsdk once (if not already installed)
./.tools/emsdk/emsdk install latest
./.tools/emsdk/emsdk activate latest

# Build (Windows: run scripts/patch-zemscripten.ps1 once after fetch)\nzig build -Dwasm=true
```

Outputs are installed under `zig-out/web/`.

## Packaging
See `docs/PACKAGING.md` and `docs/RELEASE_CHECKLIST.md` for release packaging and checklist steps.

## Layout
See `docs/ZIGGYSTARCLAW_IMPLEMENTATION_PLAN.md` for the full design and roadmap.
