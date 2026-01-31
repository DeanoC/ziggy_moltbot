#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zig_path="${root_dir}/.tools/zig-0.15.2/zig"

if [[ ! -x "${zig_path}" ]]; then
  echo "[tools] Zig not found at ${zig_path}" >&2
  echo "[tools] Current working dir: $(pwd)" >&2
  echo "[tools] Repo root: ${root_dir}" >&2
  echo "[tools] Hint: run from the repo root or a worktree with .tools linked." >&2
  exit 1
fi

if [[ "$(pwd)" != "${root_dir}" ]]; then
  echo "[tools] Warning: running from $(pwd)" >&2
  echo "[tools] Expected repo root: ${root_dir}" >&2
fi

exit 0
