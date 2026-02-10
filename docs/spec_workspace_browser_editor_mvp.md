# Workspace file browser + editor MVP (ZiggyStarClaw + OpenClaw)

WORK_ITEMS_GLOBAL#5

## Goal
Provide an operator-facing UI in ZiggyStarClaw to **browse and edit** safe, scoped workspace files (initially for maintaining `docs/WORK_ITEMS_GLOBAL.md`), backed by **safe gateway APIs**.

This doc is a planning stub / alignment artifact to keep the API + UI slices small.

## Non-goals (MVP)
- Arbitrary filesystem access outside the configured agent workspace.
- Binary files.
- Concurrent edits / merge UI.
- Search / full-text indexing.

## Proposed gateway API surface (OpenClaw)
A new `workspace.*` namespace (names TBD):

- `workspace.list`:
  - params: `{ prefix?: string, recursive?: boolean }`
  - result: `{ entries: Array<{ path, kind: 'file'|'dir', size?, updatedAtMs? }> }`

- `workspace.read`:
  - params: `{ path: string, maxBytes?: number }`
  - result: `{ path, content, size, updatedAtMs }`

- `workspace.write`:
  - params: `{ path: string, content: string, ifMatchUpdatedAtMs?: number }`
  - result: `{ ok: true, path, size, updatedAtMs }`

- `workspace.mkdir`:
  - params: `{ path: string, recursive?: boolean }`

- `workspace.stat`:
  - params: `{ path: string }`
  - result: `{ path, kind, size?, updatedAtMs? }`

### Safety constraints
- All paths are **workspace-relative** and normalized.
- Reject paths that escape (`..`, absolute paths, drive letters).
- Optional allowlist/denylist patterns (start with denylist for `node_modules`, `.git`, etc.).
- Enforce max read / max write sizes.
- Gate behind exec-approval-like policy? (maybe not in MVP, but log all writes).

## ZiggyStarClaw UI MVP
A simple panel:

- Left: file tree (start at workspace root or a chosen subdir like `docs/`).
- Right: editor with save button.
- Status: last saved time, dirty indicator.

### Initial flow
1. Browse to `docs/WORK_ITEMS_GLOBAL.md`
2. Open
3. Edit
4. Save

## Incremental plan
1. (OpenClaw) Add read-only APIs: `workspace.list`, `workspace.read`.
2. (ZSC) Add UI shell + wiring for list/read.
3. (OpenClaw) Add `workspace.write` with safety + logging.
4. (ZSC) Enable editing + save.

## Open questions
- Where should "workspace" root resolve? Agent workspace dir (current behavior) vs operator workspace.
- Do we need per-session isolation or shared root?
- Concurrency control: should we use `updatedAtMs` optimistic lock?
