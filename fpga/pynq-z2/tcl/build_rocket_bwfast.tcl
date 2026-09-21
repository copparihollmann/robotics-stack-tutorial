# The full-feature Rocket SoC + the TileLink bandwidth instrument, with the MEMORY BUS,
# the AXI4-to-AXI3 shim and S_AXI_HP0 on FCLK1 at 100 MHz while the core stays at
# 34.4828 MHz.  MAGIC 0x5A5A0008.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) bwfast
source [file dirname [info script]]/build_rocket.tcl
