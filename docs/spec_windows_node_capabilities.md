# Spec: Windows node capabilities (camera/screen/browser)

Goal: Windows node should provide feature parity with Linux node for:
- `camera.list` / `camera.snap` / `camera.clip`
- `screen.record`
- browser-like automation via canvas (CDP)

This document is a **roadmap with incremental delivery**: each slice should be shippable as a PR and safe to enable in node-mode.

---

## Incremental plan (shippable slices)

### 9f1 — Windows `camera.list` (MVP)

Deliverables:
- Advertise `capabilities: ["camera"]` and `commands: ["camera.list"]` **only on Windows**.
- Implement `camera.list` returning a stable shape:

```json
{
  "backend": "powershell-cim",
  "devices": [
    { "id": "<PNPDeviceID>", "name": "<Name>" }
  ]
}
```

Notes:
- First pass can be best-effort enumeration (PowerShell/CIM) to de-risk UX and protocol shape.
- Must log actionable diagnostics when enumeration fails (missing PowerShell, non-zero exit, invalid JSON).

### 9f2 — Replace enumeration backend with Windows Media Foundation

Deliverables:
- Enumerate video capture devices using Windows Media Foundation (MF) device APIs.
- Keep the response shape from 9f1 stable.

### 9f3 — Windows `camera.snap`

Deliverables:
- Implement `camera.snap` using MF:
  - capture a single frame
  - return `{ format: "jpeg"|"png", base64: "..." }` or `{ path: "..." }`
- Add permission/consent story for user-session node (tray UX).

### 9f4 — Windows `camera.clip`

Deliverables:
- Implement `camera.clip`:
  - record N seconds
  - encode to mp4/webm if feasible
- Confirm behavior when camera is busy / in-use.

### 9f5 — Windows `screen.record`

Deliverables:
- Implement `screen.record`:
  - record N seconds
  - return `{ format, path|base64 }`

Implementation notes:
- Use Desktop Duplication API (DXGI) for capture.
- Encoding may require Media Foundation or FFmpeg (bundling/licensing considerations).

### Canvas / browser automation

MVP:
- Implement `canvas.navigate` / `canvas.eval` / `canvas.snapshot` using CDP.

Tracking:
- This is tracked separately in WORK_ITEMS_GLOBAL#12.

---

## Acceptance

- Capability endpoints work when node is running as a user-session app.
- Clear error messages when permission is denied or the backend is missing.
- Logs are actionable (include backend + exit codes where applicable).
