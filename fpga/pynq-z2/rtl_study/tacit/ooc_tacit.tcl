# ---------------------------------------------------------------------------
# Out-of-context area AND timing for the TACIT trace encoder and its pieces.
#
#   vivado -mode batch -source ooc_tacit.tcl
#
# Same part and the same synth -> opt -> place -> phys_opt -> route flow as
# rtl_study/pext/ooc_pext.tcl and rtl_study/rocc/ooc_rocc.tcl, so the numbers are
# directly comparable with those studies' tables.  Default period 28.999 ns --
# the clock the shipped bitstreams actually run at (34.4828 MHz).
#
# The DUTs are the GENERATED Verilog under out/gensrc/<config>/gen-collateral,
# so what is measured here is the RTL the bitstream carries, not a model of it.
#
# Env:
#   TAC_GENSRC  gen-collateral directory (default: the single-core Tacit config)
#   TAC_ONLY    space-separated subset of labels (default: all)
#   TAC_OUT     output directory (default: ./ooc_out)
#   TAC_PERIOD  clock period in ns (default: 28.999)
#   TAC_TAG     suffix appended to every report/summary name (default: empty)
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../../../.."]
set gensrc [expr {[info exists ::env(TAC_GENSRC)] ? $::env(TAC_GENSRC) : \
  "$repo/out/gensrc/chipyard.harness.TestHarness.PynqZ2RocketTacitConfig/gen-collateral"}]
set outdir [expr {[info exists ::env(TAC_OUT)] ? $::env(TAC_OUT) : "$here/ooc_out"}]
set period [expr {[info exists ::env(TAC_PERIOD)] ? $::env(TAC_PERIOD) : 28.999}]
set only   [expr {[info exists ::env(TAC_ONLY)] ? $::env(TAC_ONLY) : ""}]
set tag    [expr {[info exists ::env(TAC_TAG)] ? $::env(TAC_TAG) : ""}]
file mkdir $outdir

set part xc7z020clg400-1

# Files that exist in every flavour of the config.  A gensrc built with the
# predictor gated off has no DSCBranchPredictor.sv, so that one is optional.
proc gen {gensrc names} {
  set out {}
  foreach n $names {
    set f [file join $gensrc $n]
    if {[file exists $f]} { lappend out $f }
  }
  return $out
}

set enc_files [gen $gensrc {
  TacitEncoder.sv VarLenEncoder.sv TracePacketizer.sv DSCBranchPredictor.sv
  Queue16_UInt8.sv Queue16_UInt13.sv Queue16_Vec10_UInt8.sv
  Queue512_UInt8.sv Queue512_UInt13.sv Queue512_Vec10_UInt8.sv
  Queue128_UInt8.sv Queue128_UInt13.sv Queue128_Vec10_UInt8.sv
  ram_16x8.sv ram_16x13.sv ram_16x80.sv
  ram.sv ram_0.sv ram_1.sv
}]
# A SyncReadMem-backed Queue lands in the SRAM-macro file rather than in its own
# ram_NxM.sv, so pick that up too when it is there.
set enc_files [concat $enc_files [glob -nocomplain $gensrc/*.top.mems.v]]
set bp_files [gen $gensrc {DSCBranchPredictor.sv}]

# label   top              extra rtl
# label      top              rtl          extra +define+
set duts [list \
  [list bp      bp_ooc_harness  $bp_files {}] \
  [list enc     enc_ooc_harness $enc_files {}] \
  [list encnobp enc_ooc_harness $enc_files {TACIT_NO_BP}] \
]

proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    # the value can be fractional -- "Block RAM Tile" is reported as e.g. 5.5
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9.\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return 0
}

# an undriven net synthesises to constant 0 with only a warning -- same promotion
# the pext and rocc flows use, and for the same reason.
set_msg_config -id {Synth 8-3848} -new_severity ERROR

set summary {}
foreach dd $duts {
  lassign $dd label top rtl defs
  if {$only ne "" && [lsearch -exact $only $label] < 0} { continue }
  if {[llength $rtl] == 0} {
    puts "TAC_RESULT $label SKIPPED: no RTL found in $gensrc"
    continue
  }
  puts "=============== TAC_RUN $label$tag (top=$top) ==============="

  create_project -in_memory -force -part $part
  read_verilog -sv $rtl
  read_verilog $here/tacit_harness.v

  set vdefs [concat SYNTHESIS $defs]
  if {[catch {synth_design -top $top -part $part -mode out_of_context \
                -verilog_define $vdefs} err]} {
    puts "TAC_RESULT $label$tag SYNTH_FAILED: $err"
    close_project
    continue
  }

  create_clock -name clk -period $period [get_ports clk]

  opt_design
  place_design -quiet
  phys_opt_design -quiet
  route_design -quiet

  report_utilization -file $outdir/${label}${tag}_util.rpt
  report_utilization -hierarchical -file $outdir/${label}${tag}_util_hier.rpt
  report_timing -delay_type max -max_paths 5 -nworst 5 -path_type full_clock_expanded \
                -from [all_registers] -to [all_registers] -file $outdir/${label}${tag}_timing.rpt

  set luts [util_row $outdir/${label}${tag}_util.rpt "Slice LUTs"]
  set ffs  [util_row $outdir/${label}${tag}_util.rpt "Slice Registers"]
  set dsps [util_row $outdir/${label}${tag}_util.rpt "DSPs"]
  set lram [util_row $outdir/${label}${tag}_util.rpt "LUT as Memory"]
  set llog [util_row $outdir/${label}${tag}_util.rpt "LUT as Logic"]
  set bram [util_row $outdir/${label}${tag}_util.rpt "Block RAM Tile"]
  # RAMB36/RAMB18 come from the hierarchical report's top row, which is unambiguous:
  #   sed -n '/Instance/,$p' <label>_util_hier.rpt

  set paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1 \
               -from [all_registers] -to [all_registers]]
  if {[llength $paths] == 0} {
    puts "TAC_RESULT $label$tag lut=$luts ff=$ffs dsp=$dsps NO_TIMING_PATH"
  } else {
    set pth   [lindex $paths 0]
    set slack [get_property SLACK $pth]
    set dd2   [get_property DATAPATH_DELAY $pth]
    set lvl   [get_property LOGIC_LEVELS $pth]
    set fh [open $outdir/${label}${tag}_timing.rpt r]; set t [read $fh]; close $fh
    set lg "?"; set rt "?"
    if {[regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns.*route ([0-9.]+)ns} $t -> _dd _lg _rt]} {
      set lg $_lg; set rt $_rt
    }
    puts [format "TAC_RESULT %s lut=%s lutlogic=%s lutmem=%s ff=%s dsp=%s bram=%s slack=%.3f dpd=%.3f logic=%s route=%s levels=%s" \
          $label$tag $luts $llog $lram $ffs $dsps $bram $slack $dd2 $lg $rt $lvl]
    lappend summary [list $label$tag $luts $llog $lram $ffs $dsps $bram $slack $dd2 $lg $rt $lvl]
  }
  close_project
}

set sfile $outdir/summary${tag}.tsv
set fh [open $sfile w]
puts $fh "label\tlut\tlut_logic\tlut_mem\tff\tdsp\tbram\tslack_ns\tdatapath_ns\tlogic_ns\troute_ns\tlevels"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "TAC_ALL_DONE period=$period gensrc=$gensrc n=[llength $summary] -> $sfile"
exit
