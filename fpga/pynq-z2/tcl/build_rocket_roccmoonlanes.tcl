# 0x5A5A0028 plus the two lanes inside the engine: mbxa_core (attention) and mbxr_ln
# (LayerNorm/GroupNorm), sharing the engine's scratchpad, MAC array and drain.
# MAGIC 0x5A5A0029.  All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) roccmoonlanes
source [file dirname [info script]]/build_rocket.tcl
