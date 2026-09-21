# Build the PYNQ-Z2 DRAM self-test bitstream, end to end, headless.
#   vivado -mode batch -source tcl/build_bitstream.tcl
# Emits reports into build/reports and the bitstream into build/.
set root [file normalize [file dirname [info script]]/..]
set_param board.repoPaths [list $root/boards]
source $root/tcl/board.tcl
set build $root/build_$::BOARD
file mkdir $build/reports

create_project pynqz2 $build/proj -part xc7z020clg400-1 -force
set_property board_part $::BOARD_PART [current_project]

add_files -norecurse [glob $root/src/*.v]
add_files -fileset constrs_1 -norecurse $root/src/pynqz2.xdc
set_property top pynqz2_top [current_fileset]

# --- PS7, configured explicitly (see tcl/ps7_preset_pynqz2.tcl for why not a preset import)
source $root/tcl/$::PRESET_FILE
create_ip -name processing_system7 -vendor xilinx.com -library ip -module_name ps7_0
$::PRESET_PROC [get_ips ps7_0]
set_property -dict [list \
  CONFIG.PCW_USE_S_AXI_HP0 {1} \
  CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} \
  CONFIG.PCW_EN_CLK0_PORT {1} \
  CONFIG.PCW_EN_RST0_PORT {1} \
] [get_ips ps7_0]

# Gate the build on the DDR geometry before spending an hour on place and route.
foreach {k want} [list PCW_UIPARAM_DDR_PARTNO {MT41J256M16 RE-125} \
                                    PCW_UIPARAM_DDR_BUS_WIDTH {16 Bit} \
                                    PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits} \
                                    PCW_UIPARAM_DDR_T_RCD $::DDR_T_RCD \
                                    PCW_USE_S_AXI_HP0 {1}] {
  set got [get_property CONFIG.$k [get_ips ps7_0]]
  if {[string trim $got] ne [string trim $want]} {
    error "PS7 misconfigured: $k = '$got', expected '$want'"
  }
}
puts "PS7 DDR geometry verified against the TUL board file."

generate_target all [get_ips ps7_0]
# synth_ip warns that it is "not supported in project mode", but it is what actually makes
# the ps7_0 module visible to synth_design here. Without it synthesis fails with
# "module 'ps7_0' not found". The warning is cosmetic; the alternative is a full IP run.
synth_ip [get_ips ps7_0]

# An undriven net synthesises to constant 0 with only a WARNING. On an AXI ID path that is
# fatal but silent: the PS7 GP0 master never retires a read whose RID does not match the
# ARID it issued, so the CPU locks on the very first register read and the board needs a
# physical power cycle. MEASURED: gp0_rid was undriven in the first Z1 builds and did
# exactly that. It was the only 8-3848 in either build, so promoting it is safe.
set_msg_config -id {Synth 8-3848} -new_severity ERROR

synth_design -top pynqz2_top -part xc7z020clg400-1
# A multi-driven net is resolved by Vivado keeping a constant driver and discarding the
# real logic -- silently, and the design still builds. Treat it as fatal.
set md [get_nets -quiet -filter {ROUTE_STATUS == CONFLICTS}]
if {[llength $md] > 0} { error "multi-driven nets after synthesis: $md" }
report_utilization -file $build/reports/post_synth_util.rpt
write_checkpoint -force $build/post_synth.dcp

opt_design
place_design
phys_opt_design
route_design

report_utilization      -file $build/reports/post_route_util.rpt
report_utilization -hierarchical -file $build/reports/post_route_util_hier.rpt
report_timing_summary   -file $build/reports/timing_summary.rpt -max_paths 10
report_drc              -file $build/reports/drc.rpt
report_clock_utilization -file $build/reports/clock_util.rpt
write_checkpoint -force $build/post_route.dcp

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "TIMING_WNS: $wns"
puts "TIMING_WHS: $whs"

write_bitstream -force $build/pynq${::BOARD}_dramtest.bit
puts "BITSTREAM_OK: $build/pynq${::BOARD}_dramtest.bit"
exit
