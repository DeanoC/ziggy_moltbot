#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKQ="$ROOT/scripts/workq.js"
TMP_DIR="$ROOT/tmp/workq-smoke-$(date +%Y%m%d-%H%M%S)-$$"
LOCK_DIR="$TMP_DIR/.locks"
STATE_A="$TMP_DIR/state-a.json"
STATE_B="$TMP_DIR/state-b.json"
BACKLOG="$TMP_DIR/WORK_ITEMS_GLOBAL.md"

mkdir -p "$TMP_DIR" "$LOCK_DIR"

cat > "$BACKLOG" <<'MD'
# WORK_ITEMS_GLOBAL

## Current items
1. `[zsc]` MVP claim test item
2. `[zsc]` Blocked item. blocked-by: WORK_ITEMS_GLOBAL#1
3. **no-auto-start**: `[zsc]` Manual item
4. `[openclaw]` Other queue item

## Done
9. `[zsc]` Already done
MD

run_workq() {
  node "$WORKQ" "$@"
}

assert_json() {
  local json="$1"
  local js="$2"
  node -e "const obj = JSON.parse(process.argv[1]); if (!(${js})) { console.error(JSON.stringify(obj,null,2)); process.exit(1); }" "$json"
}

echo "[1/5] sync backlog into empty state A"
out_sync_a="$(run_workq sync-backlog --state "$STATE_A" --lock-dir "$LOCK_DIR" --file "$BACKLOG")"
assert_json "$out_sync_a" "obj.ok && obj.command==='sync-backlog' && obj.eligibleCount===1"

echo "[2/5] sync backlog into separate empty state B (simulates second cron worker)"
out_sync_b="$(run_workq sync-backlog --state "$STATE_B" --lock-dir "$LOCK_DIR" --file "$BACKLOG")"
assert_json "$out_sync_b" "obj.ok && obj.eligibleCount===1"

echo "[3/5] claim from empty state A succeeds"
out_claim_a="$(run_workq claim --state "$STATE_A" --lock-dir "$LOCK_DIR" --queue zsc --session sess-A --lease-ms 20)"
assert_json "$out_claim_a" "obj.ok && obj.command==='claim' && obj.claimed===true && obj.item.itemId==='1'"

echo "[4/5] duplicate claim from state B is prevented by lock"
out_claim_b="$(run_workq claim --state "$STATE_B" --lock-dir "$LOCK_DIR" --queue zsc --session sess-B --lease-ms 20)"
assert_json "$out_claim_b" "obj.ok && obj.claimed===false && obj.skipped && obj.skipped.locked>=1"

echo "[5/5] stale detection path"
sleep 0.05
out_stale="$(run_workq status --state "$STATE_A" --lock-dir "$LOCK_DIR" --stale --ttl-ms 20)"
assert_json "$out_stale" "obj.ok && obj.command==='status' && obj.totals.staleClaims>=1"

echo "PASS: workq MVP smoke checks passed"
echo "Artifacts: $TMP_DIR"
