# Engine revision 2b: 0x5A5A0028 plus the weight lane on S_AXI_HP2 at FCLK1 (MEMORY_BANDWIDTH.md
# sections 9.9 and 9.10).  MAGIC 0x5A5A0013.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) roccmoon2b
source [file dirname [info script]]/build_rocket.tcl
