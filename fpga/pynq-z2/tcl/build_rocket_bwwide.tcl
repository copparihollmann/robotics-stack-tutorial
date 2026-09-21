# The full-feature Rocket SoC + the TileLink bandwidth instrument on a 128-bit TileLink
# system bus (lever 4), one HP port, everything at 34.4828 MHz.  MAGIC 0x5A5A000A.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) bwwide
source [file dirname [info script]]/build_rocket.tcl
