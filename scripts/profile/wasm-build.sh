#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

"${root_dir}/scripts/ensure-tools.sh" >/dev/null

zig="${root_dir}/.tools/zig-0.15.2/zig"

if [[ ! -f "${root_dir}/scripts/emsdk-env.sh" ]]; then
  echo "[profile] emsdk env script not found: ${root_dir}/scripts/emsdk-env.sh" >&2
  exit 1
fi

echo "[profile] fetching deps" >&2
"${zig}" build --fetch

echo "[profile] building (wasm) with perf markers" >&2
source "${root_dir}/scripts/emsdk-env.sh"
"${zig}" build -Dwasm=true -Denable_wasm_perf_markers=true

echo "[profile] outputs in zig-out/web/ (serve via scripts/serve-web.sh)" >&2

