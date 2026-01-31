#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <branch-or-folder>" >&2
  exit 2
fi

target="$1"

git worktree list --porcelain | awk -v target="$target" '
  function endswith(str, suffix) {
    return length(str) >= length(suffix) && substr(str, length(str) - length(suffix) + 1) == suffix
  }
  function flush() {
    if (path == "") return;
    if (branch == target || path == target || endswith(path, "/" target)) {
      print path;
      exit 0;
    }
    path = ""; branch = "";
  }
  /^worktree / { path = $2; next }
  /^branch / { branch = $2; sub("^refs/heads/", "", branch); next }
  /^detached/ { branch = "(detached)"; next }
  /^$/ { flush(); next }
  END { flush(); exit 1 }
'
