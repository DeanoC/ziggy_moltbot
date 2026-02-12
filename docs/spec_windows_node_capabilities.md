# Spec: Windows node capabilities (camera/screen/browser)

Goal: Windows node should move toward practical parity with Linux/macOS node surfaces for:
- `camera.list` / `camera.snap` / `camera.clip`
- `screen.record`
- browser-like automation for canvas workflows

This is an **umbrella roadmap** with incremental, shippable slices.
Each slice should be safe to ship independently in node-mode.

---

## Current status (2026-02-12)

Implemented now:
- Router wiring is command-surface driven (node advertises only what router can execute).
- Windows camera advertisement is executable-aware:
  - `camera.list` is advertised only when PowerShell is runnable.
  - `camera.snap`/`camera.clip` are advertised only when both PowerShell + ffmpeg are runnable.
- `camera.list` is implemented with a PowerShell/CIM backend (`powershell-cim`) and returns device objects with stable IDs and optional position hints.
- `camera.snap` is implemented with an ffmpeg+dshow capture backend (`ffmpeg-dshow`) and returns OpenClaw-compatible payload:
  - `{ format: "jpeg"|"png", base64, width, height }`
  - supports `deviceId` selection using IDs returned by `camera.list`.
- `camera.clip` is implemented with an ffmpeg+dshow backend (`ffmpeg-dshow`) and returns OpenClaw-compatible payload:
  - `{ format, base64, durationMs, hasAudio }`
  - supports `deviceId` selection and best-effort `facing` routing via inferred camera `position`.
  - supports `format=mp4|webm`.
  - supports best-effort audio capture (`includeAudio=true`) with automatic fallback to video-only output when audio input is unavailable (`hasAudio=false`).
- `screen.record` is implemented with an ffmpeg+gdigrab backend (`ffmpeg-gdigrab`) and returns OpenClaw-compatible payload:
  - `{ format, base64, durationMs, fps, screenIndex, hasAudio }`
  - supports monitor index mapping via PowerShell Forms monitor metadata (primary monitor normalized to `screenIndex=0`).
  - supports best-effort audio capture (`includeAudio=true`) with automatic fallback to video-only output when audio input is unavailable (`hasAudio=false`).

Not yet implemented on Windows:
- advanced `camera.clip` coverage (audio source/device selection + richer diagnostics)
- advanced `screen.record` coverage (non-PowerShell monitor discovery fallback improvements + richer audio source selection)
- full CDP-based canvas/browser parity (tracked separately in WORK_ITEMS_GLOBAL#12)

---

## Command + payload contract (current Windows surface)

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

`camera.snap` request params (supported subset):

```json
{
  "deviceId": "<PNPDeviceID>",
  "format": "jpeg|jpg|png"
}
```

`camera.snap` response shape:

```json
{
  "format": "jpeg|png",
  "base64": "<image bytes base64>",
  "width": 1280,
  "height": 720
}
```

Notes:
- If `deviceId` is omitted, the backend selects the first enumerated camera.
- Current backend is `ffmpeg-dshow`; `format` defaults to `jpeg`.

`camera.clip` request params (supported subset):

```json
{
  "durationMs": 3000,
  "duration": "3s",      // optional shorthand alternative to durationMs
  "format": "mp4|webm",
  "includeAudio": true,
  "deviceId": "<PNPDeviceID>",
  "facing": "front|back" // optional best-effort device routing
}
```

`camera.clip` response shape:

```json
{
  "format": "mp4|webm",
  "base64": "<video bytes base64>",
  "durationMs": 3000,
  "hasAudio": true
}
```

Notes:
- Current backend is `ffmpeg-dshow`.
- If `deviceId` is provided, it takes precedence over `facing`.
- `facing` is best-effort using inferred camera `position`; if no match is found, the backend falls back to the first enumerated camera.
- `includeAudio=true` attempts microphone capture via ffmpeg and returns `hasAudio=true` when successful.
- When audio capture is unavailable/unsupported on the host, backend falls back to video-only output and returns `hasAudio=false`.

`screen.record` request params (supported subset):

```json
{
  "durationMs": 5000,
  "duration": "5s",      // optional shorthand alternative to durationMs
  "fps": 12,
  "screenIndex": 0,
  "format": "mp4",
  "includeAudio": false
}
```

`screen.record` response shape:

```json
{
  "format": "mp4",
  "base64": "<video bytes base64>",
  "durationMs": 5000,
  "fps": 12,
  "screenIndex": 0,
  "hasAudio": true
}
```

Notes:
- Current backend is `ffmpeg-gdigrab`.
- Monitor index mapping is best-effort via PowerShell Forms (`[System.Windows.Forms.Screen]::AllScreens`):
  - primary monitor is normalized to `screenIndex=0`
  - additional monitors follow discovery order
  - if monitor discovery fails, backend falls back to legacy desktop capture for `screenIndex=0` and rejects non-zero indices with actionable errors.
- `includeAudio=true` attempts microphone capture via ffmpeg and returns `hasAudio=true` when successful.
- When audio capture is unavailable/unsupported on the host, backend falls back to video-only output and returns `hasAudio=false`.

---

## Incremental plan (shippable slices)

### 9f1 — Node command surface wiring + capability/command advertisement

Deliverables:
- Keep node metadata (`caps`/`commands`) aligned with actual router registration.
- Only advertise commands/capabilities that are executable on the current platform.

Status:
- Landed for current surface with executable-aware advertisement (`camera.list`, `camera.snap`, `camera.clip`).

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

Status:
- Landed with ffmpeg+dshow backend.
- Command registration/advertisement is executable-aware (`camera.snap` is exposed only when ffmpeg + PowerShell are runnable).

### 9f4 — Windows `screen.record`

Deliverables:
- Implement `screen.record` with OpenClaw-compatible payload:
  - `{ format, base64, durationMs, fps, screenIndex, hasAudio }`
- Start with ffmpeg-first approach if needed; keep native DXGI/MF path as follow-up.

Status:
- MVP landed with `ffmpeg-gdigrab` backend and executable-aware registration/advertisement (`screen.record` is exposed only when ffmpeg is runnable).
- Follow-up slice landed for monitor-index mapping via PowerShell Forms metadata:
  - primary monitor normalized to `screenIndex=0`
  - non-primary monitors selectable by index
  - graceful fallback to legacy desktop capture for `screenIndex=0` when monitor discovery is unavailable.
- Follow-up slice landed for best-effort `includeAudio=true` capture with automatic fallback to video-only output when audio input is unavailable.
- Current remaining gaps for this slice:
  - non-PowerShell monitor discovery fallback improvements
  - richer audio source selection (beyond default microphone input)

### Post-9f4 follow-up — Windows `camera.clip`

Deliverables:
- Implement `camera.clip`:
  - record N seconds
  - encode to mp4/webm
  - confirm busy/in-use behavior and error messages

Status:
- MVP landed with `ffmpeg-dshow` backend and executable-aware registration/advertisement (`camera.clip` is exposed only when ffmpeg + PowerShell are runnable).
- Follow-up landed for optional `format=webm` output in addition to `mp4`.
- Follow-up landed for best-effort `includeAudio=true` capture with automatic fallback to video-only output when audio input is unavailable.
- Current remaining gaps for this slice:
  - explicit audio source/device selection
  - further hardening around device-busy/in-use diagnostics

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
