#!/usr/bin/env bash
# Build the tutorial's container image.
#
#   scripts/docker/build.sh [--tag NAME] [docker-build-args...]
#
# The image is tagged iiswc-tutorial:latest by default and is built with the invoking
# user's uid/gid so that anything written into the bind-mounted repo stays owned by you.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${IISWC_IMAGE:-iiswc-tutorial:latest}"
if [ "${1-}" = "--tag" ]; then TAG="${2:?--tag needs a value}"; shift 2; fi
command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }
echo "==> building $TAG  (uid=$(id -u) gid=$(id -g))"
exec docker build \
  --build-arg "UID=$(id -u)" \
  --build-arg "GID=$(id -g)" \
  --build-arg "USERNAME=$(id -un)" \
  -t "$TAG" -f "$ROOT/Dockerfile" "$@" "$ROOT"
