#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BUILD=1
SKIP_WASM=0
VERSION_OVERRIDE=""
DATE_OVERRIDE=""

for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --skip-wasm) SKIP_WASM=1 ;;
    --version=*) VERSION_OVERRIDE="${arg#*=}" ;;
    --date=*) DATE_OVERRIDE="${arg#*=}" ;;
    -h|--help)
      cat <<'USAGE'
Usage: scripts/package-release.sh [--no-build] [--skip-wasm] [--version=X.Y.Z] [--date=YYYYMMDD]

Builds all targets and produces release bundles under dist/.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ -n "${VERSION_OVERRIDE}" ]]; then
  VERSION="${VERSION_OVERRIDE}"
else
  VERSION="$(python3 - <<PY
import re, pathlib
data = pathlib.Path("${ROOT_DIR}/build.zig.zon").read_text(encoding="utf-8")
m = re.search(r'\\.version\\s*=\\s*\"([^\"]+)\"', data)
if not m:
    raise SystemExit("Could not parse version from build.zig.zon")
print(m.group(1))
PY
)"
fi

if [[ -n "${DATE_OVERRIDE}" ]]; then
  DATE="${DATE_OVERRIDE}"
else
  DATE="$(date +%Y%m%d)"
fi

DIST_DIR="${ROOT_DIR}/dist/ziggystarclaw_${VERSION}_${DATE}"
mkdir -p "${DIST_DIR}"

if [[ "${BUILD}" -eq 1 ]]; then
  echo "[release] building native"
  "${ROOT_DIR}/.tools/zig-0.15.2/zig" build

  echo "[release] building windows"
  "${ROOT_DIR}/.tools/zig-0.15.2/zig" build -Dtarget=x86_64-windows-gnu

  if [[ "${SKIP_WASM}" -eq 0 ]]; then
    if [[ -f "${ROOT_DIR}/scripts/emsdk-env.sh" ]]; then
      echo "[release] building wasm"
      # shellcheck disable=SC1091
      source "${ROOT_DIR}/scripts/emsdk-env.sh"
      "${ROOT_DIR}/.tools/zig-0.15.2/zig" build -Dwasm=true
    else
      echo "[release] skipping wasm (emsdk env missing)"
    fi
  fi

  echo "[release] building android"
  "${ROOT_DIR}/.tools/zig-0.15.2/zig" build -Dandroid=true
fi

LINUX_DIR="${DIST_DIR}/linux"
WINDOWS_DIR="${DIST_DIR}/windows"
ANDROID_DIR="${DIST_DIR}/android"
WASM_DIR="${DIST_DIR}/wasm"
CLI_LINUX_DIR="${DIST_DIR}/cli-linux"
CLI_WINDOWS_DIR="${DIST_DIR}/cli-windows"
SYMBOLS_DIR="${DIST_DIR}/symbols"

mkdir -p "${LINUX_DIR}" "${WINDOWS_DIR}" "${ANDROID_DIR}" "${WASM_DIR}" "${CLI_LINUX_DIR}" "${CLI_WINDOWS_DIR}" "${SYMBOLS_DIR}"

copy_or_fail() {
  local src="$1"
  local dst="$2"
  if [[ ! -f "${src}" ]]; then
    echo "[release] missing file: ${src}" >&2
    exit 1
  fi
  cp "${src}" "${dst}"
}

copy_or_fail "${ROOT_DIR}/README.md" "${LINUX_DIR}/README.md"
copy_or_fail "${ROOT_DIR}/LICENSE" "${LINUX_DIR}/LICENSE"
copy_or_fail "${ROOT_DIR}/zig-out/bin/ziggystarclaw-client" "${LINUX_DIR}/"
if [[ -f "${ROOT_DIR}/zig-out/bin/ziggystarclaw-cli" ]]; then
  cp "${ROOT_DIR}/zig-out/bin/ziggystarclaw-cli" "${LINUX_DIR}/"
fi

copy_or_fail "${ROOT_DIR}/README.md" "${CLI_LINUX_DIR}/README.md"
copy_or_fail "${ROOT_DIR}/LICENSE" "${CLI_LINUX_DIR}/LICENSE"
if [[ -f "${ROOT_DIR}/zig-out/bin/ziggystarclaw-cli" ]]; then
  cp "${ROOT_DIR}/zig-out/bin/ziggystarclaw-cli" "${CLI_LINUX_DIR}/"
fi

copy_or_fail "${ROOT_DIR}/README.md" "${WINDOWS_DIR}/README.md"
copy_or_fail "${ROOT_DIR}/LICENSE" "${WINDOWS_DIR}/LICENSE"
copy_or_fail "${ROOT_DIR}/zig-out/bin/ziggystarclaw-client.exe" "${WINDOWS_DIR}/"
if [[ -f "${ROOT_DIR}/zig-out/bin/ziggystarclaw-cli.exe" ]]; then
  cp "${ROOT_DIR}/zig-out/bin/ziggystarclaw-cli.exe" "${WINDOWS_DIR}/"
fi
if [[ -f "${ROOT_DIR}/zig-out/bin/ziggystarclaw-client.pdb" ]]; then
  cp "${ROOT_DIR}/zig-out/bin/ziggystarclaw-client.pdb" "${SYMBOLS_DIR}/"
