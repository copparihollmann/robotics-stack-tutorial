# Headless PS7 configuration probe: can we configure the Zynq PS entirely from TCL,
# with no Vivado GUI and no Vitis? If yes, the "manual Vitis setup" concern is void.
set root [file normalize [file dirname [info script]]/..]
set_param board.repoPaths [list $root/boards]
set outdir /tmp/claude-1172/-scratch-dima-iiswc-tutorial/663bf7b9-2402-45dd-9c13-2a65e44ef7f0/scratchpad/ps7probe
file delete -force $outdir
create_project ps7probe $outdir -part xc7z020clg400-1 -force
set bp [get_board_parts -quiet "*pynq-z2*"]
puts "BOARDPART_FOUND: $bp"
if {[llength $bp] > 0} { set_property board_part [lindex $bp 0] [current_project] }

create_ip -name processing_system7 -vendor xilinx.com -library ip -module_name ps7_0
# Apply the TUL board preset, then turn on the HP0 slave port the PL will master into.
set_property -dict [list \
  CONFIG.PCW_IMPORT_BOARD_PRESET $root/boards/pynq-z2/A.0/preset.xml \
] [get_ips ps7_0]
set_property -dict [list \
  CONFIG.PCW_USE_S_AXI_HP0 {1} \
  CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} \
] [get_ips ps7_0]

foreach k {PCW_UIPARAM_DDR_PARTNO PCW_UIPARAM_DDR_BUS_WIDTH PCW_UIPARAM_DDR_FREQ_MHZ \
           PCW_USE_S_AXI_HP0 PCW_S_AXI_HP0_DATA_WIDTH PCW_USE_M_AXI_GP0 \
           PCW_FPGA0_PERIPHERAL_FREQMHZ PCW_APU_PERIPHERAL_FREQMHZ PCW_UIPARAM_DDR_DRAM_WIDTH} {
  puts "PS7CFG $k = [get_property CONFIG.$k [get_ips ps7_0]]"
}
generate_target {instantiation_template synthesis} [get_ips ps7_0]
puts "PS7_GENERATED_OK"
exit
