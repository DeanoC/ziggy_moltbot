#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# This repo uses a shared git dir at <repo>/.repo; worktrees live under <repo>/worktrees/*.
# Ensure each worktree has a `.tools` link pointing at the shared `<repo>/.tools`.
common_dir="$(git -C "${root_dir}" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "${common_dir}" ]]; then
  repo_dir="$(cd "$(dirname "${common_dir}")" && pwd)"
  shared_tools="${repo_dir}/.tools"
  if [[ ! -e "${root_dir}/.tools" && -d "${shared_tools}" ]]; then
    ln -s "${shared_tools}" "${root_dir}/.tools"
  fi
fi

zig_path="${root_dir}/.tools/zig-0.15.2/zig"

if [[ ! -x "${zig_path}" ]]; then
  echo "[tools] Zig not found at ${zig_path}" >&2
  echo "[tools] Current working dir: $(pwd)" >&2
  echo "[tools] Repo root: ${root_dir}" >&2
  echo "[tools] Hint: ensure ${root_dir}/.tools links to the shared <repo>/.tools directory." >&2
  exit 1
fi

if [[ "$(pwd)" != "${root_dir}" ]]; then
  echo "[tools] Warning: running from $(pwd)" >&2
  echo "[tools] Expected repo root: ${root_dir}" >&2
fi

exit 0
