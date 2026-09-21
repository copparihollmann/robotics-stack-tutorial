# The full-feature Rocket SoC + the TileLink bandwidth instrument on a 256-bit TileLink
# system bus (lever 4's second point), one HP port, everything at 34.4828 MHz.
# MAGIC 0x5A5A000F.  All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) bwwide256
source [file dirname [info script]]/build_rocket.tcl
