# The PDM microphone's two pins. A SEPARATE constraint file, added by tcl/build_rocket.tcl
# only for the mic variant, and that is not tidiness -- it is the only thing that works.
#
# The first attempt guarded the constraints inside the shared pynqz2_rocket.xdc with
# `foreach` and `if` so that the three builds without these ports would skip them. Vivado
# 2023.1 answers that with
#     CRITICAL WARNING: [Designutils 20-1307] Command 'foreach' is not supported in the
#     xdc constraint file
# and then SILENTLY RUNS NEITHER. A file in constrs_1 is parsed as XDC, a restricted
# subset, not as Tcl; control flow is dropped on the floor. The design still placed --
# Vivado assigns unconstrained I/O wherever it likes -- so the failure would have been a
# bitstream with the microphone wired to two arbitrary balls, caught only by
# write_bitstream's unconstrained-port DRC, or not at all.
#
# Knowles SPK0833LM4H-B, PYNQ-Z1 Reference Manual s13. Pin numbers from Xilinx's own base
# overlay for this board (Xilinx/PYNQ boards/Pynq-Z1/base/vivado/constraints/base.xdc) and
# confirmed by recording through it -- fpga/pynq-z2/docs/MICROPHONE.md s1.3 and s2. There
# is no L/R SELECT pin: it is tied low on the board.
set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33} [get_ports mic_pdm_clk]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports mic_pdm_data]

# mic_pdm_data is source-synchronous THROUGH THE BOARD: the microphone launches its bit on
# the rising edge of a clock we generate, and pdm_mic_capture.v samples it six system clocks
# (174 ns) later, into a two-flop synchroniser. The data is stable for ~200 ns either side
# of that point by the protocol -- so there is no launch clock the timing engine could use,
# and the only honest thing to do is say so rather than leave it silently unconstrained.
set_false_path -from [get_ports mic_pdm_data]
