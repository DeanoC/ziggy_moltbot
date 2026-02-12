# Windows canvas/browser parity roadmap

Status: draft implementation roadmap for umbrella work item 9f.

## Goal

Bring Windows node canvas/browser behavior toward practical parity with Linux/macOS for:
- `canvas.present`
- `canvas.hide`
- `canvas.navigate`
- `canvas.eval`
- `canvas.snapshot`

while keeping each slice independently shippable.

---

## Current baseline

Implemented today:
- `canvas.present` / `canvas.hide` / `canvas.navigate` are available as logical node commands.
- `canvas.snapshot` has a best-effort headless-browser fallback path for URL screenshots.
- `canvas.eval` is still a placeholder and does not execute page JS through CDP.

Gaps:
- no persistent CDP target/session management on Windows node
- no real JS evaluation result contract for `canvas.eval`
- limited browser diagnostics/backoff behavior when browser startup fails

---

## Incremental slices

### 9f-browser-1 — Baseline hardening (shipped)

Scope:
- preserve existing command surface for `present/hide/navigate/snapshot`
- keep fallback screenshot path functional in user-session node mode

Acceptance:
- commands return stable payloads
- failures are actionable and do not crash node loop

### 9f-browser-2 — CDP session bootstrap (next)

Scope:
- add reusable browser bootstrap + target discovery on Windows
- expose internal session status/diagnostics for command handlers

Acceptance:
- node can start browser, create/select target, and maintain lifecycle
- reconnect/retry behavior is deterministic

### 9f-browser-3 — Real `canvas.eval` + `canvas.snapshot` over CDP (next)

Scope:
- implement `canvas.eval` via CDP `Runtime.evaluate`
- implement `canvas.snapshot` via CDP screenshot APIs
- maintain OpenClaw-compatible payloads

Acceptance:
- `canvas.eval` returns value/error metadata from active page context
- `canvas.snapshot` returns image payloads without shelling out to one-shot browser CLI

### 9f-browser-4 — Parity + diagnostics polish

Scope:
- align behavior across Windows/Linux/macOS node builds
- improve structured diagnostics for startup/navigation/eval/snapshot failures

Acceptance:
- command contracts match across platforms where features exist
- operator can identify backend and failure cause quickly from logs/errors

---

## Non-goals (for this umbrella)

- replacing browser engine choice for all platforms
- implementing full Playwright-style automation surface in node mode
- adding UI/tray-level browser configuration UX in this slice

---

## Tracking

- umbrella spec: `docs/spec_windows_node_capabilities.md`
- broader parity epic: `WORK_ITEMS_GLOBAL#12`
