// SIMULATION ONLY.  The memory port of 0x5A5A0018/0019 as built after f7f01e0: the generated
// mbus coupler (TLWidthWidget16_3 128 -> 64, TLToAXI4, AXI4IdIndexer, AXI4UserYanker), wired
// exactly as MemoryBus.sv wires it (the coupler's tl_out loops into its own widget), then the
// repo's axi4_to_axi3 shim wired exactly as src/pynqz2_rocket_top.v wires u_bridge.  The C++
// side is a 128-bit TileLink master at the coupler's input and an AXI3 S_AXI_HP0 slave at the
// shim's output; the AXI4 signals between them are ChipTop's axi4_mem_0 port, brought out for
// checking.  See main.cpp.
module widthtb_top #(parameter integer SRC_W = 4) (
  input          clock,
  input          reset,
  // TileLink, 128-bit, into the coupler (what the mbus xbar drives)
  output         a_ready,
  input          a_valid,
  input  [2:0]   a_opcode,
  input  [2:0]   a_size,
  input  [SRC_W-1:0] a_source,
  input  [31:0]  a_address,
  input  [15:0]  a_mask,
  input  [127:0] a_data,
  input          d_ready,
  output         d_valid,
  output [2:0]   d_opcode,
  output [2:0]   d_size,
  output [SRC_W-1:0] d_source,
  output         d_denied,
  output [127:0] d_data,
  // ChipTop.axi4_mem_0, observed
  output         x_awvalid, x_awready, x_wvalid, x_wready, x_wlast, x_bvalid, x_bready,
  output         x_arvalid, x_arready, x_rvalid, x_rready, x_rlast,
  output [3:0]   x_awid, x_arid,
  output [31:0]  x_awaddr, x_araddr,
  output [7:0]   x_awlen, x_arlen,
  output [2:0]   x_awsize, x_arsize,
  output [1:0]   x_awburst, x_arburst,
  output [63:0]  x_wdata, x_rdata,
  output [7:0]   x_wstrb,
  // S_AXI_HP0 (AXI3, 6-bit ID), driven by C++
  output [5:0]   h_awid, h_arid, h_wid,
  output [31:0]  h_awaddr, h_araddr,
  output [3:0]   h_awlen, h_arlen,
  output [2:0]   h_awsize, h_arsize,
  output         h_awvalid, h_wvalid, h_wlast, h_bready, h_arvalid, h_rready,
  output [63:0]  h_wdata,
  output [7:0]   h_wstrb,
  input          h_awready, h_wready, h_bvalid, h_arready, h_rvalid, h_rlast,
  input  [5:0]   h_bid, h_rid,
  input  [1:0]   h_bresp, h_rresp,
  input  [63:0]  h_rdata,
  output         err_burst_too_long
);
  // coupler loop: tl_out -> widget in (MemoryBus.sv)
  wire         lo_a_valid, lo_a_corrupt, lo_d_ready, wi_a_ready, wi_d_valid, wi_d_denied, wi_d_corrupt;
  wire [2:0]   lo_a_opcode, lo_a_param, lo_a_size, wi_d_opcode, wi_d_size;
  wire [SRC_W-1:0] lo_a_source, wi_d_source;
  wire [31:0]  lo_a_address;
  wire [15:0]  lo_a_mask;
  wire [127:0] lo_a_data, wi_d_data;
  wire [3:0]   m_bid, m_rid, m_awid, m_arid;
  wire [1:0]   m_bresp, m_rresp;
  wire         m_awlock, m_arlock;
  wire [3:0]   m_awcache, m_arcache, m_awqos, m_arqos;
  wire [2:0]   m_awprot, m_arprot;

  TLInterconnectCoupler_mbus_to_memory_controller_port_named_axi4 dut (
    .clock(clock), .reset(reset),
    .auto_widget_anon_in_a_ready(wi_a_ready),
    .auto_widget_anon_in_a_valid(lo_a_valid), .auto_widget_anon_in_a_bits_opcode(lo_a_opcode),
    .auto_widget_anon_in_a_bits_param(lo_a_param), .auto_widget_anon_in_a_bits_size(lo_a_size),
    .auto_widget_anon_in_a_bits_source(lo_a_source), .auto_widget_anon_in_a_bits_address(lo_a_address),
    .auto_widget_anon_in_a_bits_mask(lo_a_mask), .auto_widget_anon_in_a_bits_data(lo_a_data),
    .auto_widget_anon_in_a_bits_corrupt(lo_a_corrupt),
    .auto_widget_anon_in_d_ready(lo_d_ready),
    .auto_widget_anon_in_d_valid(wi_d_valid), .auto_widget_anon_in_d_bits_opcode(wi_d_opcode),
    .auto_widget_anon_in_d_bits_size(wi_d_size), .auto_widget_anon_in_d_bits_source(wi_d_source),
    .auto_widget_anon_in_d_bits_denied(wi_d_denied), .auto_widget_anon_in_d_bits_data(wi_d_data),
    .auto_widget_anon_in_d_bits_corrupt(wi_d_corrupt),
    .auto_axi4yank_out_aw_ready(x_awready), .auto_axi4yank_out_aw_valid(x_awvalid),
    .auto_axi4yank_out_aw_bits_id(m_awid), .auto_axi4yank_out_aw_bits_addr(x_awaddr),
    .auto_axi4yank_out_aw_bits_len(x_awlen), .auto_axi4yank_out_aw_bits_size(x_awsize),
    .auto_axi4yank_out_aw_bits_burst(x_awburst), .auto_axi4yank_out_aw_bits_lock(m_awlock),
    .auto_axi4yank_out_aw_bits_cache(m_awcache), .auto_axi4yank_out_aw_bits_prot(m_awprot),
    .auto_axi4yank_out_aw_bits_qos(m_awqos),
    .auto_axi4yank_out_w_ready(x_wready), .auto_axi4yank_out_w_valid(x_wvalid),
    .auto_axi4yank_out_w_bits_data(x_wdata), .auto_axi4yank_out_w_bits_strb(x_wstrb),
    .auto_axi4yank_out_w_bits_last(x_wlast),
    .auto_axi4yank_out_b_ready(x_bready), .auto_axi4yank_out_b_valid(x_bvalid),
    .auto_axi4yank_out_b_bits_id(m_bid), .auto_axi4yank_out_b_bits_resp(m_bresp),
    .auto_axi4yank_out_ar_ready(x_arready), .auto_axi4yank_out_ar_valid(x_arvalid),
    .auto_axi4yank_out_ar_bits_id(m_arid), .auto_axi4yank_out_ar_bits_addr(x_araddr),
    .auto_axi4yank_out_ar_bits_len(x_arlen), .auto_axi4yank_out_ar_bits_size(x_arsize),
    .auto_axi4yank_out_ar_bits_burst(x_arburst), .auto_axi4yank_out_ar_bits_lock(m_arlock),
    .auto_axi4yank_out_ar_bits_cache(m_arcache), .auto_axi4yank_out_ar_bits_prot(m_arprot),
    .auto_axi4yank_out_ar_bits_qos(m_arqos),
    .auto_axi4yank_out_r_ready(x_rready), .auto_axi4yank_out_r_valid(x_rvalid),
    .auto_axi4yank_out_r_bits_id(m_rid), .auto_axi4yank_out_r_bits_data(x_rdata),
    .auto_axi4yank_out_r_bits_resp(m_rresp), .auto_axi4yank_out_r_bits_last(x_rlast),
    .auto_tl_in_a_ready(a_ready), .auto_tl_in_a_valid(a_valid),
    .auto_tl_in_a_bits_opcode(a_opcode), .auto_tl_in_a_bits_param(3'd0),
    .auto_tl_in_a_bits_size(a_size), .auto_tl_in_a_bits_source(a_source),
    .auto_tl_in_a_bits_address(a_address), .auto_tl_in_a_bits_mask(a_mask),
    .auto_tl_in_a_bits_data(a_data), .auto_tl_in_a_bits_corrupt(1'b0),
    .auto_tl_in_d_ready(d_ready), .auto_tl_in_d_valid(d_valid),
    .auto_tl_in_d_bits_opcode(d_opcode), .auto_tl_in_d_bits_size(d_size),
    .auto_tl_in_d_bits_source(d_source), .auto_tl_in_d_bits_denied(d_denied),
    .auto_tl_in_d_bits_data(d_data), .auto_tl_in_d_bits_corrupt(),
    .auto_tl_out_a_ready(wi_a_ready), .auto_tl_out_a_valid(lo_a_valid),
    .auto_tl_out_a_bits_opcode(lo_a_opcode), .auto_tl_out_a_bits_param(lo_a_param),
    .auto_tl_out_a_bits_size(lo_a_size), .auto_tl_out_a_bits_source(lo_a_source),
    .auto_tl_out_a_bits_address(lo_a_address), .auto_tl_out_a_bits_mask(lo_a_mask),
    .auto_tl_out_a_bits_data(lo_a_data), .auto_tl_out_a_bits_corrupt(lo_a_corrupt),
    .auto_tl_out_d_ready(lo_d_ready), .auto_tl_out_d_valid(wi_d_valid),
    .auto_tl_out_d_bits_opcode(wi_d_opcode), .auto_tl_out_d_bits_size(wi_d_size),
    .auto_tl_out_d_bits_source(wi_d_source), .auto_tl_out_d_bits_denied(wi_d_denied),
    .auto_tl_out_d_bits_data(wi_d_data), .auto_tl_out_d_bits_corrupt(wi_d_corrupt)
  );
  assign x_awid = m_awid;
  assign x_arid = m_arid;

  wire [31:0] h_awaddr_raw, h_araddr_raw;
  wire [1:0]  h_awburst, h_arburst, h_awlock, h_arlock;
  wire [3:0]  h_awcache, h_arcache, h_awqos, h_arqos;
  wire [2:0]  h_awprot, h_arprot;
  // the address fold, as pynqz2_rocket_top.v: Rocket's 0x8000_0000 is PS DDR 0x1000_0000
  assign h_awaddr = {4'd1, h_awaddr_raw[27:0]};
  assign h_araddr = {4'd1, h_araddr_raw[27:0]};

  // As src/pynqz2_rocket_top.v's u_bridge (clock and reset are fclk_mem/mem_resetn there).
  axi4_to_axi3 #(.ADDR_W(32), .DATA_W(64), .ID_W(6)) u_bridge (
    .clk(clock), .rstn(~reset),
    .s_awid({2'b00, m_awid}), .s_awaddr(x_awaddr), .s_awlen(x_awlen),
    .s_awsize(x_awsize), .s_awburst(x_awburst), .s_awlock(m_awlock),
    .s_awcache(m_awcache), .s_awprot(m_awprot), .s_awqos(m_awqos),
    .s_awvalid(x_awvalid), .s_awready(x_awready),
    .s_wdata(x_wdata), .s_wstrb(x_wstrb), .s_wlast(x_wlast),
    .s_wvalid(x_wvalid), .s_wready(x_wready),
    .s_bid(), .s_bresp(m_bresp), .s_bvalid(x_bvalid), .s_bready(x_bready),
    .s_arid({2'b00, m_arid}), .s_araddr(x_araddr), .s_arlen(x_arlen),
    .s_arsize(x_arsize), .s_arburst(x_arburst), .s_arlock(m_arlock),
    .s_arcache(m_arcache), .s_arprot(m_arprot), .s_arqos(m_arqos),
    .s_arvalid(x_arvalid), .s_arready(x_arready),
    .s_rdata(x_rdata), .s_rresp(m_rresp), .s_rlast(x_rlast),
    .s_rvalid(x_rvalid), .s_rready(x_rready),
    .m_awid(h_awid), .m_awaddr(h_awaddr_raw), .m_awlen(h_awlen), .m_awsize(h_awsize),
    .m_awburst(h_awburst), .m_awlock(h_awlock), .m_awcache(h_awcache),
    .m_awprot(h_awprot), .m_awqos(h_awqos),
    .m_awvalid(h_awvalid), .m_awready(h_awready),
    .m_wid(h_wid), .m_wdata(h_wdata), .m_wstrb(h_wstrb), .m_wlast(h_wlast),
    .m_wvalid(h_wvalid), .m_wready(h_wready),
    .m_bid(h_bid), .m_bresp(h_bresp), .m_bvalid(h_bvalid), .m_bready(h_bready),
    .m_arid(h_arid), .m_araddr(h_araddr_raw), .m_arlen(h_arlen), .m_arsize(h_arsize),
    .m_arburst(h_arburst), .m_arlock(h_arlock), .m_arcache(h_arcache),
    .m_arprot(h_arprot), .m_arqos(h_arqos),
    .m_arvalid(h_arvalid), .m_arready(h_arready),
    .m_rdata(h_rdata), .m_rresp(h_rresp), .m_rlast(h_rlast),
    .m_rvalid(h_rvalid), .m_rready(h_rready),
    .err_burst_too_long(err_burst_too_long)
  );
  // IDs back to ChipTop, as pynqz2_rocket_top.v (the shim widened them with 2'b00)
  assign m_bid = h_bid[3:0];
  assign m_rid = h_rid[3:0];
endmodule
