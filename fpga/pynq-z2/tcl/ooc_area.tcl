# Out-of-context area probe for a Chipyard ChipTop.
#
#   CHIPYARD_GENSRC=<dir> vivado -mode batch -source tcl/ooc_area.tcl
#
# Synthesises ChipTop ALONE on xc7z020clg400-1 -- no PS7, no structural top, no bridge, no
# XDC -- and prints utilisation. That is the cheap gate: it answers "does this config have
# any chance of fitting" in ~10 minutes instead of the ~50 that a full place-and-route
# costs, and it is the same methodology as docs/ACCELERATOR_FIT.md, so its numbers are
# directly comparable to the ones recorded there.
#
# OOC OVERSTATES. For PynqZ2RocketTacitConfig the OOC number is 31,994 LUT against 28,009
# in the routed in-context build -- a ratio of 0.875, because OOC keeps no I/O buffers but
# also gets no cross-boundary optimisation with the rest of the design. Apply that ratio
# when comparing against the 53,200-LUT budget.
set gensrc [expr {[info exists ::env(CHIPYARD_GENSRC)] ? $::env(CHIPYARD_GENSRC) : ""}]
if {$gensrc eq ""} { error "set CHIPYARD_GENSRC to a Chipyard generated-src directory" }
set outdir [expr {[info exists ::env(OOC_OUT)] ? $::env(OOC_OUT) : "/tmp/ooc_area"}]
file mkdir $outdir

set topf [glob -nocomplain $gensrc/*.top.f]
if {[llength $topf] != 1} { error "expected exactly one *.top.f in $gensrc" }
set topf [lindex $topf 0]

create_project -in_memory -part xc7z020clg400-1

set fh [open $topf r]; set files [split [string trim [read $fh]] "\n"]; close $fh
puts "Chipyard sources from top.f: [llength $files]"
read_verilog -sv $files

# The SRAM macros are emitted by the mem-gen pass into *.top.mems.v and are NOT in top.f;
# without them synthesis dies with "module 'cc_dir_ext' not found".
set mems [glob -nocomplain $gensrc/gen-collateral/*.top.mems.v]
if {[llength $mems] == 0} { error "no *.top.mems.v found in $gensrc/gen-collateral" }
puts "SRAM macro files: [llength $mems]"
read_verilog -sv $mems

# Same promotion as the real build: an undriven net synthesises to constant 0 with only a
# warning, and on an AXI ID path that is a silent hang.
set_msg_config -id {Synth 8-3848} -new_severity ERROR

synth_design -top ChipTop -part xc7z020clg400-1 -mode out_of_context
report_utilization -file $outdir/ooc_util.rpt
report_utilization -hierarchical -file $outdir/ooc_util_hier.rpt

# Parse the utilisation TABLE, not a get_cells primitive count. `Slice LUTs` in the
# report already accounts for LUT combining; counting LUT primitives directly reads ~7%
# high (34,214 vs 31,994 on the baseline) and is not comparable with docs/ACCELERATOR_FIT.md.
proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return "?"
}
set luts [util_row $outdir/ooc_util.rpt "Slice LUTs"]
set regs [util_row $outdir/ooc_util.rpt "Slice Registers"]
set rams [util_row $outdir/ooc_util.rpt "Block RAM Tile"]
set dsps [util_row $outdir/ooc_util.rpt "DSPs"]
puts [format "OOC_AREA lut=%s (%.2f%% of 53200) ff=%s bram36=%s (%.2f%% of 140) dsp=%s" \
        $luts [expr {100.0*$luts/53200}] $regs $rams [expr {100.0*$rams/140}] $dsps]
puts "OOC_AREA_OK $gensrc"
exit
