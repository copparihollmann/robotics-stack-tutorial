# `roccmoon` plus the HM01B0 camera on the Z1 shield: ospi capture with DMA, a TLI2C, the shield's
# pins (src/pynqz2_cam.xdc), and engine revision 1 from the src/cam_engine_rev1 snapshot.
# MAGIC 0x5A5A001E.  docs/CAMERA_Z1.md.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) roccmooncam
source [file dirname [info script]]/build_rocket.tcl
