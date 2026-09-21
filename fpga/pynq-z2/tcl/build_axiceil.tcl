# Build the interface-ceiling instrument (MAGIC 0x5A5A0020): PS7 + four raw AXI3 masters on
# S_AXI_HP0..HP3.  MEMORY_BANDWIDTH.md section 7.
#
#   vivado -mode batch -source tcl/build_axiceil.tcl
#
#   AXICEIL_FCLK_MHZ   the FCLK0 frequency this build is TIMED at (default 142.857 = 1000/7).
#                      The board can always run it slower; the lab sweeps down from here
#                      at run time, so a build exists only to push the top of the sweep.
#   AXICEIL_TAG        suffix for the build directory: build_axiceil${TAG}_z1
#
# A small design with its own top level (src/axiceil/axiceil_top.v): nothing here reads
# Chipyard output or touches src/pynqz2_rocket_top.v.
set root [file normalize [file dirname [info script]]/..]
set_param board.repoPaths [list $root/boards]
source $root/tcl/board.tcl

set fclk_mhz [expr {[info exists ::env(AXICEIL_FCLK_MHZ)] ? $::env(AXICEIL_FCLK_MHZ) : "142.857"}]
set tag      [expr {[info exists ::env(AXICEIL_TAG)] ? $::env(AXICEIL_TAG) : ""}]
set build $root/build_axiceil${tag}_$::BOARD
file mkdir $build/reports

create_project axiceil $build/proj -part xc7z020clg400-1 -force
set_property board_part $::BOARD_PART [current_project]

add_files -norecurse [list $root/src/axiceil/axiceil_top.v $root/src/axiceil/axiceil_core.v \
                           $root/src/axiceil/axiceil_port.v $root/src/axiceil/axiceil_guard.v]
add_files -fileset constrs_1 -norecurse $root/src/axiceil/axiceil.xdc
set_property top axiceil_top [current_fileset]

source $root/tcl/$::PRESET_FILE
create_ip -name processing_system7 -vendor xilinx.com -library ip -module_name ps7_0
$::PRESET_PROC [get_ips ps7_0]
set props [list CONFIG.PCW_USE_M_AXI_GP0 {1} \
                CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk_mhz \
                CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_EN_RST0_PORT {1}]
foreach hp {0 1 2 3} {
  lappend props CONFIG.PCW_USE_S_AXI_HP$hp {1} CONFIG.PCW_S_AXI_HP${hp}_DATA_WIDTH {64}
}
set_property -dict $props [get_ips ps7_0]

# Gate on what the PS7 actually resolved to, before an hour of anything.
foreach {k want} [list PCW_UIPARAM_DDR_PARTNO {MT41J256M16 RE-125} \
                       PCW_UIPARAM_DDR_BUS_WIDTH {16 Bit} \
                       PCW_UIPARAM_DDR_T_RCD $::DDR_T_RCD \
                       PCW_USE_S_AXI_HP0 {1} PCW_USE_S_AXI_HP1 {1} \
                       PCW_USE_S_AXI_HP2 {1} PCW_USE_S_AXI_HP3 {1} \
                       PCW_S_AXI_HP0_DATA_WIDTH {64} PCW_S_AXI_HP1_DATA_WIDTH {64} \
                       PCW_S_AXI_HP2_DATA_WIDTH {64} PCW_S_AXI_HP3_DATA_WIDTH {64} \
                       PCW_S_AXI_HP0_ID_WIDTH {6} PCW_S_AXI_HP2_ID_WIDTH {6}] {
  set got [get_property CONFIG.$k [get_ips ps7_0]]
  if {[string trim $got] ne [string trim $want]} {
    error "PS7 misconfigured: $k = '$got', expected '$want'"
  }
}
# The DDR controller QoS the preset ASKS for.  host/ddrc_afi.py reads what RUNS.
foreach k {PCW_DDR_PORT0_HPR_ENABLE PCW_DDR_PORT1_HPR_ENABLE PCW_DDR_PORT2_HPR_ENABLE \
           PCW_DDR_PORT3_HPR_ENABLE PCW_DDR_HPRLPR_QUEUE_PARTITION \
           PCW_DDR_LPR_TO_CRITICAL_PRIORITY_LEVEL PCW_DDR_HPR_TO_CRITICAL_PRIORITY_LEVEL \
           PCW_DDR_WRITE_TO_CRITICAL_PRIORITY_LEVEL PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ \
           PCW_FCLK0_PERIPHERAL_DIVISOR0 PCW_FCLK0_PERIPHERAL_DIVISOR1} {
  puts "PS7_PRESET: $k = [get_property CONFIG.$k [get_ips ps7_0]]"
}

generate_target all [get_ips ps7_0]
synth_ip [get_ips ps7_0]
# The generated ps7_init.c spells out every DDR controller field the preset would program;
# host/ddrc_afi.py --compare reads it.
foreach f [glob -nocomplain $build/proj/axiceil.gen/sources_1/ip/ps7_0/ps7_init.*] {
  file copy -force $f $build/
}

# Undriven nets -> ERROR (an undriven RID locks the CPU; build_bitstream.tcl's lesson).
set_msg_config -id {Synth 8-3848} -new_severity ERROR

synth_design -top axiceil_top -part xc7z020clg400-1
set md [get_nets -quiet -filter {ROUTE_STATUS == CONFLICTS}]
if {[llength $md] > 0} { error "multi-driven nets after synthesis: $md" }
report_utilization -file $build/reports/post_synth_util.rpt
write_checkpoint -force $build/post_synth.dcp

opt_design
place_design
phys_opt_design
route_design
phys_opt_design

report_utilization       -file $build/reports/post_route_util.rpt
report_utilization -hierarchical -file $build/reports/post_route_util_hier.rpt
report_timing_summary    -file $build/reports/timing_summary.rpt -max_paths 20
report_timing -max_paths 20 -nworst 1 -file $build/reports/worst_paths.rpt
report_clocks            -file $build/reports/clocks.rpt
report_cdc               -file $build/reports/cdc.rpt
report_drc               -file $build/reports/drc.rpt
write_checkpoint -force $build/post_route.dcp

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "AXICEIL_FCLK_MHZ: $fclk_mhz"
puts "TIMING_WNS: $wns"
puts "TIMING_WHS: $whs"

write_bitstream -force $build/pynq${::BOARD}_axiceil.bit
puts "BITSTREAM_OK: $build/pynq${::BOARD}_axiceil.bit"
exit
