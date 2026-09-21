# `roccmoon` plus the big core's pipelined multiplier (MulDivParams.mulUnroll = 64 on hart 0).
# MAGIC 0x5A5A0011.  ROCC_DECOUPLED.md section 8.15.3.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) roccmoonmul
source [file dirname [info script]]/build_rocket.tcl
