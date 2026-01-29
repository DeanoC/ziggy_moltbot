#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
web_dir="${root_dir}/zig-out/web"
port="${1:-8080}"

if [[ ! -d "${web_dir}" ]]; then
  echo "Web output not found at ${web_dir}"
  echo "Run: ./.tools/zig-0.15.2/zig build -Dwasm"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to run the static server."
  exit 1
fi

echo "Serving ${web_dir} at http://localhost:${port}"
echo "Press Ctrl+C to stop."
cd "${web_dir}"
python3 -m http.server "${port}"
