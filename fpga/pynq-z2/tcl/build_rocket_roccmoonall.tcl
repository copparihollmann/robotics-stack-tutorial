# The full-feature Rocket SoC with every measured lever: engine revision 2a, the big core's
# pipelined multiplier, and 0092's skipped clean Release.  MAGIC 0x5A5A0028.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) roccmoonall
source [file dirname [info script]]/build_rocket.tcl
