// SoC control/status registers on PS7 M_AXI_GP0.
//
//   0x00 CTRL   RW: [0] soc_resetn  (0 = Rocket held in reset; power-up default)
//                   [1] custom_boot (ChipTop boot-select pin)
//   0x04 STATUS R : [0] alive  [1] soc_resetn  [2] saw_mem  [3] err_burst_too_long
//   0x08 MAGIC  R : the MAGIC parameter -- distinguishes which bitstream is loaded.
//                   0x5A5A0001 DRAM self-test (a different register file entirely)
//                   0x5A5A0002 single-core Rocket + TACIT      (default, do not change)
//                   0x5A5A0003 dual-core big.LITTLE + TACIT
//                   0x5A5A0004 ... + MBP packed SIMD on hart 0
//                   0x5A5A0005 ... + the PDM microphone at 0x1009_0000
//                   Every Rocket bitstream here is pin- and register-compatible with
//                   every other, so without a distinct MAGIC a run against the wrong
//                   one boots happily and is silently single-core, or silently without
//                   the SIMD unit, or silently reading zeros from a microphone that is
//                   not there. That is exactly the failure this is here to catch.
//
// Rocket comes out of configuration held in reset on purpose: the PS has to be able to
// place a program in DDR before the core starts fetching.

module soc_ctrl_regs #(
  parameter integer ADDR_W = 32,
  parameter integer ID_W   = 12,
  parameter [31:0]  MAGIC  = 32'h5A5A_0002
)(
  input  wire              clk, rstn,
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
  output reg  [31:0]       s_rdata,   // combinational, driven only by the always @(*)
  output reg  [1:0]        s_rresp,
  // See axi_ctrl_regs.v: an undriven RID hangs the PS7 GP0 master permanently.
  output reg  [ID_W-1:0]   s_rid,
  output reg               s_rlast,  output reg              s_rvalid,
  input  wire              s_rready,

  output reg               soc_resetn = 1'b0,   // held in reset at power-up
  output reg               custom_boot = 1'b0,
  input  wire              err_burst_too_long,
  input  wire [31:0]       status
);
  reg [ADDR_W-1:0] awaddr_q = 0, araddr_q = 0;
  reg [7:0]        arbeats_q = 0;

  // AW and W are independent channels and AXI allows write data before its address; the
  // PS7 GP0 master does that. Decoding W against a registered AW alone therefore writes to
  // whatever register the previous transaction addressed. See axi_ctrl_regs.v -- the same
  // bug there silently dropped the start bit. Hold s_wready low until AW is in hand.
  reg aw_full;

  always @(posedge clk) begin
    if (!rstn) begin
      s_awready <= 1'b1; s_wready <= 1'b0; s_bvalid <= 0; s_bresp <= 2'b00;
      s_bid <= {ID_W{1'b0}}; aw_full <= 1'b0;
      soc_resetn <= 1'b0; custom_boot <= 1'b0; awaddr_q <= 0;
    end else begin
      if (s_awvalid && s_awready) begin
        awaddr_q  <= s_awaddr; s_bid <= s_awid;
        aw_full   <= 1'b1;
        s_awready <= 1'b0;
        s_wready  <= 1'b1;
      end

      if (aw_full && s_wvalid && s_wready) begin
        if (awaddr_q[7:2] == 6'h00 && s_wstrb[0]) begin
          soc_resetn  <= s_wdata[0];
          custom_boot <= s_wdata[1];
        end
        awaddr_q <= awaddr_q + 32'd4;
        if (s_wlast) begin
          s_wready <= 1'b0; aw_full <= 1'b0;
          s_bvalid <= 1'b1; s_bresp <= 2'b00;
        end
      end

      if (s_bvalid && s_bready) begin
        s_bvalid  <= 1'b0;
        s_awready <= 1'b1;
      end
    end
  end

  always @(posedge clk) begin
    if (!rstn) begin
      s_arready <= 0; s_rvalid <= 0; s_rresp <= 2'b00; s_rlast <= 0;
      araddr_q <= 0; arbeats_q <= 0; s_rid <= {ID_W{1'b0}};
    end else begin
      s_arready <= (!s_arready && s_arvalid && !s_rvalid);
      if (s_arvalid && s_arready) begin
        araddr_q <= s_araddr; arbeats_q <= s_arlen; s_rid <= s_arid;
        s_rvalid <= 1'b1; s_rlast <= (s_arlen == 8'd0); s_rresp <= 2'b00;
      end else if (s_rvalid && s_rready) begin
        if (arbeats_q == 8'd0) begin s_rvalid <= 0; s_rlast <= 0; end
        else begin
          arbeats_q <= arbeats_q - 8'd1;
          araddr_q  <= araddr_q + 32'd4;
          s_rlast   <= (arbeats_q == 8'd1);
        end
      end
    end
  end

  always @(*) begin
    case (araddr_q[7:2])
      6'h00:   s_rdata = {30'd0, custom_boot, soc_resetn};
      6'h01:   s_rdata = status;
      6'h02:   s_rdata = MAGIC;
      default: s_rdata = 32'hDEAD_BEEF;
    endcase
  end
endmodule
