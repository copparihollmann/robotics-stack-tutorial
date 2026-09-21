// HM01B0SimModel: a SIMULATION-ONLY stand-in for the Himax HM01B0 on the Z1 camera shield.
//
// It is instantiated by chipyard.WithHM01B0SimModel (fpga/pynq-z2/chipyard/PynqZ2Configs.scala)
// in the Chipyard TestHarness of PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig, in place
// of a tie-off, and connected to ChipTop's ospi_sensor_* and i2c_0_* ports.  It is a plain
// BlackBox: this file is handed to Verilator by scripts/65_cam_rtl_sim.sh and is never read by
// Vivado (the bitstream is built from *.top.f, which is ChipTop and below).
//
// WHAT IT MODELS, AND WHAT IT DOES NOT.  It is shaped like the sensor where the RTL and the driver
// can tell the difference, and simplified everywhere else:
//
//   * I2C slave at 7-bit address 0x24, 16-bit register addresses, 8-bit data, register pointer
//     auto-increment on sequential reads and writes.  MODEL_ID 0x0000/0x0001 = 0x01/0xB0 (the
//     HM01B0's).  MODE_SELECT 0x0100: bit 0 set = stream continuously, clear = standby after the
//     current frame.  Every other address is ACKed; writes are counted and ignored, reads return 0.
//     Any other slave address is NACKed, i.e. SDA is left released.
//     Model-only diagnostics (NOT HM01B0 registers; nothing on the board may use them):
//       0xFF00 TRIG rising edges seen (8 bits)   0xFF01 MCLK has toggled (bit 0)
//       0xFF02 frames completed (8 bits)         0xFF03 register writes accepted (8 bits)
//       0xFF04/0xFF05 SCL rising edges seen (16 bits, big-endian; reading 0xFF04 latches the
//       low byte for 0xFF05, so a sequential two-byte read is one sample)
//       0xFF06/0xFF07 the SHORTEST SCL period seen, in MCLK rising edges (16 bits, big-endian).
//       Within a byte the TLI2C clocks nine bits with no software in between, so the minimum is
//       the controller's own bit period; with MCLKDIV = 0 one MCLK period is two SoC clock cycles.
//   * Video on MCLK: PCLK = MCLK / 2, and only while streaming -- held low in standby, which is
//     what makes the idle diagnostic (PCLKCNT = FVLDCNT = LVLDCNT = 0) meaningful in simulation.
//     D/FVLD/LVLD change on PCLK's FALLING edge and are sampled by the RTL on the rising edge.
//     Geometry is fixed by the parameters, not by the sensor's window registers.  Each frame is
//     VBLANK lines with FVLD low, then HEIGHT lines with FVLD high; each active line has HFP PCLKs
//     with LVLD low, WIDTH pixels, then the rest of HBLANK with LVLD low, so FVLD falls HBLANK-HFP
//     PCLKs after the last pixel -- the CaptureFrontend needs FVLD to fall AFTER LVLD, or the EOF
//     marker lands on the last pixel's beat.  Streaming starts with a blank period, so the first
//     frame after MODE_SELECT is always whole.
//   * Pixel (x, y) of frame f is ((x*7) ^ (y*13) ^ f) & 0xFF.  Pixel (0,0) is therefore the frame
//     number, and a reader can check every other byte of a frame against it.
//   * INT is held low.  TRIG is only counted.
module HM01B0SimModel #(
  parameter WIDTH  = 32,
  parameter HEIGHT = 24,
  parameter HFP    = 4,
  parameter HBLANK = 16,
  parameter VBLANK = 6
) (
  input            reset,       // harness reset, active high
  input            i2c_clock,   // oversampling clock for the I2C slave (the harness clock)
  // video, from the FPGA's point of view: mclk/trig come in, the rest goes out
  input            mclk,
  input            trig,
  output           pclk,
  output reg       fvld,
  output reg       lvld,
  output reg [7:0] d,
  output           intr,
  // TLI2C pins.  The controller drives *_out = 0 and signals the drive on *_oe (open drain).
  input            scl_out,
  input            scl_oe,
  input            sda_out,
  input            sda_oe,
  output           scl_in,
  output           sda_in
);
  localparam [6:0] I2C_ADDR = 7'h24;

  // ------------------------------------------------------------------------------------------
  // The bus: wired-AND with pull-ups (the Z1's 2.2 k on SDA/SCL).
  // ------------------------------------------------------------------------------------------
  reg  slave_sda_low;
  wire scl_line = ~(scl_oe & ~scl_out);
  wire sda_line = ~(sda_oe & ~sda_out) & ~slave_sda_low;
  assign scl_in = scl_line;
  assign sda_in = sda_line;
  assign intr   = 1'b0;

  // ------------------------------------------------------------------------------------------
  // Registers and model-only counters.
  // ------------------------------------------------------------------------------------------
  reg  [7:0] mode_select;
  reg  [7:0] writes;
  reg  [7:0] trig_count;
  reg        mclk_seen;
  reg  [7:0] frames_done;
  reg [15:0] scl_rises_q = 16'd0;
  wire [15:0] scl_rises = scl_rises_q;
  reg  [7:0] scl_snap;

  reg  [1:0] mclk_s;                  // resynchronised into i2c_clock for readback
  reg  [7:0] frames_s0, frames_s1, trig_s0, trig_s1;
  always @(posedge i2c_clock) begin
    trig_s0 <= trig_count;  trig_s1 <= trig_s0;
    frames_s0 <= frames_done; frames_s1 <= frames_s0;
    mclk_s <= {mclk_s[0], mclk_seen};
  end

  reg [15:0] ptr;
  function [7:0] rdata(input [15:0] a);
    case (a)
      16'h0000: rdata = 8'h01;        // MODEL_ID_H
      16'h0001: rdata = 8'hB0;        // MODEL_ID_L
      16'h0100: rdata = mode_select;  // MODE_SELECT
      16'hFF00: rdata = trig_s1;
      16'hFF01: rdata = {7'd0, mclk_s[1]};
      16'hFF02: rdata = frames_s1;
      16'hFF03: rdata = writes;
      16'hFF04: rdata = scl_rises[15:8];
      16'hFF05: rdata = scl_snap;
      16'hFF06: rdata = scl_min_s[15:8];
      16'hFF07: rdata = scl_min_s[7:0];
      default:  rdata = 8'h00;
    endcase
  endfunction
  wire [7:0] rd = rdata(ptr);

  // ------------------------------------------------------------------------------------------
  // I2C slave, oversampled.  SDA only ever changes here while SCL is low (on a detected fall),
  // so the slave cannot manufacture a START or STOP.
  // ------------------------------------------------------------------------------------------
  reg [1:0] scl_q, sda_q;             // [0] newest
  always @(posedge i2c_clock) begin
    scl_q <= {scl_q[0], scl_line};
    sda_q <= {sda_q[0], sda_line};
  end
  wire i2c_start = scl_q[0] & scl_q[1] &  sda_q[1] & ~sda_q[0];
  wire i2c_stop  = scl_q[0] & scl_q[1] & ~sda_q[1] &  sda_q[0];
  wire scl_rise  =  scl_q[0] & ~scl_q[1];
  wire scl_fall  = ~scl_q[0] &  scl_q[1];
  wire sda_bit   =  sda_q[0];

  always @(posedge i2c_clock) if (!reset && scl_rise) scl_rises_q <= scl_rises_q + 16'd1;

  localparam S_IDLE = 3'd0, S_ADDR = 3'd1, S_AACK = 3'd2, S_WR = 3'd3,
             S_WACK = 3'd4, S_RD   = 3'd5, S_RACK = 3'd6;
  reg [2:0] st;
  reg [3:0] nbit;
  reg [7:0] sh;
  reg       rnw, mack;
  reg [1:0] widx;

  always @(posedge i2c_clock) begin
    if (reset) begin
      st <= S_IDLE; slave_sda_low <= 1'b0; nbit <= 4'd0; sh <= 8'd0; rnw <= 1'b0; mack <= 1'b0;
      widx <= 2'd0; ptr <= 16'd0; mode_select <= 8'd0; writes <= 8'd0; scl_snap <= 8'd0;
    end else if (i2c_start) begin
      st <= S_ADDR; nbit <= 4'd0; slave_sda_low <= 1'b0; widx <= 2'd0;
    end else if (i2c_stop) begin
      st <= S_IDLE; slave_sda_low <= 1'b0;
    end else begin
      case (st)
        S_ADDR:
          if (scl_rise) begin
            sh <= {sh[6:0], sda_bit}; nbit <= nbit + 4'd1;
          end else if (scl_fall && nbit == 4'd8) begin
            if (sh[7:1] == I2C_ADDR) begin
              slave_sda_low <= 1'b1; rnw <= sh[0]; st <= S_AACK;
            end else begin
              st <= S_IDLE;                                    // not us: NACK by silence
            end
          end
        S_AACK:
          if (scl_fall) begin
            if (rnw) begin
              sh <= rd; slave_sda_low <= ~rd[7]; nbit <= 4'd1; st <= S_RD;
              if (ptr == 16'hFF04) scl_snap <= scl_rises[7:0];
            end else begin
              slave_sda_low <= 1'b0; nbit <= 4'd0; st <= S_WR;
            end
          end
        S_WR:
          if (scl_rise) begin
            sh <= {sh[6:0], sda_bit}; nbit <= nbit + 4'd1;
          end else if (scl_fall && nbit == 4'd8) begin
            slave_sda_low <= 1'b1; st <= S_WACK;
            case (widx)
              2'd0:    begin ptr[15:8] <= sh; widx <= 2'd1; end
              2'd1:    begin ptr[7:0]  <= sh; widx <= 2'd2; end
              default: begin
                writes <= writes + 8'd1;
                if (ptr == 16'h0100) mode_select <= sh;
                ptr <= ptr + 16'd1;
              end
            endcase
          end
        S_WACK:
          if (scl_fall) begin slave_sda_low <= 1'b0; nbit <= 4'd0; st <= S_WR; end
        S_RD:
          if (scl_fall) begin
            if (nbit == 4'd8) begin
              slave_sda_low <= 1'b0; ptr <= ptr + 16'd1; st <= S_RACK;   // release for the master's ACK
            end else begin
              slave_sda_low <= ~sh[3'd7 - nbit[2:0]]; nbit <= nbit + 4'd1;
            end
          end
        S_RACK:
          if (scl_rise) begin
            mack <= ~sda_bit;
          end else if (scl_fall) begin
            if (mack) begin
              sh <= rd; slave_sda_low <= ~rd[7]; nbit <= 4'd1; st <= S_RD;
              if (ptr == 16'hFF04) scl_snap <= scl_rises[7:0];
            end
            else st <= S_IDLE;
          end
        default: st <= S_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------------------------------
  // Video on MCLK.
  // ------------------------------------------------------------------------------------------
  always @(posedge trig or posedge reset)
    if (reset) trig_count <= 8'd0; else trig_count <= trig_count + 8'd1;

  reg [1:0] stream_q;
  always @(posedge mclk or posedge reset)
    if (reset) begin stream_q <= 2'b00; mclk_seen <= 1'b0; end
    else begin stream_q <= {stream_q[0], mode_select[0]}; mclk_seen <= 1'b1; end
  wire stream = stream_q[1];

  // SCL period in MCLK edges: SCL resampled on MCLK, count MCLK edges between SCL rising edges,
  // keep the minimum.  Resampling costs at most one MCLK edge of error either way.
  reg  [2:0]  scl_m;
  reg  [15:0] scl_cnt, scl_min;
  reg         scl_seen;
  always @(posedge mclk or posedge reset)
    if (reset) begin scl_m <= 3'b111; scl_cnt <= 16'd0; scl_min <= 16'hFFFF; scl_seen <= 1'b0; end
    else begin
      scl_m <= {scl_m[1:0], scl_line};
      if (scl_m[1] & ~scl_m[2]) begin
        if (scl_seen && scl_cnt < scl_min) scl_min <= scl_cnt;
        scl_seen <= 1'b1;
        scl_cnt  <= 16'd1;
      end else if (scl_cnt != 16'hFFFF) begin
        scl_cnt <= scl_cnt + 16'd1;
      end
    end
  reg [15:0] scl_min_s0, scl_min_s;
  always @(posedge i2c_clock) begin scl_min_s0 <= scl_min; scl_min_s <= scl_min_s0; end

  localparam integer LINE = WIDTH + HBLANK;
  localparam integer ROWS = HEIGHT + VBLANK;

  reg        pclk_r, running;
  reg [15:0] col, row;
  reg [7:0]  frame;
  assign pclk = pclk_r;

  wire [15:0] x = col - HFP;
  wire in_fv = (row < HEIGHT);
  wire in_lv = in_fv && (col >= HFP) && (col < HFP + WIDTH);
  wire [7:0] pix = (x[7:0] * 8'd7) ^ (row[7:0] * 8'd13) ^ frame;

  always @(posedge mclk or posedge reset) begin
    if (reset) begin
      pclk_r <= 1'b0; running <= 1'b0; col <= 16'd0; row <= 16'd0; frame <= 8'd0;
      frames_done <= 8'd0; fvld <= 1'b0; lvld <= 1'b0; d <= 8'd0;
    end else if (!running) begin
      pclk_r <= 1'b0;
      if (stream) begin running <= 1'b1; col <= 16'd0; row <= HEIGHT; end   // blank lines first
    end else begin
      pclk_r <= ~pclk_r;
      if (pclk_r) begin
        // PCLK falls on this MCLK edge: present position (col, row), then advance.
        fvld <= in_fv;
        lvld <= in_lv;
        d    <= in_lv ? pix : 8'h00;
        if (row == HEIGHT - 1 && col == LINE - 1) begin
          frame <= frame + 8'd1; frames_done <= frames_done + 8'd1;
        end
        if (col == LINE - 1) begin
          col <= 16'd0;
          if (row == ROWS - 1) begin
            row <= 16'd0;
            if (!stream) running <= 1'b0;    // stop only at the end of a blank period
          end else begin
            row <= row + 16'd1;
          end
        end else begin
          col <= col + 16'd1;
        end
      end
    end
  end
endmodule
