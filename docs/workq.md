# workq MVP (local work queue broker)

`workq` is a dependency-light Node CLI for cron-safe work-item claiming.

- No sqlite3 binary required
- No Python required
- JSON-only stdout output (machine-parseable)
- Uses atomic state writes + lock files for single-host race safety
- Interoperates with existing lock files in:
  - `/safe/Safe/openclaw-config/workspace/.locks/workitem-<ID>.lock`

## CLI path

```bash
node /safe/Safe/openclaw-config/workspace/ZiggyStarClaw/scripts/workq.js help
```

## State + lock defaults

From repo root (`/safe/Safe/openclaw-config/workspace/ZiggyStarClaw`):

- default state: `../.workq/state.json`
- default lock dir: `../.locks`

You can override with `--state` and `--lock-dir`.

## Commands

## 1) Sync backlog into state

```bash
node scripts/workq.js sync-backlog \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --file /safe/Safe/openclaw-config/workspace/docs/WORK_ITEMS_GLOBAL.md
```

Backlog parsing rules in this MVP:

- Parse only `## Current items` section, stop at `## Done`
- Keep lines that look like `<itemId>. ...`
- Eligible for claim only when:
  - item has `[zsc]`
  - item is not marked `**no-auto-start**`
  - item does not contain `blocked-by:`
- `**no-auto-merge**` items remain eligible

## 2) Claim next eligible item

```bash
node scripts/workq.js claim \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --queue zsc \
  --session pm-loop-main \
  --lease-ms 7200000
```

If successful:

- lock file is created atomically (`workitem-<ID>.lock`)
- state claim row is written atomically
- output JSON includes itemId/label/workLine/session

If no work is claimable, returns:

```json
{"ok":true,"command":"claim","claimed":false,"reason":"no_eligible_items",...}
```

## 3) Heartbeat claimed work

```bash
node scripts/workq.js heartbeat \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --item 20a \
  --session pm-loop-main
```

Updates lease heartbeat in both state and lock file metadata.

## 4) Complete / update PR metadata

```bash
node scripts/workq.js complete \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --item 20a \
  --branch ziggy/workitem-20a \
  --pr 130 \
  --url https://github.com/DeanoC/ZiggyStarClaw/pull/130
```

Default completion status behavior:

- if any of `--branch/--pr/--url` is provided: `status=pr_opened`
- otherwise: `status=done`

Use `--status` to force explicit status.

## 5) Status / stale detection

```bash
node scripts/workq.js status \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json
```

Only stale entries:

```bash
node scripts/workq.js status \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --stale \
  --ttl-ms 7200000
```

`list` is an alias for `status`.

## Atomicity strategy (single-host cron races)

- state mutex lock file: `<state>.mutex` acquired with `open(..., O_EXCL)`
- stale mutex auto-recovery by lock age timeout
- state file writes via temp file + atomic rename
- item lock claim via `open(workitem-<ID>.lock, O_EXCL)`
- duplicate claim prevented if lock already exists

## Migration note (cron prompt replacement)

These are exact command replacements for the fragile markdown+lock prompt flow.

### PM-loop replacement

Old behavior: parse markdown in prompt, manually check/create lock, emit `SPAWN_REQUEST`.

New behavior:

```bash
# 1) refresh claimable pool from backlog
node /safe/Safe/openclaw-config/workspace/ZiggyStarClaw/scripts/workq.js sync-backlog \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --file /safe/Safe/openclaw-config/workspace/docs/WORK_ITEMS_GLOBAL.md

# 2) atomically claim next item
node /safe/Safe/openclaw-config/workspace/ZiggyStarClaw/scripts/workq.js claim \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --queue zsc \
  --session pm-loop
```

If `claimed=true`, use returned `item.itemId`, `item.label`, `item.workLine` to spawn worker.

### Progress-guard replacement

Old behavior: infer stale work from ad-hoc lock checks.

New behavior:

```bash
node /safe/Safe/openclaw-config/workspace/ZiggyStarClaw/scripts/workq.js status \
  --state /safe/Safe/openclaw-config/workspace/.workq/zsc-state.json \
  --stale \
  --ttl-ms 7200000
```

Alert when JSON `totals.staleClaims > 0` or `totals.staleLocks > 0`.
