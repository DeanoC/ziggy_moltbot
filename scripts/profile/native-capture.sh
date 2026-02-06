#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

duration_sec=15
optimize="ReleaseSafe"
out_path=""

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/profile/native-capture.sh [--duration SEC] [--optimize MODE] [--out FILE]

Builds + runs the native client with Tracy markers and captures a `.tracy` file.

Defaults:
  --duration 15
  --optimize ReleaseSafe

Notes:
  - Uses TRACY_ON_DEMAND so captures only happen when `tracy-capture` connects.
  - Output defaults to profiles/<timestamp>/native.tracy
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)
      duration_sec="${2:-}"; shift 2 ;;
    --optimize)
      optimize="${2:-}"; shift 2 ;;
    --out)
      out_path="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

"${root_dir}/scripts/ensure-tools.sh" >/dev/null
"${root_dir}/scripts/tools/ensure-tracy.sh" >/dev/null

zig="${root_dir}/.tools/zig-0.15.2/zig"

if [[ -z "${out_path}" ]]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out_dir="${root_dir}/profiles/${stamp}"
  mkdir -p "${out_dir}"
  out_path="${out_dir}/native.tracy"
else
  mkdir -p "$(dirname "${out_path}")"
fi

git_sha="$(git -C "${root_dir}" rev-parse HEAD 2>/dev/null || echo unknown)"
meta_path="$(dirname "${out_path}")/meta.json"
cat >"${meta_path}" <<META
{
  "platform": "native",
  "git_sha": "${git_sha}",
  "duration_sec": ${duration_sec},
  "optimize": "${optimize}",
  "zig_flags": ["-Denable_ztracy=true", "-Dtracy_on_demand=true"]
}
META

echo "[profile] fetching deps" >&2
"${zig}" build --fetch

echo "[profile] building (native)" >&2
"${zig}" build -Doptimize="${optimize}" -Denable_ztracy=true -Dtracy_on_demand=true

tracy_capture=""
tracy_capture="$(find "${root_dir}/.tools/tracy" -maxdepth 3 -type f -iname "tracy-capture*" -perm -u+x 2>/dev/null | head -n 1 || true)"
if [[ -z "${tracy_capture}" ]]; then
  echo "[profile] tracy-capture not found; ensure scripts/tools/ensure-tracy.sh succeeded." >&2
  exit 1
fi

echo "[profile] starting app" >&2
"${root_dir}/zig-out/bin/ziggystarclaw-client" &
app_pid=$!

cleanup() {
  if kill -0 "${app_pid}" 2>/dev/null; then
    kill -INT "${app_pid}" 2>/dev/null || true
    sleep 0.5
    kill -KILL "${app_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sleep 1

echo "[profile] capturing -> ${out_path}" >&2
help="$("${tracy_capture}" -h 2>&1 || true)"
cap_args=( -a 127.0.0.1 -p 8086 -o "${out_path}" )
if echo "${help}" | grep -q -- " -s seconds"; then
  cap_args+=( -s "${duration_sec}" )
elif echo "${help}" | grep -q -- " -t"; then
  cap_args+=( -t "${duration_sec}" )
elif echo "${help}" | grep -q -- " --time"; then
  cap_args+=( --time "${duration_sec}" )
fi

set +e
"${tracy_capture}" "${cap_args[@]}" &
cap_pid=$!

# Hard-stop guard in case capture doesn't respect the duration flag.
# Use SIGINT first so tracy-capture disconnects cleanly and flushes the file.
(
  sleep "$(( duration_sec + 5 ))"
  kill -INT "${cap_pid}" 2>/dev/null || true
  sleep 3
  kill -KILL "${cap_pid}" 2>/dev/null || true
) &
guard_pid=$!

wait "${cap_pid}"
cap_status=$?
kill "${guard_pid}" 2>/dev/null || true
wait "${guard_pid}" 2>/dev/null || true
set -e

if [[ "${cap_status}" -ne 0 ]]; then
  echo "[profile] tracy-capture exited with status ${cap_status}" >&2
  exit "${cap_status}"
fi

echo "[profile] done: ${out_path}" >&2
