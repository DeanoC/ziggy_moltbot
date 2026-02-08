# Spec: Windows node capabilities (camera/screen/browser)

Goal: Windows node should provide feature parity with Linux node for:
- camera_list / camera_snap / camera_clip
- screen_record
- browser-like automation via canvas (CDP)

This spec is a roadmap with incremental delivery.

---

## Camera

### MVP
- Implement `camera.list` to enumerate available webcams.
- Implement `camera.snap`:
  - Capture a single image
  - Return bytes as base64 (or write to file and return path)

### Implementation notes
- Use Windows Media Foundation APIs.
- Consider permissions/consent UX via the tray app.

---

## Screen

### MVP
- Implement `screen.record`:
  - record N seconds
  - encode to mp4/webm if feasible

### Implementation notes
- Use Desktop Duplication API (DXGI) for capture.
- Encoding may require Media Foundation or FFmpeg (bundling/licensing considerations).

---

## Browser/Canvas

### MVP
- Implement `canvas.navigate` / `canvas.eval` / `canvas.snapshot` using CDP.

(Tracked in WORK_ITEMS_GLOBAL#12.)

---

## Acceptance

- Capability endpoints work when node is running as a user-session app.
- Clear error messages when permission denied.
- Logs are actionable.
