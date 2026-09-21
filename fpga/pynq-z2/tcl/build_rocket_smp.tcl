# Build the dual-core big.LITTLE Rocket + TACIT bitstream.
#
#   vivado -mode batch -source tcl/build_rocket_smp.tcl -tclargs [synth|all]
#
# This is build_rocket.tcl with ROCKET_VARIANT=smp: same structural top, same AXI4->AXI3
# bridge, same XDC, same PS7 preset. The generated ChipTop's port list is identical
# between PynqZ2RocketTacitConfig and PynqZ2RocketBigLittleTacitConfig, so nothing in the
# PL wrapper has to know there are two harts -- the second core lives entirely inside
# ChipTop, behind the same single AXI4 memory port and the same CLINT.
#
# What DOES differ:
#   * generated-src            -> .../TestHarness.PynqZ2RocketBigLittleTacitConfig
#   * build dir / bitstream    -> build_rocket_smp_<board>/pynq<board>_rocket_smp.bit
#   * SOC_MAGIC                -> 0x5A5A0003, so run_rocket_smp.py can refuse to boot a
#                                 dual-core image against the single-core PL
#
# See docs/DUAL_CORE.md for the measured area and the second hart's boot path.
set ::env(ROCKET_VARIANT) smp
source [file dirname [info script]]/build_rocket.tcl
