# Build the dual-core big.LITTLE Rocket + TACIT bitstream WITH the MBP packed-SIMD
# extension on hart 0.
#
#   vivado -mode batch -source tcl/build_rocket_pext.tcl -tclargs [synth|all]
#
# This is build_rocket.tcl with ROCKET_VARIANT=pext. The structural top, the AXI4->AXI3
# bridge, the XDC and the PS7 preset are all shared unchanged with the other two variants:
# the four MBP ops live inside RocketALU on tile 0, so nothing outside ChipTop can tell.
#
# What DOES differ:
#   * generated-src            -> .../TestHarness.PynqZ2RocketBigLittlePextTacitConfig
#   * build dir / bitstream    -> build_rocket_pext_<board>/pynq<board>_rocket_pext.bit
#   * SOC_MAGIC                -> 0x5A5A0004. The bitstreams are pin- and register-
#                                 compatible, so without this the dual-core image boots
#                                 happily on the P-ext PL and vice versa, and the MBP
#                                 kernels take an illegal-instruction trap on a core that
#                                 was supposed to have the extension. DUAL_CORE.md records
#                                 why this guard exists.
#   * the CLOCK                -> 35 MHz requested, 34.4828 MHz delivered. The 40 MHz the
#                                 other two variants use is 3.53 ns short of what the
#                                 QMUL/DOT8 EX stage needs. See build_rocket.tcl's
#                                 ROCKET_VARIANT note for why 35 is not 35.
#
# See docs/PEXT_SPEC.md for the instruction set and docs/PEXT_FEASIBILITY.md section 2.6
# for the measured EX-stage cost this clock is paying for.
set ::env(ROCKET_VARIANT) pext
source [file dirname [info script]]/build_rocket.tcl
