# ---------------------------------------------------------------------------
# Out-of-context area and timing of T4's LUT lane (mbxl_lut.v, through mbxl_lut_ooc, which
# registers every port) and of the generation tag (mbxl_gtag), on the same part, period
# (28.999 ns = 34.4828 MHz) and synth -> opt -> place -> phys_opt -> route flow as
# ../ooc_roccmoon.tcl, ../ln_lane/ooc_ln.tcl and ../smx_lane/ooc_smx.tcl.
# No MAGIC, no bitstream.  From the repo root:
#
#   scripts/lib/with_lock.sh vivado vivado -mode batch -nojournal -nolog \
#     -source fpga/pynq-z2/rtl_study/roccmoon/lut_lane/ooc_lut.tcl
#
# NOT -quiet on opt_design, deliberately: -quiet suppressed DRC MDRV-1 on the LayerNorm
# lane's first run and a multiple-driver net reached a full build (LAYERNORM_LANE.md s15).
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../../../../.."]
set outdir [expr {[info exists ::env(LUT_OUT)] ? $::env(LUT_OUT) : "$repo/archive/rtl_study/roccmoon/lut_lane/ooc_out"}]
set period 28.999
set part xc7z020clg400-1
file mkdir $outdir
set rtl [list $here/mbxl_lut.v]
# label      top
set rows {{lut_lane mbxl_lut_ooc} {gtag mbxl_gtag}}
set_msg_config -id {Synth 8-3848} -new_severity ERROR
proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9.\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return 0
}
proc path_row {pth} {
  if {$pth eq ""} { return [list NA NA NA NA NA] }
  return [list [format %.3f [get_property SLACK $pth]] [format %.3f [get_property DATAPATH_DELAY $pth]] \
               [get_property LOGIC_LEVELS $pth] [format %s [get_property STARTPOINT_PIN $pth]] \
               [format %s [get_property ENDPOINT_PIN $pth]]]
}
set summary {}
foreach r $rows {
  lassign $r label top
  create_project -in_memory -force -part $part
  read_verilog $rtl
  synth_design -top $top -part $part -mode out_of_context
  create_clock -name clk -period $period [get_ports clk]
  opt_design; place_design -quiet; phys_opt_design -quiet; route_design -quiet
  report_utilization -file $outdir/${label}_util.rpt
  report_utilization -hierarchical -hierarchical_depth 4 -file $outdir/${label}_hier.rpt
  report_timing_summary -max_paths 5 -file $outdir/${label}_timing_summary.rpt
  report_timing -delay_type max -max_paths 20 -nworst 1 -from [all_registers] -to [all_registers] \
    -file $outdir/${label}_timing.rpt
  set setup [lindex [get_timing_paths -delay_type max -max_paths 1 -from [all_registers] -to [all_registers]] 0]
  set hold  [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
  set row [list $label [util_row $outdir/${label}_util.rpt "Slice LUTs"] \
             [util_row $outdir/${label}_util.rpt "Slice Registers"] \
             [util_row $outdir/${label}_util.rpt "DSPs"] \
             [util_row $outdir/${label}_util.rpt "Block RAM Tile"] \
             [util_row $outdir/${label}_util.rpt "LUT as Memory"] \
             [util_row $outdir/${label}_util.rpt "LUT as Logic"] \
             {*}[path_row $setup] [format %.3f [get_property SLACK $hold]]]
  puts "LUT_RESULT $row"
  lappend summary $row
  # ---- the regression assertion this lane exists to carry --------------------------------
  # The first implementation was FUNCTIONALLY PERFECT and 27x too big: a three-dimensional
  # table array inferred no distributed RAM and synthesised as logic -- 10,588 LUT with
  # `LUT as Memory` = 0, while 73,936 byte checks passed.  No amount of stimulus finds that;
  # only the utilisation report does.  So the report is now read, not just written.
  # (Suggested by the LayerNorm workstream after the same shape cost it an unconnected port.)
  if {$label eq "lut_lane"} {
    set lutmem [util_row $outdir/${label}_util.rpt "LUT as Memory"]
    if {$lutmem <= 0} {
      error "LUT_ASSERT_FAIL: LUT as Memory = $lutmem. The table is not inferring as\
             distributed RAM -- see mbxl_lut.v's header.  Area is meaningless until it does."
    }
    puts "LUT_ASSERT_OK LUT-as-Memory=$lutmem"
  }
  close_project
}
set fh [open $outdir/summary.tsv w]
puts $fh "label\tlut\tff\tdsp\tbram_tile\tlut_mem\tlut_logic\tslack_ns\tdatapath_ns\tlevels\tstart\tend\twhs_ns"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "LUT_ALL_DONE"
exit
