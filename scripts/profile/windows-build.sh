#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

optimize="ReleaseSafe"

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/profile/windows-build.sh [--optimize MODE]

Cross-compiles the client for Windows with Tracy markers enabled.

Defaults:
  --optimize ReleaseSafe

Output:
  zig-out/bin/ziggystarclaw-client.exe
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --optimize)
      optimize="${2:-}"; shift 2 ;;
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

zig="${root_dir}/.tools/zig-0.15.2/zig"

echo "[profile] fetching deps" >&2
"${zig}" build --fetch

echo "[profile] building (windows)" >&2
"${zig}" build -Dtarget=x86_64-windows-gnu -Doptimize="${optimize}" -Denable_ztracy=true -Dtracy_on_demand=true

exe="${root_dir}/zig-out/bin/ziggystarclaw-client.exe"
if [[ ! -f "${exe}" ]]; then
  echo "[profile] expected exe missing: ${exe}" >&2
  exit 1
fi

echo "[profile] done: ${exe}" >&2

