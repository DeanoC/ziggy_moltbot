#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/worktree-new.sh <branch> [base]

Creates a new local branch and a matching git worktree under:
  <repo>/worktrees/<branch>

Examples:
  scripts/worktree-new.sh feature/my_task
  scripts/worktree-new.sh bugfix/crash origin/main

Environment:
  ZSC_WORKTREES_DIR: override the default <repo>/worktrees output directory.

Notes:
  - This repo uses a shared git dir at <repo>/.repo, so this script derives the
    worktrees directory from `git rev-parse --git-common-dir`.
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

branch="$1"
base="${2:-main}"

if [[ "${branch}" == "-"* ]]; then
  echo "error: branch must not start with '-': ${branch}" >&2
  exit 2
fi
if [[ "${branch}" == /* || "${branch}" == *".."* ]]; then
  echo "error: branch looks unsafe: ${branch}" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git worktree" >&2
  exit 1
}
common_dir="$(git rev-parse --git-common-dir)"
repo_dir="$(cd "$(dirname "${common_dir}")" && pwd)"
worktrees_dir="${ZSC_WORKTREES_DIR:-${repo_dir}/worktrees}"
worktree_path="${worktrees_dir}/${branch}"

if ! git -C "${repo_root}" rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
  echo "error: base ref does not resolve to a commit: ${base}" >&2
  exit 1
fi

if git -C "${repo_root}" show-ref --verify --quiet "refs/heads/${branch}"; then
  echo "error: branch already exists: ${branch}" >&2
  exit 1
fi

if [[ -e "${worktree_path}" ]]; then
  echo "error: worktree path already exists: ${worktree_path}" >&2
  exit 1
fi

mkdir -p "$(dirname "${worktree_path}")"

echo "Creating worktree:"
echo "  branch: ${branch}"
echo "  base:   ${base}"
echo "  path:   ${worktree_path}"

git -C "${repo_root}" worktree add -b "${branch}" "${worktree_path}" "${base}"

# Link shared toolchain folder into the worktree so pinned Zig/Android tooling works
# regardless of which worktree you're in.
#
# The canonical location for tools is the main repo dir derived from the shared
# git common dir (see notes in usage()).
tools_src="${repo_dir}/.tools"
tools_dst="${worktree_path}/.tools"
if [[ -e "${tools_dst}" ]]; then
  echo "Note: .tools already exists in worktree, leaving it as-is: ${tools_dst}" >&2
else
  if [[ -d "${tools_src}" ]]; then
    ln -s "${tools_src}" "${tools_dst}"
    echo "Linked tools:"
    echo "  ${tools_dst} -> ${tools_src}"
  else
    echo "Warning: tools dir not found, skipping .tools link: ${tools_src}" >&2
  fi
fi

echo
echo "Worktree created:"
echo "  cd \"${worktree_path}\""
