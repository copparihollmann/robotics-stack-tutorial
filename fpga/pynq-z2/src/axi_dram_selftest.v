// AXI4 DRAM self-test master.
//
// Stands in for the SoC's memory port and exercises the exact path that has never been
// tested on this board: PL master -> S_AXI_HP0 -> PS DDR controller -> DDR3.
//
// Traffic is shaped like Rocket's: 64-bit data, 8-beat INCR bursts (a 64 B cacheline).
// Writes a position-dependent pattern over a region, reads it back, and counts mismatches.
// Everything is reported through registers the PS can read over M_AXI_GP0, and mirrored
// onto LEDs so the board self-reports with nothing attached.
//
// Deliberately single-outstanding: correctness of the path is the question here, not
// bandwidth. One transaction in flight makes the handshake logic simple enough to audit.

module axi_dram_selftest #(
  parameter integer ADDR_W   = 32,
  parameter integer DATA_W   = 64,
  parameter integer ID_W     = 6,
  parameter [7:0]   BURSTLEN = 8'd7   // AXI AWLEN: beats-1, so 7 == 8 beats == 64 B
)(
  input  wire                 clk,
  input  wire                 rstn,

  // control (from the AXI-Lite register file)
  input  wire                 start,       // pulse
  input  wire [ADDR_W-1:0]    base_addr,   // PS-side physical address
  input  wire [31:0]          num_bursts,
  output reg                  busy = 1'b0,
  output reg                  done = 1'b0,
  output reg  [31:0]          err_count = 32'd0,
  output reg  [31:0]          beats_done = 32'd0,

  // AXI4 master -> S_AXI_HP0
  output reg  [ID_W-1:0]      m_awid = {ID_W{1'b0}}, output reg [ADDR_W-1:0] m_awaddr = {ADDR_W{1'b0}},
  output reg  [7:0]           m_awlen = 8'd0, output wire [2:0]       m_awsize,
  output wire [1:0]           m_awburst, output reg             m_awvalid = 1'b0,
  input  wire                 m_awready,
  output reg  [DATA_W-1:0]    m_wdata = {DATA_W{1'b0}}, output wire [DATA_W/8-1:0] m_wstrb,
  output reg                  m_wlast = 1'b0, output reg              m_wvalid = 1'b0,
  input  wire                 m_wready,
  input  wire [ID_W-1:0]      m_bid,    input  wire [1:0]       m_bresp,
  input  wire                 m_bvalid, output wire             m_bready,
  output reg  [ID_W-1:0]      m_arid = {ID_W{1'b0}}, output reg [ADDR_W-1:0] m_araddr = {ADDR_W{1'b0}},
  output reg  [7:0]           m_arlen = 8'd0, output wire [2:0]       m_arsize,
  output wire [1:0]           m_arburst, output reg             m_arvalid = 1'b0,
  input  wire                 m_arready,
  input  wire [DATA_W-1:0]    m_rdata,  input  wire [1:0]       m_rresp,
  input  wire                 m_rlast,  input  wire             m_rvalid,
  output wire                 m_rready
);

  localparam S_IDLE_INIT = 4'd0;
  localparam [2:0] SZ = (DATA_W == 64) ? 3'b011 : 3'b010;  // 8 bytes/beat
  assign m_awsize  = SZ;
  assign m_arsize  = SZ;
  assign m_awburst = 2'b01;   // INCR
  assign m_arburst = 2'b01;
  assign m_wstrb   = {(DATA_W/8){1'b1}};
  assign m_bready  = 1'b1;
  assign m_rready  = 1'b1;

  // Pattern is a pure function of the beat index, so the checker needs no golden buffer.
  function [DATA_W-1:0] pattern(input [31:0] idx);
    pattern = {~idx, idx} ^ 64'hA5A5_5A5A_C3C3_3C3C;
  endfunction

  localparam S_IDLE=4'd0, S_AW=4'd1, S_W=4'd2, S_B=4'd3,
             S_AR=4'd4, S_R=4'd5, S_NEXT=4'd6, S_DONE=4'd7;
  // Initialised at declaration so simulation matches FPGA power-up (Xilinx FFs come out
  // of configuration at their INIT value). Without this the AXI handshake outputs are X
  // at time 0 and the VIP protocol checker fires AXI4_ERRM_AWVALID_RESET before reset
  // has even been released.
  reg [3:0]  st       = 4'd0;   // S_IDLE
  reg [31:0] burst_i  = 32'd0;   // which burst
  reg [7:0]  beat_i   = 8'd0;    // beat within the burst
  reg [31:0] wr_total = 32'd0;   // running beat index, drives the pattern
  reg        phase    = 1'b0;    // 0 = write pass, 1 = read/verify pass

  wire [ADDR_W-1:0] burst_addr = base_addr + (burst_i * ((BURSTLEN+1) * (DATA_W/8)));

  always @(posedge clk) begin
    if (!rstn) begin
      st <= S_IDLE; busy <= 1'b0; done <= 1'b0; err_count <= 32'd0;
      beats_done <= 32'd0; burst_i <= 32'd0; beat_i <= 8'd0; wr_total <= 32'd0;
      phase <= 1'b0;
      m_awvalid <= 1'b0; m_wvalid <= 1'b0; m_arvalid <= 1'b0; m_wlast <= 1'b0;
      m_awid <= {ID_W{1'b0}}; m_arid <= {ID_W{1'b0}};
      m_awlen <= BURSTLEN; m_arlen <= BURSTLEN;
      m_awaddr <= {ADDR_W{1'b0}}; m_araddr <= {ADDR_W{1'b0}}; m_wdata <= {DATA_W{1'b0}};
    end else begin
      case (st)
        S_IDLE: begin
          done <= done;
          if (start) begin
            busy <= 1'b1; done <= 1'b0; err_count <= 32'd0; beats_done <= 32'd0;
            burst_i <= 32'd0; beat_i <= 8'd0; wr_total <= 32'd0; phase <= 1'b0;
            st <= S_AW;
          end
        end

        // ---- write pass ----
        S_AW: begin
          m_awaddr  <= burst_addr;
          m_awlen   <= BURSTLEN;
          m_awvalid <= 1'b1;
          if (m_awvalid && m_awready) begin
            m_awvalid <= 1'b0;
            beat_i    <= 8'd0;
            m_wdata   <= pattern(wr_total);
            m_wlast   <= (BURSTLEN == 8'd0);
            m_wvalid  <= 1'b1;
            st        <= S_W;
          end
        end
        S_W: begin
          if (m_wvalid && m_wready) begin
            beats_done <= beats_done + 32'd1;
            if (beat_i == BURSTLEN) begin
              m_wvalid <= 1'b0; m_wlast <= 1'b0;
              wr_total <= wr_total + 32'd1;
              st <= S_B;
            end else begin
              beat_i   <= beat_i + 8'd1;
              wr_total <= wr_total + 32'd1;
              m_wdata  <= pattern(wr_total + 32'd1);
              m_wlast  <= ((beat_i + 8'd1) == BURSTLEN);
            end
          end
        end
        S_B: if (m_bvalid) begin
          if (m_bresp != 2'b00) err_count <= err_count + 32'd1;
          st <= S_NEXT;
        end

        // ---- read / verify pass ----
        S_AR: begin
          m_araddr  <= burst_addr;
          m_arlen   <= BURSTLEN;
          m_arvalid <= 1'b1;
          if (m_arvalid && m_arready) begin
            m_arvalid <= 1'b0; beat_i <= 8'd0; st <= S_R;
          end
        end
        S_R: if (m_rvalid) begin
          beats_done <= beats_done + 32'd1;
          if (m_rresp != 2'b00 || m_rdata != pattern(wr_total))
            err_count <= err_count + 32'd1;
          wr_total <= wr_total + 32'd1;
          if (m_rlast) st <= S_NEXT; else beat_i <= beat_i + 8'd1;
        end

        S_NEXT: begin
          if (burst_i + 32'd1 == num_bursts) begin
            if (phase == 1'b0) begin
              phase <= 1'b1; burst_i <= 32'd0; wr_total <= 32'd0; st <= S_AR;
            end else begin
              // Park in S_IDLE, not S_DONE. done stays set (S_IDLE holds it) so software
              // can still read the result, and the next start begins a run immediately.
              busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
            end
          end else begin
            burst_i <= burst_i + 32'd1;
            st <= (phase == 1'b0) ? S_AW : S_AR;
          end
        end

        // Unreachable now, but harmless and unconditional: a start arriving here used to
        // be swallowed moving back to S_IDLE, so every SECOND run silently did nothing.
        // MEASURED: 64 KiB passed, 256 KiB timed out, 1 MiB passed, 4 MiB timed out ...
        S_DONE: st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
