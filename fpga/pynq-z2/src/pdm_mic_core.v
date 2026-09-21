// -----------------------------------------------------------------------------
// The whole microphone peripheral: capture chain + sample FIFO + a flat register
// file, with a deliberately bus-agnostic port list.
//
// The register side is a single-cycle read/write port rather than AXI or TileLink so
// that the same Verilog can be wrapped by a Chisel `TLRegisterNode` BlackBox inside
// ChipTop, by an AXI4-Lite shim beside it, or driven directly by a Verilator
// testbench.  Bus glue is the part that differs between those three; the DSP is not.
//
// Register map.  `reg_addr` is a register INDEX, 0..7, not a byte address: the byte
// stride is the bus wrapper's business.  The TileLink wrapper in Chipyard
// (generators/chipyard/src/main/scala/pdmmic/PdmMic.scala) uses a stride of EIGHT,
// one 32-bit register per 64-bit pbus word, so that no access size can select two
// fields at once and make this module's single shared reg_addr ambiguous.  The CPU
// byte offsets are therefore 0x00, 0x08, 0x10, ... and are shown in brackets below.
//
//   idx (byte)
//
//   0 (0x00)  ID      R    0x504D4331 "PMC1"
//   1 (0x08)  CTRL    RW   [0] enable  [1] fifo_reset (self-clearing)  [2] dc_bypass
//                      [3] clear_sticky (self-clearing: overrun + saturated)
//   2 (0x10)  STATUS  R    [0] settling  [1] empty  [2] full  [3] overrun  [4] saturated
//   3 (0x18)  LEVEL   R    samples currently in the FIFO
//   4 (0x20)  DATA    R    pops one sample, sign-extended to 32 bits.  Reads 0 when the
//                      FIFO is empty; software is expected to consult LEVEL first.
//   5 (0x28)  RATE    R    the PCM sample rate in MILLIHERTZ.  15993859 = 15993.859 Hz.
//                      Not 16000: see MICROPHONE.md -- exactly 16 kHz is unreachable
//                      from a 1000/29 MHz clock by integer division.
//   6 (0x30)  DEPTH   R    FIFO depth in samples
//   7 (0x38)  WMARK   RW   interrupt watermark.  `irq` is level-sensitive and asserts
//                      while LEVEL >= WMARK; 0 disables it.  Nothing is obliged to
//                      wire `irq` anywhere -- at 32 kB/s with a 64 ms FIFO, polling
//                      is not a compromise.
// -----------------------------------------------------------------------------
module pdm_mic_core #(
  parameter integer PDM_HALF   = 7,
  parameter integer CIC_R      = 22,
  parameter integer FIR_TAPS   = 289,
  parameter integer FIR_DECIM  = 7,
  parameter integer FIR_SHIFT  = 22,
  parameter integer SETTLE     = 131072,
  parameter integer FIFO_ALOG2 = 10,
  parameter [31:0]  RATE_MHZ   = 32'd15993859    // millihertz
) (
  input  wire        clk,
  input  wire        rst,
  // off-chip
  output wire        pdm_m_clk,
  input  wire        pdm_m_data,
  // register port
  input  wire [3:0]  reg_addr,
  input  wire        reg_wr,
  input  wire [31:0] reg_wdata,
  input  wire        reg_rd,
  output reg  [31:0] reg_rdata,
  // level-sensitive interrupt: FIFO at or above the watermark
  output wire        irq
);
  reg enable, dc_bypass;
  reg [FIFO_ALOG2:0] watermark;
  reg fifo_rst_pulse, clear_pulse;

  wire               pcm_valid;
  wire signed [15:0] pcm_data;
  wire               settling, saturated_raw;

  pdm_mic_capture #(
    .PDM_HALF(PDM_HALF), .CIC_R(CIC_R), .FIR_TAPS(FIR_TAPS),
    .FIR_DECIM(FIR_DECIM), .FIR_SHIFT(FIR_SHIFT), .SETTLE(SETTLE)
  ) u_cap (
    .clk(clk), .rst(rst), .enable(enable), .dc_bypass(dc_bypass),
    .pdm_m_clk(pdm_m_clk), .pdm_m_data(pdm_m_data),
    .pcm_valid(pcm_valid), .pcm_data(pcm_data),
    .settling(settling), .saturated(saturated_raw));

  wire [15:0]           fifo_q;
  wire                  fifo_empty, fifo_full, fifo_overrun;
  wire [FIFO_ALOG2:0]   fifo_level;
  wire                  data_read = reg_rd && (reg_addr == 4'h4);

  pdm_mic_fifo #(.DW(16), .ALOG2(FIFO_ALOG2)) u_fifo (
    .clk(clk), .rst(rst || fifo_rst_pulse), .wr_en(pcm_valid), .wr_data(pcm_data),
    .rd_en(data_read), .rd_data(fifo_q), .empty(fifo_empty), .full(fifo_full),
    .level(fifo_level), .overrun(fifo_overrun));

  reg sat_sticky;
  always @(posedge clk) begin
    if (rst || clear_pulse) sat_sticky <= 1'b0;
    else if (saturated_raw) sat_sticky <= 1'b1;
  end

  assign irq = (fifo_level >= watermark) && (watermark != 0);

  always @(posedge clk) begin
    if (rst) begin
      enable <= 1'b0; dc_bypass <= 1'b0;
      watermark <= 0; fifo_rst_pulse <= 1'b0; clear_pulse <= 1'b0;
    end else begin
      fifo_rst_pulse <= 1'b0;
      clear_pulse    <= 1'b0;
      if (reg_wr) begin
        case (reg_addr)
          4'h1: begin                       // CTRL
            enable         <= reg_wdata[0];
            fifo_rst_pulse <= reg_wdata[1];
            dc_bypass      <= reg_wdata[2];
            clear_pulse    <= reg_wdata[3];
          end
          4'h7: watermark <= reg_wdata[FIFO_ALOG2:0];
          default: ;
        endcase
      end
    end
  end

  always @(*) begin
    case (reg_addr)
      4'h0: reg_rdata = 32'h504D4331;
      4'h1: reg_rdata = {28'd0, 1'b0, dc_bypass, 1'b0, enable};
      4'h2: reg_rdata = {27'd0, sat_sticky, fifo_overrun, fifo_full, fifo_empty, settling};
      4'h3: reg_rdata = {{(31-FIFO_ALOG2){1'b0}}, fifo_level};
      4'h4: reg_rdata = fifo_empty ? 32'd0 : {{16{fifo_q[15]}}, fifo_q};
      4'h5: reg_rdata = RATE_MHZ;
      4'h6: reg_rdata = 32'd1 << FIFO_ALOG2;
      4'h7: reg_rdata = {{(31-FIFO_ALOG2){1'b0}}, watermark};
      default: reg_rdata = 32'hDEADBEEF;
    endcase
  end
endmodule
