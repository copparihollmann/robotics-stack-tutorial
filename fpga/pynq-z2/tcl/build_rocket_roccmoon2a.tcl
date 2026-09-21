# The full-feature Rocket SoC plus engine revision 2a (rtl_study/roccmoon/mbxr_engine.v) as a
# RoCC on hart 1.  MAGIC 0x5A5A0012.  ROCC_DECOUPLED.md section 8.15.5.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) roccmoon2a
source [file dirname [info script]]/build_rocket.tcl
