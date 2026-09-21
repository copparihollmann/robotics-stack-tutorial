# The full-feature Rocket SoC + the TileLink bandwidth instrument with TWO memory
# channels, into S_AXI_HP0 and S_AXI_HP1, both at the core clock.  MAGIC 0x5A5A0009.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) bwports
source [file dirname [info script]]/build_rocket.tcl
