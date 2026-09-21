# ---------------------------------------------------------------------------
# Read-only interrogation of the SHIPPED routed checkpoint.
#
#   vivado -mode batch -source probe_alu_cone.tcl
#
# Two questions the OOC study cannot answer on its own:
#   1. How much setup slack does the EX-stage ALU cone of hart 0 actually have
#      today?  The design's WNS is +0.067 ns but that path is in the L2 MSHR
#      scheduler -- the ALU may have far more room, in which case a slower ALU
#      is affordable.
#   2. How is Rocket's 31x64 2R1W register file physically built?  That is what
#      prices a third read port.
#
# Nothing is written back to the checkpoint.
# ---------------------------------------------------------------------------
set dcp [expr {[info exists ::env(PEXT_DCP)] ? $::env(PEXT_DCP) : \
  "$::env(IISWC_ROOT)/fpga/pynq-z2/build_rocket_smp_z1/post_route.dcp"}]
set outdir [expr {[info exists ::env(PEXT_OUT)] ? $::env(PEXT_OUT) : "/tmp/pext_probe"}]
file mkdir $outdir

open_checkpoint $dcp
puts "PROBE opened $dcp"

# ---- locate the two tiles ------------------------------------------------
set tiles [get_cells -hier -filter {REF_NAME =~ Rocket || REF_NAME =~ Rocket_*}]
puts "PROBE cores: [llength $tiles]"
foreach t $tiles { puts "PROBE core_inst $t (REF=[get_property REF_NAME $t])" }

# ---- 1. the EX-stage ALU cone -------------------------------------------
# alu.io.out is captured into mem_reg_wdata (RocketCore.scala:692); alu.io.cmp_out
# into mem_br_taken (:693); alu.io.adder_out feeds the D$ address (:1205).
foreach pat {mem_reg_wdata_reg mem_br_taken_reg} {
  set eps [get_cells -quiet -hier -filter "NAME =~ *${pat}*"]
  puts "PROBE endpoint_group $pat cells=[llength $eps]"
  if {[llength $eps] == 0} { continue }
  set paths [get_timing_paths -quiet -delay_type max -max_paths 4 -nworst 4 -to $eps]
  foreach p $paths {
    puts [format "PROBE_PATH %s slack=%.3f dpd=%.3f levels=%s from=%s to=%s" \
      $pat [get_property SLACK $p] [get_property DATAPATH_DELAY $p] \
      [get_property LOGIC_LEVELS $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
  }
}

# ---- worst path anywhere inside each core -------------------------------
foreach t $tiles {
  set cells [get_cells -quiet -hier -filter "NAME =~ ${t}/*"]
  set paths [get_timing_paths -quiet -delay_type max -max_paths 3 -nworst 3 -through $cells]
  puts "PROBE core_worst $t n=[llength $paths]"
  foreach p $paths {
    puts [format "PROBE_CORE %s slack=%.3f dpd=%.3f levels=%s from=%s to=%s" \
      $t [get_property SLACK $p] [get_property DATAPATH_DELAY $p] \
      [get_property LOGIC_LEVELS $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
  }
}

# ---- 2. how the integer register file is physically built ---------------
foreach pat {*core/rf* *_rf_* *RegFile*} {
  set rfc [get_cells -quiet -hier -filter "NAME =~ $pat"]
  if {[llength $rfc]} { puts "PROBE rf_match $pat n=[llength $rfc]" }
}
# Rocket's Mem(31,64) becomes distributed RAM; count the primitives per core.
foreach t $tiles {
  array unset cnt
  foreach c [get_cells -quiet -hier -filter "NAME =~ ${t}/* && PRIMITIVE_SUBGROUP == dram"] {
    set r [get_property REF_NAME $c]
    incr cnt($r)
  }
  set tot 0
  foreach r [array names cnt] { incr tot $cnt($r); puts "PROBE dram $t $r = $cnt($r)" }
  puts "PROBE dram_total $t = $tot"
}

report_timing_summary -file $outdir/probe_timing_summary.rpt -max_paths 20
report_utilization -hierarchical -file $outdir/probe_util_hier.rpt
puts "PROBE_DONE"
exit
