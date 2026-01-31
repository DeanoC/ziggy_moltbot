#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ensure a usable python is on PATH for emsdk when running under MSYS/Git Bash.
if [[ -d "${ROOT_DIR}/.tools/emsdk/python" ]]; then
  PY_SUBDIR="$(ls -1 "${ROOT_DIR}/.tools/emsdk/python" | head -n 1)"
  if [[ -n "${PY_SUBDIR}" ]]; then
    PY_DIR="${ROOT_DIR}/.tools/emsdk/python/${PY_SUBDIR}"
    if command -v cygpath >/dev/null 2>&1; then
      PY_DIR="$(cygpath -u "${PY_DIR}")"
    fi
    if [[ -f "${PY_DIR}/python.exe" ]]; then
      export EMSDK_PYTHON="${PY_DIR}/python.exe"
    fi
    export PATH="${PY_DIR}:${PATH}"
  fi
fi
source "${ROOT_DIR}/.tools/emsdk/emsdk_env.sh" >/dev/null 2>&1

# Ensure EMSDK_PYTHON uses a Windows path so emcc.bat can launch it.
if [[ -n "${EMSDK_PYTHON-}" ]]; then
  if command -v wslpath >/dev/null 2>&1; then
    EMSDK_PYTHON="$(wslpath -w "${EMSDK_PYTHON}")"
    export EMSDK_PYTHON
  elif command -v cygpath >/dev/null 2>&1; then
    EMSDK_PYTHON="$(cygpath -w "${EMSDK_PYTHON}")"
    export EMSDK_PYTHON
  fi
fi

# Print a short status when run directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "emsdk env loaded from ${ROOT_DIR}/.tools/emsdk"
  emcc -v | head -n 1
fi
