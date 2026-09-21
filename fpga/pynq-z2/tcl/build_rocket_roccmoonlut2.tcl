# 0x5A5A002C's SoC with mbxl_lut's out_valid pulsed instead of held (T4_LANES.md s11).
# MAGIC 0x5A5A002D.  All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) roccmoonlut2
source [file join [file dirname [file normalize [info script]]] build_rocket.tcl]
