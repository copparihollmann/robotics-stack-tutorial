#!/usr/bin/env bash
# Run a command inside the tutorial container with this checkout bind-mounted.
#
#   scripts/docker/run.sh                          interactive shell
#   scripts/docker/run.sh scripts/01_doctor.sh     one command
#   scripts/docker/run.sh bash -lc 'source env.sh && west build ...'
#
# THE CHECKOUT IS MOUNTED AT ITS OWN ABSOLUTE PATH, not at /work, and that is
# deliberate. scripts/00_bootstrap.sh installs a conda env into the checkout, and conda
# bakes absolute prefixes into every entry point -- the shebang of
# tools/miniforge3/envs/zephyr/bin/west is a literal path to that env's python. Mount the
# repo somewhere else and the env you bootstrapped in the container is unusable on the
# host, and vice versa:
#
#     $ head -1 .../envs/zephyr/bin/west
#     #!/work/zephyr-chipyard-sw/tools/miniforge3/envs/zephyr/bin/python3.12
#     $ .../envs/zephyr/bin/west --version
#     cannot execute: required file not found
#
# Same path inside and out, and one bootstrap serves both routes. Set IISWC_MOUNT to
# override (e.g. IISWC_MOUNT=/work for a deliberately path-independent run).
#
# The mount is read-WRITE: the bootstrap installs conda, the Zephyr SDK and the west
# modules into zephyr-chipyard-sw/, and those must persist between runs. Set IISWC_IMAGE
# to use a different tag; pass extra `docker run` flags in IISWC_DOCKER_ARGS.
#
# Vivado is deliberately absent -- see docs/REPRODUCING.md §6 for the bitstream flow.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MOUNT="${IISWC_MOUNT:-$ROOT}"
IMAGE="${IISWC_IMAGE:-iiswc-tutorial:latest}"
command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || { echo "image $IMAGE not built -- run scripts/docker/build.sh" >&2; exit 1; }

tty_args=()
[ -t 0 ] && tty_args=(-it)
# shellcheck disable=SC2206
extra=(${IISWC_DOCKER_ARGS:-})

exec docker run --rm "${tty_args[@]}" \
  -v "$ROOT:$MOUNT" \
  -w "$MOUNT" \
  -e "TERM=${TERM:-xterm}" \
  "${extra[@]}" \
  "$IMAGE" \
  "${@:-bash}"
