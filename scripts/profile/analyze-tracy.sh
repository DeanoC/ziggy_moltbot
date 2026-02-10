#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: scripts/profile/analyze-tracy.sh <file.tracy> [--top N] [--filter SUBSTR] [--self]" >&2
  exit 2
fi

"${root_dir}/scripts/ensure-tools.sh" >/dev/null
"${root_dir}/scripts/tools/ensure-tracy.sh" >/dev/null

exec python3 "${root_dir}/scripts/profile/analyze_tracy.py" "$@"

