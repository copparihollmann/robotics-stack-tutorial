#!/usr/bin/env bash
# Fail early, and legibly, when Vivado is not on PATH.
#
#   . scripts/require_vivado.sh        (sourced from a build script)
#
# Without this the build scripts get all the way past the Verilator gates and then die on
# `vivado: command not found`, which does not tell a reader what to do about it -- and in
# the tutorial container, which deliberately has no Vivado, that is the FIRST thing a new
# user sees. Vivado is licensed and ~100 GB; it is not in the image and cannot be.
if ! command -v vivado >/dev/null 2>&1; then
  cat >&2 <<'MSG'

  vivado is not on PATH -- this step needs it and cannot be containerised.

  Vivado 2023.1 is licensed and roughly 100 GB installed, so it is deliberately absent
  from the tutorial image. Run this step on a host that has it:

      source /path/to/Vivado/2023.1/settings64.sh
      export XILINXD_LICENSE_FILE=<port>@<server>
      scripts/08_gensrc.sh                  # unpack the vendored Chipyard Verilog
      fpga/pynq-z2/scripts/build_all_z1.sh  # (or build_smp_z1.sh)

  You may not need to build at all: both Z1 bitstreams are tracked in this repo
  (fpga/pynq-z2/build_rocket_z1/*.bit, build_rocket_smp_z1/*.bit) precisely so the
  hardware labs can be run without a Vivado licence.

  docs/REPRODUCING.md section 6 has the details, including how to bind-mount an existing
  Vivado installation into the container instead.

MSG
  exit 1
fi
