# ---------------------------------------------------------------------------
# Out-of-context area and timing of the LayerNorm/GroupNorm lane (mbxr_ln.v, through
# mbxr_ln_ooc, which registers every port), on the same part, period (28.999 ns =
# 34.4828 MHz) and synth -> opt -> place -> phys_opt -> route flow as ../ooc_roccmoon.tcl,
# ../ooc_dpw.tcl and ../smx_lane/ooc_smx.tcl.  No MAGIC, no bitstream.  From the repo root:
#
#   scripts/lib/with_lock.sh vivado vivado -mode batch -nojournal -nolog \
#     -source fpga/pynq-z2/rtl_study/roccmoon/ln_lane/ooc_ln.tcl
#
# Env: LN_OUT   report directory (default archive/rtl_study/roccmoon/ln_lane/ooc_out -- raw
#               reports are not committed; ln_lane/summary.json carries the curated numbers)
#      LN_ONLY  space-separated subset of the labels below
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../../../../.."]
set outdir [expr {[info exists ::env(LN_OUT)] ? $::env(LN_OUT) : "$repo/archive/rtl_study/roccmoon/ln_lane/ooc_out"}]
set period 28.999
set part xc7z020clg400-1
file mkdir $outdir
set rtl [list $here/mbxr_ln.v]
# label     KL2 TL2 OFW
#   ln_main  the lane as simulated and reported: K <= 512 one-pass, 512 affine indices
#   ln_k1024 the next model size up: K <= 1024 one-pass, 1024 affine indices
set rows {{ln_main 9 9 4} {ln_k1024 10 10 4}}
if {[info exists ::env(LN_ONLY)]} {
  set keep {}
  foreach r $rows { if {[lsearch -exact $::env(LN_ONLY) [lindex $r 0]] >= 0} { lappend keep $r } }
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
  lassign $r label kl2 tl2 ofw
  create_project -in_memory -force -part $part
  read_verilog $rtl
  synth_design -top mbxr_ln_ooc -part $part -mode out_of_context \
    -generic KL2=$kl2 -generic TL2=$tl2 -generic OFW=$ofw
  create_clock -name clk -period $period [get_ports clk]
  # NOT -quiet on opt_design: -quiet suppressed DRC MDRV-1 (a multiple-driver net) on the
  # first run of this lane and the defect only surfaced in a full build.  See
  # docs/LAYERNORM_LANE.md s15.
  opt_design; place_design -quiet; phys_opt_design -quiet; route_design -quiet
  report_utilization -file $outdir/${label}_util.rpt
  report_utilization -hierarchical -hierarchical_depth 4 -file $outdir/${label}_hier.rpt
  report_timing_summary -max_paths 5 -file $outdir/${label}_timing_summary.rpt
  report_timing -delay_type max -max_paths 20 -nworst 1 -from [all_registers] -to [all_registers] \
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
  puts "LN_RESULT $row"
  lappend summary $row
  # the worst setup path ending in each part of the lane, by the registers it writes
  set fh [open $outdir/${label}_parts.tsv w]
  puts $fh "part\tslack_ns\tdatapath_ns\tlevels\tstart\tend"
  foreach {grp pat} {row_unit {u/acc* u/root* u/dq* u/vq* u/kq*} \
                     apply    {u/pr5* u/qq6* u/m4* u/d3* u/w2* u/yy7*} \
                     ingest   {u/acc_s* u/acc_q* u/uu3* u/u2* u/u3*}} {
    set cells {}
    foreach p $pat {
      set cells [concat $cells [get_cells -quiet -hierarchical -filter "NAME =~ $p && IS_SEQUENTIAL"]]
    }
    if {[llength $cells] == 0} { puts $fh "$grp\tNA\tNA\tNA\tNA\tNA"; continue }
    set p [lindex [get_timing_paths -delay_type max -max_paths 1 -to $cells] 0]
    puts $fh "$grp\t[join [path_row $p] \t]"
    puts "LN_PART $label $grp [path_row $p]"
  }
  close $fh
  close_project
}
set fh [open $outdir/summary.tsv w]
puts $fh "label\tlut\tff\tdsp\tbram_tile\tramb36\tramb18\tlut_mem\tslack_ns\tdatapath_ns\tlevels\tstart\tend\twhs_ns"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "LN_ALL_DONE"
exit
