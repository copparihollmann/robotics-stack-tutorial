# ---------------------------------------------------------------------------
# Out-of-context area AND timing for the RoCC candidate datapaths.
#
#   vivado -mode batch -source ooc_rocc.tcl
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
set outdir [expr {[info exists ::env(MBX_OUT)] ? $::env(MBX_OUT) : "$here/ooc_out"}]
set period [expr {[info exists ::env(MBX_PERIOD)] ? $::env(MBX_PERIOD) : 28.999}]
set only   [expr {[info exists ::env(MBX_ONLY)] ? $::env(MBX_ONLY) : ""}]
file mkdir $outdir

set part xc7z020clg400-1

set rtl [list \
  $here/mbx_mac.v $here/mbx_quant.v $here/mbx_gather.v $here/mbx_accbank.v \
  $here/mbx_ctrl.v $here/mbx_top.v $here/mbx_spad.v $here/mbx_dma.v \
  $here/mbx_tseq.v $here/mbx_tiled.v $here/mbx_variants.v $here/mbx_harness.v]

# label                 MBX_DUT
set duts {
  {null                 mbx_v_null}
  {mac8_dsp             mbx_v_mac8_dsp}
  {mac8_dsp_p2          mbx_v_mac8_dsp_p2}
  {mac8x4_nopack        mbx_v_mac8x4_nopack}
  {mac8x4_pack          mbx_v_mac8x4_pack}
  {mac8x4_pack_p2       mbx_v_mac8x4_pack_p2}
  {mac8x4_pack_a32      mbx_v_mac8x4_pack_a32}
  {mac8x4_lut           mbx_v_mac8x4_lut}
  {mac8x8_pack          mbx_v_mac8x8_pack}
  {quant4_comb          mbx_v_quant4_comb}
  {quant4_p3            mbx_v_quant4_p3}
  {qmul32               mbx_v_qmul32}
  {align                mbx_v_align}
  {gather               mbx_v_gather}
  {accbank16            mbx_v_accbank16}
  {ctrl_d1              mbx_v_ctrl_d1}
  {ctrl_d4              mbx_v_ctrl_d4}
  {ctrl_d8              mbx_v_ctrl_d8}
  {unit_min             mbx_v_min}
  {unit_lean            mbx_v_lean}
  {unit_full            mbx_v_full}
  {spad_5x1             mbx_v_spad_5x1}
  {spad_5x3             mbx_v_spad_5x3}
  {spad_5x6             mbx_v_spad_5x6}
  {spad_5x15            mbx_v_spad_5x15}
  {spad_9x2             mbx_v_spad_9x2}
  {dma_d4               mbx_v_dma_d4}
  {dma_d8               mbx_v_dma_d8}
  {tseq4                mbx_v_tseq4}
  {unit_tiled4_nog      mbx_v_tiled4_nog}
  {unit_tiled4          mbx_v_tiled4}
  {unit_tiled8          mbx_v_tiled8}
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
