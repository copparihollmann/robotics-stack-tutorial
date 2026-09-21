# ---------------------------------------------------------------------------
# Out-of-context area and timing of the softmax lane (mbxr_smx.v, through mbxr_smx_ooc, which
# registers every port), on the same part, period (28.999 ns = 34.4828 MHz) and
# synth -> opt -> place -> phys_opt -> route flow as ../ooc_roccmoon.tcl and ../ooc_dpw.tcl.
# No MAGIC, no bitstream.  From the repository root:
#
#   scripts/lib/with_lock.sh vivado vivado -mode batch -nojournal -nolog \
#     -source fpga/pynq-z2/rtl_study/roccmoon/smx_lane/ooc_smx.tcl
#
# Env: SMX_OUT   report directory (default archive/rtl_study/roccmoon/smx_lane/ooc_out -- raw
#                reports are not committed; smx_lane/summary.json carries the curated numbers)
#      SMX_ONLY  space-separated subset of the labels below
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../../../../.."]
set outdir [expr {[info exists ::env(SMX_OUT)] ? $::env(SMX_OUT) : "$repo/archive/rtl_study/roccmoon/smx_lane/ooc_out"}]
set period 28.999
set part xc7z020clg400-1
file mkdir $outdir
set rtl [list $here/mbxr_smx.v]
# label       DIV_BPC  RAW  OFW
#   smx_bpc6  the lane as simulated and reported (6 cycles of reciprocal per row)
#   smx_bpc4  the timing fallback: 9 cycles of reciprocal, same throughput for K >= 13
set rows {{smx_bpc6 6 11 3} {smx_bpc4 4 11 3}}
if {[info exists ::env(SMX_ONLY)]} {
  set keep {}
  foreach r $rows { if {[lsearch -exact $::env(SMX_ONLY) [lindex $r 0]] >= 0} { lappend keep $r } }
  set rows $keep
}
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
  # names as plain strings: pin objects print as "null" once the project is closed
  return [list [format %.3f [get_property SLACK $pth]] [format %.3f [get_property DATAPATH_DELAY $pth]] \
               [get_property LOGIC_LEVELS $pth] [format %s [get_property STARTPOINT_PIN $pth]] \
               [format %s [get_property ENDPOINT_PIN $pth]]]
}
set summary {}
foreach r $rows {
  lassign $r label bpc raw ofw
  create_project -in_memory -force -part $part
  read_verilog $rtl
  synth_design -top mbxr_smx_ooc -part $part -mode out_of_context \
    -generic DIV_BPC=$bpc -generic RAW=$raw -generic OFW=$ofw
  create_clock -name clk -period $period [get_ports clk]
  opt_design; place_design -quiet; phys_opt_design -quiet; route_design -quiet
  report_utilization -file $outdir/${label}_util.rpt
  report_utilization -hierarchical -hierarchical_depth 4 -file $outdir/${label}_hier.rpt
  report_timing_summary -max_paths 5 -file $outdir/${label}_timing_summary.rpt
  report_timing -delay_type max -max_paths 10 -nworst 1 -from [all_registers] -to [all_registers] \
    -file $outdir/${label}_timing.rpt
  report_timing -delay_type min -max_paths 5 -nworst 1 -file $outdir/${label}_hold.rpt
  set setup [lindex [get_timing_paths -delay_type max -max_paths 1 -from [all_registers] -to [all_registers]] 0]
  set hold  [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
  set row [list $label [util_row $outdir/${label}_util.rpt "Slice LUTs"] \
             [util_row $outdir/${label}_util.rpt "Slice Registers"] \
             [util_row $outdir/${label}_util.rpt "DSPs"] \
             [util_row $outdir/${label}_util.rpt "Block RAM Tile"] \
             [util_row $outdir/${label}_util.rpt "RAMB36/FIFO"] \
             [util_row $outdir/${label}_util.rpt "RAMB18"] \
             [util_row $outdir/${label}_util.rpt "LUT as Memory"] \
             {*}[path_row $setup] [format %.3f [get_property SLACK $hold]]]
  puts "SMX_RESULT $row"
  lappend summary $row
  # the worst setup path ending in each part of the lane
  set fh [open $outdir/${label}_parts.tsv w]
  puts $fh "part\tslack_ns\tdatapath_ns\tlevels\tstart\tend"
  foreach {grp pat} {divider u/u_div/* element u/u_elem/* control u/*} {
    set cells [get_cells -hierarchical -filter "NAME =~ $pat && IS_SEQUENTIAL"]
    if {$grp eq "control"} {
      set cells [get_cells -hierarchical -filter {NAME =~ u/* && NAME !~ u/u_div/* && NAME !~ u/u_elem/* && IS_SEQUENTIAL}]
    }
    set p [lindex [get_timing_paths -delay_type max -max_paths 1 -to $cells] 0]
    puts $fh "$grp\t[join [path_row $p] \t]"
    puts "SMX_PART $label $grp [path_row $p]"
  }
  close $fh
  close_project
}
set fh [open $outdir/summary.tsv w]
puts $fh "label\tlut\tff\tdsp\tbram_tile\tramb36\tramb18\tlut_mem\tslack_ns\tdatapath_ns\tlevels\tstart\tend\twhs_ns"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "SMX_ALL_DONE"
exit
