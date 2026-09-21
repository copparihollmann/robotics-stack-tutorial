# Reproducible build environment for the IISWC TACIT tutorial.
#
#   scripts/docker/build.sh          build the image
#   scripts/docker/run.sh <cmd...>   run a command inside it with the repo mounted at /work
#
# WHAT IS IN HERE, AND WHY IT IS THIS SMALL
#
# The image carries only what apt and rustup can give us: compilers, Verilator, the
# libraries spike needs, and a Rust toolchain. Everything else -- conda, the Zephyr SDK,
# the west module trees -- is installed by scripts/00_bootstrap.sh INTO THE REPO, which is
# bind-mounted. That keeps the image ~1.5 GB instead of ~15 GB, and it means the expensive
# bootstrap survives `docker rm` and is shared with a host-native checkout.
#
# WHAT IS NOT IN HERE
#
#   * Vivado. It is licensed and ~100 GB; it cannot be redistributed in an image. Bitstream
#     builds run on a host that has it -- see docs/REPRODUCING.md.
#   * The PYNQ board. Nothing in this image touches hardware.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
# Pinned rather than "stable" so the decoder builds against a known-good compiler. Bump
# deliberately; the tutorial's golden numbers do not depend on it, but build errors do.
ARG RUST_VERSION=1.97.1
# The image creates a user with the invoking host's uid/gid so that files written into the
# bind-mounted repo are owned by the caller, not by root. scripts/docker/build.sh passes
# these automatically.
ARG UID=1000
ARG GID=1000
ARG USERNAME=builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git openssh-client \
      build-essential autoconf automake libtool pkg-config \
      cmake ninja-build \
      python3 python3-venv python3-dev \
      device-tree-compiler \
      libboost-dev libboost-regex-dev libboost-system-dev \
      zlib1g-dev libssl-dev libffi-dev \
      verilator \
      xz-utils bzip2 unzip file bc rsync procps less \
    && rm -rf /var/lib/apt/lists/*

# Rust, for third_party/tacit-decoder. Installed system-wide so any uid can use it.
ENV RUSTUP_HOME=/opt/rust \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:$PATH
RUN curl -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "${RUST_VERSION}" \
 && chmod -R a+rX,a+w /opt/cargo

# zephyr-chipyard-sw's nested `modelblaster` submodule is declared with an SSH URL
# (git@github.com:ucb-bar/ModelBlaster.git) and a container has no SSH key. The repo is
# public over https, so rewrite the scheme rather than mounting a key. Harmless for repos
# that were already https.
RUN git config --system url."https://github.com/".insteadOf "git@github.com:" \
 && git config --system url."https://github.com/".insteadOf "ssh://git@github.com/" \
 && git config --system --add safe.directory '*' \
 && git config --system advice.detachedHead false

# Match the host uid/gid so bind-mounted writes are owned by the caller. If the uid is
# already taken by a stock account (ubuntu owns 1000 on 24.04), reuse it.
RUN if getent group "${GID}" >/dev/null; then \
      groupmod -n "${USERNAME}" "$(getent group "${GID}" | cut -d: -f1)"; \
    else groupadd -g "${GID}" "${USERNAME}"; fi \
 && if getent passwd "${UID}" >/dev/null; then \
      usermod -l "${USERNAME}" -g "${GID}" -d /home/"${USERNAME}" -m "$(getent passwd "${UID}" | cut -d: -f1)"; \
    else useradd -u "${UID}" -g "${GID}" -m -s /bin/bash "${USERNAME}"; fi \
 && mkdir -p /work && chown "${UID}:${GID}" /work

USER ${UID}:${GID}
ENV HOME=/home/${USERNAME}
WORKDIR /work
CMD ["/bin/bash"]
