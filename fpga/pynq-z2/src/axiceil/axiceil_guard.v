// axiceil_guard -- a hard address firewall between a PL master and an S_AXI_HP port, and the
// registered slice that drives the port's AW and AR pins.
//
// The HP ports reach ALL of PS DDR, and Linux is running on the bottom half of it.  One
// wrong AWADDR from the fabric overwrites kernel memory with no fault anywhere.  PYNQ here
// boots with `mem=256M`, so the only DDR the PL may touch is physical
// 0x1000_0000 .. 0x1FFF_FFFF (host/run_rocket.py explains the same window for the SoC).
//
// This module does not trust the master behind it or the host that configured it.  A request
// is ACCEPTED from the master only if the WHOLE burst lies inside that window and it is a
// plain 8-byte INCR burst:
//
//     addr[31:28] == 4'h1                           starts inside the window
//     addr[2:0]   == 0, size == 3'b011, burst == INCR
//     end = addr + (len+1)*8 <= 0x2000_0000         the last byte is inside too
//     addr[11:0] + (len+1)*8 <= 4096                it does not cross a 4 KiB boundary (v5)
//
// The end test needs no wide adder: a <=16-beat burst spans at most 128 bytes, so it can
// only cross 0x2000_0000 when addr[27:7] is all ones, and then only by the low 7 bits.
//
// A refused request is never accepted (READY stays low for it), so it never enters the slice
// and never reaches the PS; the master stalls on it and the host sees a timeout plus `fault`
// and the address.  W beats already sent for a refused AW sit in the AFI's write FIFO with no
// command to release them; nothing reaches DDR without an AW.
//
// v2 (build 2): the check sits in front of a two-register skid slice, so the PS7's AWVALID /
// ARVALID / address pins are driven straight from flops.  Build 1 had the check between the
// master's flops and the pins, and its worst PS7-boundary path (5.8 ns into SAXIHP0ARVALID)
// was that logic plus the route to the PS corner.  The slice changes no ordering and adds one
// cycle of latency; it holds at most two requests, which the master counts as outstanding.

module axiceil_guard (
  input  wire        clk,
  input  wire        rst,
  // from the master
  input  wire [5:0]  s_awid,    input wire [31:0] s_awaddr, input wire [3:0] s_awlen,
  input  wire [2:0]  s_awsize,  input wire [1:0]  s_awburst,
  input  wire        s_awvalid, output wire s_awready,
  input  wire [5:0]  s_arid,    input wire [31:0] s_araddr, input wire [3:0] s_arlen,
  input  wire [2:0]  s_arsize,  input wire [1:0]  s_arburst,
  input  wire        s_arvalid, output wire s_arready,
  // to the PS
  output wire [5:0]  m_awid,    output wire [31:0] m_awaddr, output wire [3:0] m_awlen,
  output wire        m_awvalid, input  wire m_awready,
  output wire [5:0]  m_arid,    output wire [31:0] m_araddr, output wire [3:0] m_arlen,
  output wire        m_arvalid, input  wire m_arready,
  // sticky report
  output reg         fault = 1'b0,
  output reg  [31:0] fault_addr = 32'd0,
  output reg         fault_is_write = 1'b0
);
  function ok(input [31:0] a, input [3:0] len, input [2:0] size, input [1:0] burst);
    reg [7:0]  endlow;
    reg [12:0] endpage;
    begin
      endlow  = {1'b0, a[6:0]} + {({1'b0, len} + 5'd1), 3'b000};   // <= 127 + 128: 8 bits suffice
      endpage = {1'b0, a[11:0]} + {5'd0, ({1'b0, len} + 5'd1), 3'b000};
      ok = (a[31:28] == 4'h1) && (a[2:0] == 3'd0) && (size == 3'b011) && (burst == 2'b01)
           && (!(&a[27:7]) || (endlow <= 8'd128)) && (endpage <= 13'd4096);
    end
  endfunction

  wire aw_ok = ok(s_awaddr, s_awlen, s_awsize, s_awburst);
  wire ar_ok = ok(s_araddr, s_arlen, s_arsize, s_arburst);
  wire aw_in_ready, ar_in_ready;
  assign s_awready = aw_in_ready & aw_ok;
  assign s_arready = ar_in_ready & ar_ok;

  axiceil_skid #(.W(42)) u_aw (
    .clk(clk), .rst(rst),
    .s_valid(s_awvalid & aw_ok), .s_ready(aw_in_ready), .s_data({s_awid, s_awaddr, s_awlen}),
    .m_valid(m_awvalid), .m_ready(m_awready), .m_data({m_awid, m_awaddr, m_awlen}));
  axiceil_skid #(.W(42)) u_ar (
    .clk(clk), .rst(rst),
    .s_valid(s_arvalid & ar_ok), .s_ready(ar_in_ready), .s_data({s_arid, s_araddr, s_arlen}),
    .m_valid(m_arvalid), .m_ready(m_arready), .m_data({m_arid, m_araddr, m_arlen}));

  always @(posedge clk) begin
    if (rst) begin
      fault <= 1'b0; fault_addr <= 32'd0; fault_is_write <= 1'b0;
    end else if (!fault) begin
      if (s_awvalid && !aw_ok) begin
        fault <= 1'b1; fault_addr <= s_awaddr; fault_is_write <= 1'b1;
      end else if (s_arvalid && !ar_ok) begin
        fault <= 1'b1; fault_addr <= s_araddr; fault_is_write <= 1'b0;
      end
    end
  end
endmodule

// A two-register AXI slice: output VALID and DATA come straight from flops, input READY is a
// flop too, and it passes one item per cycle when the far side never stalls.
module axiceil_skid #(parameter integer W = 8) (
  input  wire         clk,
  input  wire         rst,
  input  wire         s_valid,
  output wire         s_ready,
  input  wire [W-1:0] s_data,
  output reg          m_valid = 1'b0,
  input  wire         m_ready,
  output reg  [W-1:0] m_data = {W{1'b0}}
);
  reg         sk_valid = 1'b0;
  reg [W-1:0] sk_data = {W{1'b0}};
  assign s_ready = ~sk_valid;
  wire take = s_valid & ~sk_valid;
  always @(posedge clk) begin
    if (rst) begin
      m_valid <= 1'b0; sk_valid <= 1'b0;
    end else if (m_valid && m_ready) begin
      if (sk_valid) begin
        m_data <= sk_data; sk_valid <= 1'b0;
      end else if (take) begin
        m_data <= s_data;
      end else begin
        m_valid <= 1'b0;
      end
    end else if (!m_valid) begin
      if (take) begin m_valid <= 1'b1; m_data <= s_data; end
    end else if (take) begin                // m_valid && !m_ready
      sk_valid <= 1'b1; sk_data <= s_data;
    end
  end
endmodule
