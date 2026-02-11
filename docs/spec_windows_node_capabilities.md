# Spec: Windows node capabilities (camera/screen/browser)

Goal: Windows node should move toward practical parity with Linux/macOS node surfaces for:
- `camera.list` / `camera.snap` / `camera.clip`
- `screen.record`
- browser-like automation for canvas workflows

This is an **umbrella roadmap** with incremental, shippable slices.
Each slice should be safe to ship independently in node-mode.

---

## Current status (2026-02-11)

Implemented now:
- Windows-only advertisement of camera capability/command for MVP:
  - `capabilities` includes `"camera"`
  - `commands` includes `"camera.list"`
- Router wiring is command-surface driven (node advertises only what router can execute).
- `camera.list` is implemented with a PowerShell/CIM backend (`powershell-cim`) and returns device objects with stable IDs and optional position hints.

Not yet implemented on Windows:
- `camera.snap`
- `camera.clip`
- `screen.record`
- full CDP-based canvas/browser parity (tracked separately in WORK_ITEMS_GLOBAL#12)

---

## Command + payload contract (current MVP)

`camera.list` response shape:

```json
{
  "backend": "powershell-cim",
  "devices": [
    {
      "id": "<PNPDeviceID>",
      "deviceId": "<PNPDeviceID>",
      "name": "<Name>",
      "position": "front|back|external" // optional
    }
  ]
}
```

Notes:
- `id` and `deviceId` are both emitted for compatibility with existing OpenClaw tooling.
- `position` is best-effort and may be omitted when unknown.

---

## Incremental plan (shippable slices)

### 9f1 — Node command surface wiring + capability/command advertisement

Deliverables:
- Keep node metadata (`caps`/`commands`) aligned with actual router registration.
- Only advertise commands/capabilities that are executable on the current platform.

Status:
- Landed for current surface, including Windows-only `camera.list` advertisement.

### 9f2 — Windows `camera.list` backend hardening

Deliverables:
- Keep stable payload shape (`backend`, `devices[*].id/deviceId/name`, optional `position`).
- Actionable diagnostics when enumeration fails:
  - missing PowerShell executable
  - non-zero exit codes
  - invalid JSON output

Status:
- MVP landed with PowerShell/CIM backend and diagnostics.
- Future swap to Windows Media Foundation should preserve payload shape.

### 9f3 — Windows `camera.snap`

Deliverables:
- Implement `camera.snap` with OpenClaw-compatible payload:
  - `{ format: "jpeg"|"png", base64, width, height }`
- Device selection support via `deviceId` from `camera.list`.
- Permission/consent UX story for user-session node (tray integration).

### 9f4 — Windows `screen.record`

Deliverables:
- Implement `screen.record` with OpenClaw-compatible payload:
  - `{ format, base64, durationMs, fps, screenIndex, hasAudio }`
- Start with ffmpeg-first approach if needed; keep native DXGI/MF path as follow-up.

### Post-9f4 follow-up — Windows `camera.clip`

Deliverables:
- Implement `camera.clip`:
  - record N seconds
  - encode to mp4/webm
  - confirm busy/in-use behavior and error messages

### Canvas / browser automation

MVP for parity target:
- `canvas.navigate` / `canvas.eval` / `canvas.snapshot` via real CDP.

Tracking:
- Tracked separately in WORK_ITEMS_GLOBAL#12.

---

## Acceptance criteria

- Capability endpoints work when node runs as user-session app.
- Node only advertises executable commands for the active platform.
- Errors are actionable (backend + exit code/context where applicable).
- Future backend swaps (e.g., MF) preserve `camera.list` payload compatibility.
