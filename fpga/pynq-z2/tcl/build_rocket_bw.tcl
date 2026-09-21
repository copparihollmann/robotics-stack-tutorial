# The full-feature Rocket SoC plus a TileLink bandwidth instrument on the system bus:
# rtl_study/rocc/mbxd_dma.v issuing 64-byte Gets with up to eight in flight, behind an
# MMIO control block at 0x100A_0000.  MAGIC 0x5A5A0007.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) bw
source [file dirname [info script]]/build_rocket.tcl
