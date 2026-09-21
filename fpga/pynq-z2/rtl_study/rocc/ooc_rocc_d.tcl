# ---------------------------------------------------------------------------
# Out-of-context area AND timing for the DECOUPLED engine (mbxd_*), revision 3.
#
# Same part, same period and the same synth -> opt -> place -> phys_opt -> route flow as
# ooc_rocc.tcl, so every number here is directly comparable with ooc_out/summary.tsv and
# with PEXT_FEASIBILITY.md.  It writes to ooc_out_d/ so revision 2's record is untouched.
#
# The rows are deliberately per-BLOCK as well as per-unit: the fill engine is the part
# most likely to be worth landing on its own, and mixing its area into a whole-unit
# number would hide that.
#
# Out-of-context area AND timing for the RoCC candidate datapaths.
#
#   vivado -mode batch -source ooc_rocc_d.tcl
#
# Same part and the same synth -> opt -> place -> phys_opt -> route flow as
# rtl_study/pext/ooc_pext.tcl, so the numbers are directly comparable with
# PEXT_FEASIBILITY.md's tables.  The default period is 28.999 ns -- the clock the
# shipped P-ext bitstream actually runs at (34.4828 MHz), not the 25 or 28.571 ns
# the P-ext study used before the clock arithmetic was settled.
#
# Env:
#   MBX_ONLY    space-separated subset of labels to run (default: all)
#   MBX_OUT     output directory (default: ./ooc_out)
#   MBX_PERIOD  clock period in ns (default: 28.999)
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set outdir [expr {[info exists ::env(MBX_OUT)] ? $::env(MBX_OUT) : "$here/ooc_out_d"}]
set period [expr {[info exists ::env(MBX_PERIOD)] ? $::env(MBX_PERIOD) : 28.999}]
set only   [expr {[info exists ::env(MBX_ONLY)] ? $::env(MBX_ONLY) : ""}]
file mkdir $outdir

set part xc7z020clg400-1

set rtl [list \
  $here/mbx_mac.v $here/mbx_quant.v $here/mbx_accbank.v $here/mbx_tseq.v \
  $here/mbxd_dma.v $here/mbxd_st.v $here/mbxd_spad.v $here/mbxd_top.v \
  $here/mbxd_variants.v $here/mbx_harness.v]

# label                 MBX_DUT
set duts {
  {null                 mbx_v_null}
  {d_dma2               mbxd_v_dma2}
  {d_dma4               mbxd_v_dma4}
  {d_dma8               mbxd_v_dma8}
  {d_st2                mbxd_v_st2}
  {d_spad_5x4           mbxd_v_spad5x4}
  {d_spad_5x8           mbxd_v_spad5x8}
  {d_spad_9x4           mbxd_v_spad9x4}
  {d_tseq4              mbxd_v_tseq4}
  {d_mac4               mbxd_v_mac4}
  {d_eng4               mbxd_v_eng4}
  {d_eng4_nost          mbxd_v_eng4_nost}
  {d_eng4_d4            mbxd_v_eng4_d4}
  {d_eng8               mbxd_v_eng8}
}

proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return 0
}

# an undriven net synthesises to constant 0 with only a warning -- same promotion
# the pext flow uses, and the same reason: a silently tied-off port would make a
# block measure small for the wrong reason.
set_msg_config -id {Synth 8-3848} -new_severity ERROR

set summary {}
foreach dd $duts {
  lassign $dd label dut
  if {$only ne "" && [lsearch -exact $only $label] < 0} { continue }
  puts "=============== MBX_RUN $label (dut=$dut) ==============="

  create_project -in_memory -force -part $part
  read_verilog $rtl

  if {[catch {synth_design -top mbx_harness -part $part -mode out_of_context \
                -verilog_define "MBX_DUT=$dut"} err]} {
    puts "MBX_RESULT $label SYNTH_FAILED: $err"
    close_project
    continue
  }

  create_clock -name clk -period $period [get_ports clk]

  opt_design
  place_design -quiet
  phys_opt_design -quiet
  route_design -quiet

  report_utilization -file $outdir/${label}_util.rpt
  report_timing -delay_type max -max_paths 5 -nworst 5 -path_type full_clock_expanded \
                -from [all_registers] -to [all_registers] -file $outdir/${label}_timing.rpt

  set luts [util_row $outdir/${label}_util.rpt "Slice LUTs"]
  set ffs  [util_row $outdir/${label}_util.rpt "Slice Registers"]
  set dsps [util_row $outdir/${label}_util.rpt "DSPs"]
  set lram [util_row $outdir/${label}_util.rpt "LUT as Memory"]
  set llog [util_row $outdir/${label}_util.rpt "LUT as Logic"]
  set bram [util_row $outdir/${label}_util.rpt "Block RAM Tile"]

  set paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1 \
               -from [all_registers] -to [all_registers]]
  if {[llength $paths] == 0} {
    puts "MBX_RESULT $label lut=$luts ff=$ffs dsp=$dsps NO_TIMING_PATH"
  } else {
    set pth   [lindex $paths 0]
    set slack [get_property SLACK $pth]
    set dd2   [get_property DATAPATH_DELAY $pth]
    set lvl   [get_property LOGIC_LEVELS $pth]
    set src   [get_property STARTPOINT_PIN $pth]
    set dst   [get_property ENDPOINT_PIN $pth]
    set fh [open $outdir/${label}_timing.rpt r]; set t [read $fh]; close $fh
    set lg "?"; set rt "?"
    if {[regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns.*route ([0-9.]+)ns} $t -> _dd _lg _rt]} {
      set lg $_lg; set rt $_rt
    }
    puts [format "MBX_RESULT %s lut=%s lutlogic=%s lutmem=%s ff=%s dsp=%s bram=%s slack=%.3f dpd=%.3f logic=%s route=%s levels=%s" \
          $label $luts $llog $lram $ffs $dsps $bram $slack $dd2 $lg $rt $lvl]
    lappend summary [list $label $luts $llog $lram $ffs $dsps $bram $slack $dd2 $lg $rt $lvl $src $dst]
  }
  close_project
}

set fh [open $outdir/summary.tsv w]
puts $fh "label\tlut\tlut_logic\tlut_mem\tff\tdsp\tbram\tslack_ns\tdatapath_ns\tlogic_ns\troute_ns\tlevels\tstart\tend"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "MBX_ALL_DONE period=$period n=[llength $summary] -> $outdir/summary.tsv"
exit
