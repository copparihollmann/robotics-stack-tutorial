# 0x5A5A002E's SoC with the engine's 6-bit weight unpacker (rtl_study/roccmoon/INT6_WEIGHTS.md).
# MAGIC 0x5A5A002F.  All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) roccmoonint6
source [file join [file dirname [file normalize [info script]]] build_rocket.tcl]
