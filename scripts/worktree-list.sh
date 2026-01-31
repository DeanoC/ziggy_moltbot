#!/usr/bin/env bash
set -euo pipefail

git worktree list --porcelain | awk '
  function flush() {
    if (path != "") {
      if (branch == "") branch = "(detached)";
      printf "%-28s %s\n", branch, path;
    }
    path = ""; branch = "";
  }
  /^worktree / { path = $2; next }
  /^branch / {
    branch = $2; sub("^refs/heads/", "", branch); next
  }
  /^detached/ { branch = "(detached)"; next }
  /^$/ { flush(); next }
  END { flush() }
'
