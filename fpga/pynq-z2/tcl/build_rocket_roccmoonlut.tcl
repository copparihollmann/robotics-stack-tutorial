# 0x5A5A002A's SoC plus T4's LUT lane (mbxl_lut as lane 4).
# MAGIC 0x5A5A002C.  All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) roccmoonlut
source [file join [file dirname [file normalize [info script]]] build_rocket.tcl]
