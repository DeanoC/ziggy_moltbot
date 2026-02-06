#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

"${root_dir}/scripts/ensure-tools.sh" >/dev/null

zig="${root_dir}/.tools/zig-0.15.2/zig"

if [[ ! -x "${zig}" ]]; then
  echo "[tracy] Zig not found at ${zig}" >&2
  exit 1
fi

# Try to detect the Tracy version used by our ztracy dependency (best-effort).
detect_tracy_version() {
  local zon="${root_dir}/build.zig.zon"
  local ztracy_hash=""
  ztracy_hash="$(awk '
    BEGIN { in=0 }
    /^[[:space:]]*\.ztracy[[:space:]]*=[[:space:]]*\.\\{/ { in=1; next }
    in && /^[[:space:]]*\\.hash[[:space:]]*=/ {
      gsub(/^[^"]*"/, "", $0);
      sub(/".*$/, "", $0);
      print $0;
      exit 0
    }
  ' "${zon}" 2>/dev/null || true)"
  if [[ -z "${ztracy_hash}" ]]; then
    return 1
  fi
  local pkg_dir="${HOME}/.cache/zig/p/${ztracy_hash}"
  if [[ ! -f "${pkg_dir}/libs/tracy/common/TracyVersion.hpp" ]]; then
    return 1
  fi
  python3 - <<'PY' "${pkg_dir}/libs/tracy/common/TracyVersion.hpp"
import re, sys
data = open(sys.argv[1], "r", encoding="utf-8", errors="ignore").read()
maj = re.search(r'enum\\s*\\{\\s*Major\\s*=\\s*(\\d+)\\s*\\s*\\};', data)
min_ = re.search(r'enum\\s*\\{\\s*Minor\\s*=\\s*(\\d+)\\s*\\s*\\};', data)
pat = re.search(r'enum\\s*\\{\\s*Patch\\s*=\\s*(\\d+)\\s*\\s*\\};', data)
if not (maj and min_ and pat):
    sys.exit(1)
print(f"{maj.group(1)}.{min_.group(1)}.{pat.group(1)}")
PY
}

tracy_version="$(detect_tracy_version 2>/dev/null || true)"
if [[ -z "${tracy_version}" ]]; then
  tracy_version="0.13.0"
fi

install_dir="${root_dir}/.tools/tracy/${tracy_version}"
capture_bin="${install_dir}/tracy-capture"
profiler_bin="${install_dir}/tracy-profiler"
csvexport_bin="${install_dir}/tracy-csvexport"

if [[ -x "${capture_bin}" && -x "${csvexport_bin}" ]]; then
  exit 0
fi

mkdir -p "${install_dir}"

uname_s="$(uname -s | tr '[:upper:]' '[:lower:]')"
uname_m="$(uname -m)"

tag="v${tracy_version}"

echo "[tracy] Installing Tracy tools ${tracy_version} into ${install_dir}" >&2

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "${tmp_dir}"; }
trap cleanup EXIT

if [[ "${uname_s}" == "windows"* || "${uname_s}" == "mingw"* || "${uname_s}" == "msys"* || "${uname_s}" == "cygwin"* ]]; then
  # Tracy releases commonly ship Windows binaries. Try to download and extract.
  api_url="https://api.github.com/repos/wolfpld/tracy/releases/tags/${tag}"
  json="$(curl -fsSL "${api_url}")"
  asset_url="$(
    python3 - <<'PY' "${uname_s}" "${uname_m}" "${json}"
import json, sys
uname_s = sys.argv[1]
uname_m = sys.argv[2]
data = json.loads(sys.argv[3])
assets = data.get("assets", [])

def want(name: str) -> bool:
    n = name.lower()
    if not n.endswith(".zip"):
        return False
    return "windows" in n

for a in assets:
    name = a.get("name","")
    if want(name):
        print(a.get("browser_download_url",""))
        sys.exit(0)
sys.exit(2)
PY
  )"
  if [[ -z "${asset_url}" ]]; then
    echo "[tracy] Could not find a suitable Windows release asset for ${tag}." >&2
    exit 1
  fi
  archive="${tmp_dir}/tracy_tools.zip"
  curl -fsSL "${asset_url}" -o "${archive}"
  unzip -q "${archive}" -d "${tmp_dir}/out"
  cap_path="$(find "${tmp_dir}/out" -type f -iname 'tracy-capture*' | head -n 1 || true)"
  prof_path="$(find "${tmp_dir}/out" -type f -iname 'tracy-profiler*' | head -n 1 || true)"
  csv_path="$(find "${tmp_dir}/out" -type f -iname 'tracy-csvexport*' | head -n 1 || true)"
else
  # Linux/macOS: build tracy-capture from source. Releases do not reliably ship binaries.
  if ! command -v cmake >/dev/null 2>&1; then
    echo "[tracy] cmake not found; install cmake or put tracy-capture on PATH." >&2
    exit 1
  fi
  if ! command -v c++ >/dev/null 2>&1 && ! command -v g++ >/dev/null 2>&1 && ! command -v clang++ >/dev/null 2>&1; then
    echo "[tracy] no C++ compiler found; install g++/clang++ or put tracy-capture on PATH." >&2
    exit 1
  fi

  src_url="https://github.com/wolfpld/tracy/archive/refs/tags/${tag}.tar.gz"
  archive="${tmp_dir}/tracy-src.tar.gz"
  curl -fsSL "${src_url}" -o "${archive}"
  mkdir -p "${tmp_dir}/src"
  tar -xzf "${archive}" -C "${tmp_dir}/src" --strip-components=1

  build_one() {
    local subdir="$1"
    local outvar="$2"
    local builddir="${tmp_dir}/build-${subdir}"
    if ! cmake -S "${tmp_dir}/src/${subdir}" -B "${builddir}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DNO_FILESELECTOR=ON \
      -DCURL_USE_OPENSSL=OFF \
      -DCURL_ENABLE_SSL=OFF >/dev/null; then
      echo "[tracy] cmake configure failed for tracy-${subdir} (${tag})." >&2
      exit 1
    fi
    if ! cmake --build "${builddir}" -j >/dev/null; then
      echo "[tracy] cmake build failed for tracy-${subdir} (${tag})." >&2
      echo "[tracy] Hint (Debian/Ubuntu): sudo apt-get install -y build-essential cmake" >&2
      exit 1
    fi
    local p
    p="$(find "${builddir}" -maxdepth 2 -type f -iname "tracy-${subdir}*" | head -n 1 || true)"
    if [[ -z "${p}" ]]; then
      # some builds name the binary after the CMake project
      p="$(find "${builddir}" -maxdepth 2 -type f -iname "tracy-*${subdir}*" | head -n 1 || true)"
    fi
    eval "${outvar}=\"${p}\""
  }

  build_one "capture" cap_path
  build_one "csvexport" csv_path

  prof_path=""
fi

if [[ -z "${cap_path}" ]]; then
  echo "[tracy] tracy-capture not found after install." >&2
  exit 1
fi

cp -f "${cap_path}" "${capture_bin}"
chmod +x "${capture_bin}" || true

if [[ -z "${csv_path}" ]]; then
  echo "[tracy] tracy-csvexport not found after install." >&2
  exit 1
fi
cp -f "${csv_path}" "${csvexport_bin}"
chmod +x "${csvexport_bin}" || true

if [[ -n "${prof_path}" ]]; then
  cp -f "${prof_path}" "${profiler_bin}" || true
  chmod +x "${profiler_bin}" || true
fi

echo "[tracy] Installed: ${capture_bin}" >&2
echo "[tracy] Installed: ${csvexport_bin}" >&2
if [[ -x "${profiler_bin}" ]]; then
  echo "[tracy] Installed: ${profiler_bin}" >&2
fi