fi
if [[ -f "${ROOT_DIR}/zig-out/bin/ziggystarclaw-cli.pdb" ]]; then
  cp "${ROOT_DIR}/zig-out/bin/ziggystarclaw-cli.pdb" "${SYMBOLS_DIR}/"
fi

copy_or_fail "${ROOT_DIR}/README.md" "${CLI_WINDOWS_DIR}/README.md"
copy_or_fail "${ROOT_DIR}/LICENSE" "${CLI_WINDOWS_DIR}/LICENSE"
if [[ -f "${ROOT_DIR}/zig-out/bin/ziggystarclaw-cli.exe" ]]; then
  cp "${ROOT_DIR}/zig-out/bin/ziggystarclaw-cli.exe" "${CLI_WINDOWS_DIR}/"
fi

copy_or_fail "${ROOT_DIR}/zig-out/bin/ziggystarclaw_android.apk" "${ANDROID_DIR}/"

copy_or_fail "${ROOT_DIR}/README.md" "${WASM_DIR}/README.md"
copy_or_fail "${ROOT_DIR}/zig-out/web/ziggystarclaw-client.html" "${WASM_DIR}/"
copy_or_fail "${ROOT_DIR}/zig-out/web/ziggystarclaw-client.js" "${WASM_DIR}/"
copy_or_fail "${ROOT_DIR}/zig-out/web/ziggystarclaw-client.wasm" "${WASM_DIR}/"
if [[ -f "${ROOT_DIR}/zig-out/web/ziggystarclaw-client.wasm.map" ]]; then
  cp "${ROOT_DIR}/zig-out/web/ziggystarclaw-client.wasm.map" "${WASM_DIR}/"
fi
if [[ -f "${ROOT_DIR}/zig-out/web/shell.html" ]]; then
  cp "${ROOT_DIR}/zig-out/web/shell.html" "${WASM_DIR}/"
fi
if [[ -d "${ROOT_DIR}/zig-out/web/icons" ]]; then
  mkdir -p "${WASM_DIR}/icons"
  cp "${ROOT_DIR}/zig-out/web/icons/"* "${WASM_DIR}/icons/" || true
fi

python3 - <<PY
import pathlib, zipfile
root = pathlib.Path("${DIST_DIR}")
def zip_dir(src: pathlib.Path, out_name: str):
    out = root / out_name
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in src.rglob("*"):
            if path.is_file():
                zf.write(path, path.relative_to(src.parent))

zip_dir(pathlib.Path("${LINUX_DIR}"), "ziggystarclaw_linux_${VERSION}.zip")
zip_dir(pathlib.Path("${WINDOWS_DIR}"), "ziggystarclaw_windows_${VERSION}.zip")
zip_dir(pathlib.Path("${ANDROID_DIR}"), "ziggystarclaw_android_${VERSION}.zip")
zip_dir(pathlib.Path("${WASM_DIR}"), "ziggystarclaw_wasm_${VERSION}.zip")
zip_dir(pathlib.Path("${CLI_LINUX_DIR}"), "ziggystarclaw_cli_linux_${VERSION}.zip")
zip_dir(pathlib.Path("${CLI_WINDOWS_DIR}"), "ziggystarclaw_cli_windows_${VERSION}.zip")
PY

tar -czf "${DIST_DIR}/ziggystarclaw_linux_${VERSION}.tar.gz" -C "${DIST_DIR}" "linux"
tar -czf "${DIST_DIR}/ziggystarclaw_cli_linux_${VERSION}.tar.gz" -C "${DIST_DIR}" "cli-linux"

(cd "${DIST_DIR}" && sha256sum ziggystarclaw_* > checksums.txt)

python3 - <<PY
import json, pathlib
root = pathlib.Path("${DIST_DIR}")
checksums = {}
with open(root / "checksums.txt", "r", encoding="utf-8") as f:
    for line in f:
        if not line.strip():
            continue
        sha, name = line.strip().split(maxsplit=1)
        checksums[name] = sha

manifest = {
    "version": "${VERSION}",
    "date": "${DATE}",
    "notes": "",
    "release_url": "https://github.com/DeanoC/ZiggyStarClaw/releases/latest",
    "base_url": "https://github.com/DeanoC/ZiggyStarClaw/releases/latest/download/",
    "platforms": {
        "linux": {
            "file": f"ziggystarclaw_linux_${VERSION}.tar.gz",
            "sha256": checksums.get(f"ziggystarclaw_linux_${VERSION}.tar.gz", ""),
        },
        "windows": {
            "file": f"ziggystarclaw_windows_${VERSION}.zip",
            "sha256": checksums.get(f"ziggystarclaw_windows_${VERSION}.zip", ""),
        },
        "android": {
            "file": f"ziggystarclaw_android_${VERSION}.zip",
            "sha256": checksums.get(f"ziggystarclaw_android_${VERSION}.zip", ""),
        },
        "wasm": {
            "file": f"ziggystarclaw_wasm_${VERSION}.zip",
            "sha256": checksums.get(f"ziggystarclaw_wasm_${VERSION}.zip", ""),
        },
    },
}
with open(root / "update.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
PY

echo "[release] bundles written to ${DIST_DIR}"
