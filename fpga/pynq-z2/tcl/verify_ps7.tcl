# Build the PS7 with the explicit preset and ASSERT the board-critical parameters.
# This is the gate: if DDR geometry does not match the TUL board file, fail loudly here
# rather than discovering it when a board finally arrives.
set root [file normalize [file dirname [info script]]/..]
set_param board.repoPaths [list $root/boards]
set outdir /tmp/claude-1172/-scratch-dima-iiswc-tutorial/663bf7b9-2402-45dd-9c13-2a65e44ef7f0/scratchpad/ps7verify
file delete -force $outdir
create_project ps7verify $outdir -part xc7z020clg400-1 -force
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]

source $root/tcl/ps7_preset_pynqz2.tcl
create_ip -name processing_system7 -vendor xilinx.com -library ip -module_name ps7_0
apply_ps7_preset_pynqz2 [get_ips ps7_0]

# The PL-facing ports this design needs on top of the preset.
set_property -dict [list \
  CONFIG.PCW_USE_S_AXI_HP0 {1} \
  CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_M_AXI_GP0_ENABLE_STATIC_REMAP {0} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} \
  CONFIG.PCW_EN_CLK0_PORT {1} \
  CONFIG.PCW_EN_RST0_PORT {1} \
] [get_ips ps7_0]

set fails 0
proc expect {ip key want} {
  upvar fails fails
  set got [get_property CONFIG.$key [get_ips $ip]]
  if {[string trim $got] eq [string trim $want]} {
    puts "  OK   $key = $got"
  } else {
    puts "  FAIL $key = '$got'  (expected '$want')"
    incr fails
  }
}
puts "=== PS7 ASSERTIONS (PYNQ-Z2, TUL board rev A.0) ==="
expect ps7_0 PCW_UIPARAM_DDR_PARTNO         "MT41J256M16 RE-125"
expect ps7_0 PCW_UIPARAM_DDR_BUS_WIDTH      "16 Bit"
expect ps7_0 PCW_UIPARAM_DDR_DRAM_WIDTH     "16 Bits"
expect ps7_0 PCW_UIPARAM_DDR_DEVICE_CAPACITY "4096 MBits"
expect ps7_0 PCW_UIPARAM_DDR_FREQ_MHZ       "525"
expect ps7_0 PCW_UIPARAM_DDR_CL             "7"
expect ps7_0 PCW_UIPARAM_DDR_BANK_ADDR_COUNT "3"
expect ps7_0 PCW_UIPARAM_DDR_ROW_ADDR_COUNT  "15"
expect ps7_0 PCW_UIPARAM_DDR_COL_ADDR_COUNT  "10"
expect ps7_0 PCW_USE_S_AXI_HP0              "1"
expect ps7_0 PCW_S_AXI_HP0_DATA_WIDTH       "64"
expect ps7_0 PCW_USE_M_AXI_GP0              "1"
expect ps7_0 PCW_FPGA0_PERIPHERAL_FREQMHZ   "50"
puts "PS7_DDR_BASE = [get_property CONFIG.PCW_DDR_RAM_BASEADDR [get_ips ps7_0]]"
puts "PS7_DDR_HIGH = [get_property CONFIG.PCW_DDR_RAM_HIGHADDR [get_ips ps7_0]]"

generate_target {instantiation_template synthesis} [get_ips ps7_0]
if {$fails > 0} { puts "PS7_VERIFY: FAIL ($fails)"; exit 1 } else { puts "PS7_VERIFY: PASS"; exit 0 }
