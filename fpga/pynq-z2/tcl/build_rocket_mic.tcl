# The dual-core Rocket + TACIT + MBP P-ext bitstream WITH the PDM microphone peripheral.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) mic
source [file dirname [info script]]/build_rocket.tcl
