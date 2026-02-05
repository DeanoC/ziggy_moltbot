#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
DOCKERFILE="${REPO_ROOT}/tools/docker/Dockerfile.node-sandbox"
IMAGE_NAME="ziggystarclaw-node-sandbox"

usage() {
  cat <<'USAGE'
Usage: scripts/dev/node_sandbox.sh [--rw] [--] [cli args...]

Runs ZiggyStarClaw CLI node-mode inside a disposable Docker sandbox.

Options:
  --rw     Mount the repo read-write (default is read-only).
  --help   Show this help.

Environment:
  NODE_SANDBOX_IMAGE        Override image tag (default: ziggystarclaw-node-sandbox)
  NODE_SANDBOX_DOCKER_ARGS  Extra docker run args (e.g. "-v $HOME/.config/ziggystarclaw:/config:ro")

Examples:
  scripts/dev/node_sandbox.sh -- --config /repo/config/dev.json --auto-approve-pairing
  NODE_SANDBOX_DOCKER_ARGS="-v $HOME/.config/ziggystarclaw:/config:ro" \
    scripts/dev/node_sandbox.sh -- --config /config/config.json
USAGE
}

rw=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rw)
      rw=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

IMAGE_NAME="${NODE_SANDBOX_IMAGE:-${IMAGE_NAME}}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required but was not found on PATH." >&2
  exit 1
fi

if [ ! -f "${DOCKERFILE}" ]; then
  echo "Dockerfile not found: ${DOCKERFILE}" >&2
  exit 1
fi

mount_mode="ro"
zig_prefix="/tmp/zig-out"
zig_cache="/tmp/zig-cache"
zig_global_cache="/tmp/zig-global-cache"

if [ "${rw}" -eq 1 ]; then
  mount_mode="rw"
  zig_prefix="/repo/zig-out"
  zig_cache="/repo/.zig-cache"
  zig_global_cache="/repo/.zig-cache/global"
fi

extra_args=()
if [ -n "${NODE_SANDBOX_DOCKER_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  extra_args+=(${NODE_SANDBOX_DOCKER_ARGS})
fi

docker build -f "${DOCKERFILE}" -t "${IMAGE_NAME}" "${REPO_ROOT}"

docker run --rm --network=host \
  -v "${REPO_ROOT}:/repo:${mount_mode}" \
  -e ZIG_LOCAL_CACHE_DIR="${zig_cache}" \
  -e ZIG_GLOBAL_CACHE_DIR="${zig_global_cache}" \
  -e ZIG_PREFIX="${zig_prefix}" \
  -w /repo \
  "${extra_args[@]}" \
  "${IMAGE_NAME}" \
  /bin/bash -lc 'set -euo pipefail; mkdir -p "${ZIG_PREFIX}" "${ZIG_LOCAL_CACHE_DIR}" "${ZIG_GLOBAL_CACHE_DIR}"; zig build --prefix "${ZIG_PREFIX}"; exec "${ZIG_PREFIX}/bin/ziggystarclaw-cli" --node-mode "$@"' -- "$@"
