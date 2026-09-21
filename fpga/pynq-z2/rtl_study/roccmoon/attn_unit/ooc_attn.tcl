# ---------------------------------------------------------------------------
# Out-of-context area and timing of the attention unit, on the same part, period
# (28.999 ns = 34.4828 MHz) and synth -> opt -> place -> phys_opt -> route flow as
# ../ooc_roccmoon.tcl and ../smx_lane/ooc_smx.tcl.  No MAGIC, no bitstream.
# From the repository root:
#
#   scripts/lib/with_lock.sh vivado vivado -mode batch -nojournal -nolog \
#     -source fpga/pynq-z2/rtl_study/roccmoon/attn_unit/ooc_attn.tcl
#
# Env: ATTN_OUT   report directory (default archive/rtl_study/roccmoon/attn_unit/ooc_out --
#                 raw reports are not committed; attn_unit/summary.json carries the curated
#                 numbers)
#      ATTN_ONLY  space-separated subset of the labels below
#
# attn_core is the figure that answers ROCC_DECOUPLED.md s8.14: what the unit ADDS to
# mbxr_engine.  attn_unit adds mbxr_mac, which the engine already has, and is a sanity check
# on the array's share rather than an area claim.
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../../../../.."]
set outdir [expr {[info exists ::env(ATTN_OUT)] ? $::env(ATTN_OUT) : "$repo/archive/rtl_study/roccmoon/attn_unit/ooc_out"}]
set period 28.999
set part xc7z020clg400-1
file mkdir $outdir
set rtl_core [list $here/mbxa_rq.v $here/mbxa_unit.v $here/../smx_lane/mbxr_smx.v]
set rtl_unit [concat $rtl_core [list $here/../mbxr_datapath.v $here/../../rocc/mbx_mac.v]]
# label            top             DIV_BPC  rtl
#   attn_core      what the unit adds to the engine, DIV_BPC = 6 as simulated
#   attn_core_bpc4 the timing fallback: 9 cycles of reciprocal, same throughput
#   attn_unit      the same plus mbxr_mac (32 DSP), for the array's share
set rows {}
lappend rows [list attn_core      mbxa_core_ooc 6 core]
lappend rows [list attn_core_bpc4 mbxa_core_ooc 4 core]
lappend rows [list attn_unit      mbxa_unit_ooc 6 unit]
if {[info exists ::env(ATTN_ONLY)]} {
  set keep {}
  foreach r $rows { if {[lsearch -exact $::env(ATTN_ONLY) [lindex $r 0]] >= 0} { lappend keep $r } }
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
  return [list [format %.3f [get_property SLACK $pth]] [format %.3f [get_property DATAPATH_DELAY $pth]] \
               [get_property LOGIC_LEVELS $pth] [format %s [get_property STARTPOINT_PIN $pth]] \
               [format %s [get_property ENDPOINT_PIN $pth]]]
}
set summary {}
foreach r $rows {
  lassign $r label top bpc which
  set rtl [expr {$which eq "unit" ? $::rtl_unit : $::rtl_core}]
  create_project -in_memory -force -part $part
  read_verilog $rtl
  synth_design -top $top -part $part -mode out_of_context -generic DIV_BPC=$bpc
  create_clock -name clk -period $period [get_ports clk]
  opt_design; place_design -quiet; phys_opt_design -quiet; route_design -quiet
  report_utilization -file $outdir/${label}_util.rpt
  report_utilization -hierarchical -hierarchical_depth 5 -file $outdir/${label}_hier.rpt
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
  puts "ATTN_RESULT $row"
  lappend summary $row
  # the worst setup path ending in each part of the unit, so a miss can be attributed
  set fh [open $outdir/${label}_parts.tsv w]
  puts $fh "part\tslack_ns\tdatapath_ns\tlevels\tstart\tend"
  foreach {grp pat} {softmax */u_smx/* requant */u_rq/* packers */u_?pk/* sequencer */u_seq/*} {
    set cells [get_cells -hierarchical -filter "NAME =~ $pat && IS_SEQUENTIAL"]
    if {[llength $cells] == 0} { puts $fh "$grp\tNA\tNA\tNA\tNA\tNA"; continue }
    set p [lindex [get_timing_paths -delay_type max -max_paths 1 -to $cells] 0]
    puts $fh "$grp\t[join [path_row $p] \t]"
    puts "ATTN_PART $label $grp [path_row $p]"
  }
  close $fh
  close_project
}
set fh [open $outdir/summary.tsv w]
puts $fh "label\tlut\tff\tdsp\tbram_tile\tramb36\tramb18\tlut_mem\tslack_ns\tdatapath_ns\tlevels\tstart\tend\twhs_ns"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "ATTN_ALL_DONE"
exit
