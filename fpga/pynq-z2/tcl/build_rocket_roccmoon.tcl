# The full-feature Rocket SoC plus the decoupled accelerator (rtl_study/roccmoon/mbxr_engine.v)
# as a RoCC on hart 1.  MAGIC 0x5A5A0010.  ROCC_DECOUPLED.md section 8.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) roccmoon
source [file dirname [info script]]/build_rocket.tcl
