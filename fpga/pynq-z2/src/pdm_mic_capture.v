// -----------------------------------------------------------------------------
// PDM microphone front end for the PYNQ-Z1's Knowles SPK0833LM4H-B.
//
// Two package pins, both in the PL (PYNQ-Z1 Reference Manual s13, and the pin
// numbers from Xilinx/PYNQ boards/Pynq-Z1/base/vivado/constraints/base.xdc):
//
//     F17  pdm_m_clk   out   the clock this block generates for the microphone
//     G18  pdm_m_data  in    the returned 1-bit bitstream
//
// The microphone's L/R SELECT is tied low ON THE BOARD, so there is no third pin and
// data is always presented on the RISING edge of the clock.  This block therefore
// samples on the FALLING edge -- half a PDM period, 203 ns, after the microphone
// launches the bit.  The round trip (IOB out, the part's ~20 ns data delay, IOB in)
// is well under 100 ns, so the sample point is not marginal; see MICROPHONE.md for
// the constraint that tells the timing engine so.
//
// There is exactly ONE clock in this design.  pdm_m_clk is an output SIGNAL derived
// from a counter on the system clock, not a clock the fabric runs on, and nothing
// here crosses a domain.  Resisting the urge to make a 2.46 MHz clock region is what
// keeps this block free of CDC and out of the way of a design already at 75% LUT.
//
//     FCLK0 = 34.482759 MHz  (1000 MHz / 29, the P-ext bitstream clock)
//     f_pdm = FCLK0/(2*PDM_HALF) = 2.463054 MHz   PDM_HALF=7, inside the 1-3.3 MHz
//                                                 range the reference manual gives
//     f_cic = f_pdm/22         = 111.957 kHz
//     f_pcm = f_cic/7          = 15.9939 kHz      -0.038% from 16 kHz
// -----------------------------------------------------------------------------
module pdm_mic_capture #(
  parameter integer PDM_HALF  = 7,        // system clocks per PDM half period
  parameter integer CIC_R     = 22,
  parameter integer CIC_W     = 20,
  parameter integer FIR_TAPS  = 289,
  parameter integer FIR_DECIM = 7,
  parameter integer FIR_SHIFT = 22,
  parameter integer SETTLE    = 131072    // PDM bits discarded after enable rises
) (
  input  wire                clk,
  input  wire                rst,          // synchronous, active high
  input  wire                enable,
  input  wire                dc_bypass,
  // off-chip
  output wire                pdm_m_clk,
  input  wire                pdm_m_data,
  // PCM
  output wire                pcm_valid,
  output wire signed [15:0]  pcm_data,
  output wire                settling,
  output wire                saturated
);
  localparam integer HW = (PDM_HALF < 4) ? 2 : $clog2(PDM_HALF);
  localparam integer SW = (SETTLE  < 4) ? 2 : $clog2(SETTLE + 1);

  // ---- PDM clock generation ---------------------------------------------------
  reg [HW-1:0] hcnt;
  reg          pclk;
  wire         half_done = (hcnt == PDM_HALF[HW-1:0] - 1'b1);

  always @(posedge clk) begin
    if (rst || !enable) begin
      hcnt <= 0;
      pclk <= 1'b0;
    end else if (half_done) begin
      hcnt <= 0;
      pclk <= ~pclk;
    end else begin
      hcnt <= hcnt + 1'b1;
    end
  end
  assign pdm_m_clk = pclk;

  // The microphone launches its bit on the rising edge of pdm_m_clk, so sample when
  // pclk is about to fall -- one system clock before the 1->0 transition, which is
  // when the synchroniser output is settled and still a whole half period away from
  // the next change.
  wire sample_now = enable && pclk && half_done;

  // ---- input synchroniser -----------------------------------------------------
  // Two flops.  The data is guaranteed stable for ~200 ns either side of the sample
  // point by the protocol, so this is belt-and-braces against board-level skew and a
  // place to hang the timing exception, not a real asynchronous crossing.
  (* ASYNC_REG = "TRUE" *) reg d_sync0, d_sync1;
  always @(posedge clk) begin
    d_sync0 <= pdm_m_data;
    d_sync1 <= d_sync0;
  end

  reg        bit_valid;
  reg        bit_data;
  always @(posedge clk) begin
    if (rst) begin bit_valid <= 1'b0; bit_data <= 1'b0; end
    else begin
      bit_valid <= sample_now;
      if (sample_now) bit_data <= d_sync1;
    end
  end

  // ---- settling ---------------------------------------------------------------
  // The part needs time to come out of standby once its clock starts, and the CIC
  // needs R*N bits to fill.  SETTLE PDM bits = 53 ms at 2.46 MHz.
  reg [SW-1:0] scnt;
  wire         settled = (scnt == SETTLE[SW-1:0]);
  assign settling = enable && !settled;

  always @(posedge clk) begin
    if (rst || !enable) scnt <= 0;
    else if (bit_valid && !settled) scnt <= scnt + 1'b1;
  end

  wire chain_rst = rst || !enable || !settled;

  // ---- CIC -> FIR -> DC blocker ------------------------------------------------
  wire                    cic_valid;
  wire signed [CIC_W-1:0] cic_data;

  pdm_cic4 #(.W(CIC_W), .R(CIC_R)) u_cic (
    .clk(clk), .rst(chain_rst),
    .in_valid(bit_valid && settled), .in_bit(bit_data),
    .out_valid(cic_valid), .out_data(cic_data));

  wire               fir_valid;
  wire signed [15:0] fir_data;

  pdm_fir_mac #(
    .DW(CIC_W), .NTAPS(FIR_TAPS), .DECIM(FIR_DECIM), .SHIFT(FIR_SHIFT)
  ) u_fir (
    .clk(clk), .rst(chain_rst),
    .in_valid(cic_valid), .in_data(cic_data),
    .out_valid(fir_valid), .out_data(fir_data), .saturated(saturated));

  pdm_dcblock u_dc (
    .clk(clk), .rst(chain_rst), .bypass(dc_bypass),
    .in_valid(fir_valid), .in_data(fir_data),
    .out_valid(pcm_valid), .out_data(pcm_data));
endmodule
