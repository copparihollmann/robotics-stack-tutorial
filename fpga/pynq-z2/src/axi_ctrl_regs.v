// Control/status register file on PS7 M_AXI_GP0.
//
// GP0 is AXI3 and software accesses are single-beat 32-bit, but burst-capable masters are
// handled anyway (INCR, incrementing address) so this cannot be tripped by a DMA engine or
// a cache line fill during bring-up.
//
//   0x00 CTRL    W: [0] start (self-clearing pulse)
//   0x04 BASE    RW: PS physical base address for the test region
//   0x08 NBURST  RW: number of 64 B bursts to write then verify
//   0x0C STATUS  R : [0] busy  [1] done
//   0x10 ERRCNT  R : mismatches + non-OKAY responses
//   0x14 BEATS   R : total AXI beats transferred
//   0x18 MAGIC   R : 0x5A5A0001 -- proves the PL is loaded and GP0 reaches it at all
//   0x1C RUNS    R : completed runs since reset
//
// RUNS exists so software can tell a finished run from a STALE one. STATUS.done stays set
// after a run, so a host that writes CTRL.start and immediately polls done reads the
// PREVIOUS run's result and reports an instant pass with the previous run's counters.
// MEASURED: that made the 256 KiB, 1 MiB, 4 MiB and 16 MiB tests all report exactly
// 65536 beats in "0.0 ms". Sample RUNS before starting and wait for it to change.

module axi_ctrl_regs #(
  parameter integer ADDR_W = 32,
  parameter integer ID_W   = 12
)(
  input  wire              clk,
  input  wire              rstn,

  input  wire [ID_W-1:0]   s_awid,   input wire [ADDR_W-1:0] s_awaddr,
  input  wire [7:0]        s_awlen,  input wire              s_awvalid,
  output reg               s_awready,
  input  wire [31:0]       s_wdata,  input wire [3:0]        s_wstrb,
  input  wire              s_wlast,  input wire              s_wvalid,
  output reg               s_wready,
  output reg  [ID_W-1:0]   s_bid,    output reg [1:0]        s_bresp,
  output reg               s_bvalid, input  wire             s_bready,
  input  wire [ID_W-1:0]   s_arid,   input wire [ADDR_W-1:0] s_araddr,
  input  wire [7:0]        s_arlen,  input wire              s_arvalid,
  output reg               s_arready,
  output reg  [31:0]       s_rdata,   // combinational: driven only by the always @(*) below
  output reg  [1:0]        s_rresp,
  // AXI3 requires the read response to carry back the ARID of the transaction. The PS7 GP0
  // master issues non-zero IDs and will never retire a read whose RID does not match, so
  // leaving this undriven hangs the CPU forever on the first register read.
  output reg  [ID_W-1:0]   s_rid,
  output reg               s_rlast,  output reg              s_rvalid,
  input  wire              s_rready,

  output reg               start,
  output reg  [31:0]       base_addr,
  output reg  [31:0]       num_bursts,
  input  wire              busy,
  input  wire              done,
  input  wire [31:0]       err_count,
  input  wire [31:0]       beats_done
);
  localparam [31:0] MAGIC = 32'h5A5A_0001;

  reg [ADDR_W-1:0] awaddr_q, araddr_q;
  reg [7:0]        arbeats_q;

  // Count completed runs by watching done's rising edge; the engine needs no change.
  reg        done_q    = 1'b0;
  reg [31:0] run_count = 32'd0;
  always @(posedge clk) begin
    if (!rstn) begin
      done_q <= 1'b0; run_count <= 32'd0;
    end else begin
      done_q <= done;
      if (done && !done_q) run_count <= run_count + 32'd1;
    end
  end

  // ---- write channel ----
  // AW and W are INDEPENDENT channels and AXI explicitly allows write data to arrive
  // before its address; the PS7 GP0 master does exactly that. Accepting W on its own and
  // decoding against a registered AW therefore writes to whatever register the PREVIOUS
  // transaction addressed. MEASURED: this sent the CTRL start bit into num_bursts, so the
  // engine sat idle (status=0x0, beats=0) and the test timed out. The fix is to hold
  // s_wready low until the address is in hand; stalling W that way is legal AXI.
  reg aw_full;

  always @(posedge clk) begin
    if (!rstn) begin
      s_awready <= 1'b1; s_wready <= 1'b0; s_bvalid <= 1'b0; s_bresp <= 2'b00;
      s_bid <= {ID_W{1'b0}}; start <= 1'b0; aw_full <= 1'b0;
      base_addr <= 32'h1000_0000;   // upper 256 MB of PS DDR: above Linux low memory
      num_bursts <= 32'd1024;       // 1024 * 64 B = 64 KB
      awaddr_q <= {ADDR_W{1'b0}};
    end else begin
      start <= 1'b0;                // one-cycle pulse

      if (s_awvalid && s_awready) begin
        awaddr_q  <= s_awaddr;
        s_bid     <= s_awid;
        aw_full   <= 1'b1;
        s_awready <= 1'b0;          // one write outstanding at a time
        s_wready  <= 1'b1;          // only now will this burst's data be taken
      end

      if (aw_full && s_wvalid && s_wready) begin
        case (awaddr_q[7:2])
          6'h00: if (s_wstrb[0]) start      <= s_wdata[0];
          6'h01:                 base_addr  <= s_wdata;
          6'h02:                 num_bursts <= s_wdata;
          default: ;
        endcase
        awaddr_q <= awaddr_q + 32'd4;      // INCR burst support
        if (s_wlast) begin
          s_wready <= 1'b0; aw_full <= 1'b0;
          s_bvalid <= 1'b1; s_bresp <= 2'b00;
        end
      end

      if (s_bvalid && s_bready) begin
        s_bvalid  <= 1'b0;
        s_awready <= 1'b1;          // ready for the next write transaction
      end
    end
  end

  // ---- read channel ----
  always @(posedge clk) begin
    if (!rstn) begin
      s_arready <= 1'b0; s_rvalid <= 1'b0; s_rresp <= 2'b00; s_rlast <= 1'b0;
      araddr_q <= {ADDR_W{1'b0}}; arbeats_q <= 8'd0;
      s_rid <= {ID_W{1'b0}};
    end else begin
      s_arready <= (!s_arready && s_arvalid && !s_rvalid);
      if (s_arvalid && s_arready) begin
        araddr_q  <= s_araddr;
        arbeats_q <= s_arlen;
        s_rid     <= s_arid;      // echoed on every beat of this burst
        s_rvalid  <= 1'b1;
        s_rlast   <= (s_arlen == 8'd0);
        s_rresp   <= 2'b00;
      end else if (s_rvalid && s_rready) begin
        if (arbeats_q == 8'd0) begin
          s_rvalid <= 1'b0; s_rlast <= 1'b0;
        end else begin
          arbeats_q <= arbeats_q - 8'd1;
          araddr_q  <= araddr_q + 32'd4;
          s_rlast   <= (arbeats_q == 8'd1);
        end
      end
    end
  end

  always @(*) begin
    case (araddr_q[7:2])
      6'h00: s_rdata = 32'd0;
      6'h01: s_rdata = base_addr;
      6'h02: s_rdata = num_bursts;
      6'h03: s_rdata = {30'd0, done, busy};
      6'h04: s_rdata = err_count;
      6'h05: s_rdata = beats_done;
      6'h06: s_rdata = MAGIC;
      6'h07: s_rdata = run_count;
      default: s_rdata = 32'hDEAD_BEEF;
    endcase
  end
endmodule
