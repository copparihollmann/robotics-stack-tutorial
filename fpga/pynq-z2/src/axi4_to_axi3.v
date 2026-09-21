// AXI4 (Chipyard mem_axi4) -> AXI3 (Zynq S_AXI_HP0) bridge.
//
// S_AXI_HP0 is AXI3, and differs from AXI4 in exactly three ways that matter here:
//
//   1. AWLEN/ARLEN are 4 bits, so a burst is at most 16 beats (AXI4 allows 256).
//   2. The write-data channel carries WID, which must match the AWID of the burst it
//      belongs to. AXI4 deleted WID entirely.
//   3. AWLOCK/ARLOCK are 2 bits rather than 1.
//
// On burst length this bridge PASSES THROUGH and CHECKS rather than fragmenting. Rocket's
// memory port moves one cache line per burst -- 64 B as 8 beats of 64 bits -- which is
// comfortably inside AXI3's limit, so a fragmenter would be dead logic carrying live bug
// risk. Instead, any burst longer than 16 beats sets a sticky error bit that software can
// read, and it is asserted in simulation. If a future config ever does emit longer bursts,
// this reports it loudly instead of silently truncating the length field and corrupting
// memory.
//
// WID is reconstructed with a small FIFO. AXI4 forbids write-data interleaving, so write
// bursts complete in the order their AW beats were accepted: push AWID on the AW handshake,
// use the head as WID, pop on WLAST.

module axi4_to_axi3 #(
  parameter integer ADDR_W  = 32,
  parameter integer DATA_W  = 64,
  parameter integer ID_W    = 6,
  parameter integer FIFO_LG = 3      // 2^3 = 8 outstanding write bursts
)(
  input  wire                 clk,
  input  wire                 rstn,

  // ---- AXI4 slave side (from Chipyard mem_axi4) ----
  input  wire [ID_W-1:0]      s_awid,
  input  wire [ADDR_W-1:0]    s_awaddr,
  input  wire [7:0]           s_awlen,
  input  wire [2:0]           s_awsize,
  input  wire [1:0]           s_awburst,
  input  wire                 s_awlock,
  input  wire [3:0]           s_awcache,
  input  wire [2:0]           s_awprot,
  input  wire [3:0]           s_awqos,
  input  wire                 s_awvalid,
  output wire                 s_awready,
  input  wire [DATA_W-1:0]    s_wdata,
  input  wire [DATA_W/8-1:0]  s_wstrb,
  input  wire                 s_wlast,
  input  wire                 s_wvalid,
  output wire                 s_wready,
  output wire [ID_W-1:0]      s_bid,
  output wire [1:0]           s_bresp,
  output wire                 s_bvalid,
  input  wire                 s_bready,
  input  wire [ID_W-1:0]      s_arid,
  input  wire [ADDR_W-1:0]    s_araddr,
  input  wire [7:0]           s_arlen,
  input  wire [2:0]           s_arsize,
  input  wire [1:0]           s_arburst,
  input  wire                 s_arlock,
  input  wire [3:0]           s_arcache,
  input  wire [2:0]           s_arprot,
  input  wire [3:0]           s_arqos,
  input  wire                 s_arvalid,
  output wire                 s_arready,
  output wire [DATA_W-1:0]    s_rdata,
  output wire [1:0]           s_rresp,
  output wire                 s_rlast,
  output wire                 s_rvalid,
  input  wire                 s_rready,

  // ---- AXI3 master side (to S_AXI_HP0) ----
  output wire [ID_W-1:0]      m_awid,
  output wire [ADDR_W-1:0]    m_awaddr,
  output wire [3:0]           m_awlen,
  output wire [2:0]           m_awsize,
  output wire [1:0]           m_awburst,
  output wire [1:0]           m_awlock,
  output wire [3:0]           m_awcache,
  output wire [2:0]           m_awprot,
  output wire [3:0]           m_awqos,
  output wire                 m_awvalid,
  input  wire                 m_awready,
  output wire [ID_W-1:0]      m_wid,
  output wire [DATA_W-1:0]    m_wdata,
  output wire [DATA_W/8-1:0]  m_wstrb,
  output wire                 m_wlast,
  output wire                 m_wvalid,
  input  wire                 m_wready,
  input  wire [ID_W-1:0]      m_bid,
  input  wire [1:0]           m_bresp,
  input  wire                 m_bvalid,
  output wire                 m_bready,
  output wire [ID_W-1:0]      m_arid,
  output wire [ADDR_W-1:0]    m_araddr,
  output wire [3:0]           m_arlen,
  output wire [2:0]           m_arsize,
  output wire [1:0]           m_arburst,
  output wire [1:0]           m_arlock,
  output wire [3:0]           m_arcache,
  output wire [2:0]           m_arprot,
  output wire [3:0]           m_arqos,
  output wire                 m_arvalid,
  input  wire                 m_arready,
  input  wire [DATA_W-1:0]    m_rdata,
  input  wire [1:0]           m_rresp,
  input  wire                 m_rlast,
  input  wire                 m_rvalid,
  output wire                 m_rready,

  // sticky: a burst arrived that AXI3 cannot encode
  output reg                  err_burst_too_long
);

  // ---- address channels: straight through, LEN narrowed ----
  assign m_awid    = s_awid;
  assign m_awaddr  = s_awaddr;
  assign m_awlen   = s_awlen[3:0];
  assign m_awsize  = s_awsize;
  assign m_awburst = s_awburst;
  assign m_awlock  = {1'b0, s_awlock};
  assign m_awcache = s_awcache;
  assign m_awprot  = s_awprot;
  assign m_awqos   = s_awqos;
  assign m_awvalid = s_awvalid;
  assign s_awready = m_awready;

  assign m_arid    = s_arid;
  assign m_araddr  = s_araddr;
  assign m_arlen   = s_arlen[3:0];
  assign m_arsize  = s_arsize;
  assign m_arburst = s_arburst;
  assign m_arlock  = {1'b0, s_arlock};
  assign m_arcache = s_arcache;
  assign m_arprot  = s_arprot;
  assign m_arqos   = s_arqos;
  assign m_arvalid = s_arvalid;
  assign s_arready = m_arready;

  // ---- write data: pass through, WID from the AWID order FIFO ----
  localparam integer DEPTH = (1 << FIFO_LG);
  reg [ID_W-1:0] idq [0:DEPTH-1];
  reg [FIFO_LG:0] wr_ptr = 0, rd_ptr = 0;
  wire fifo_empty = (wr_ptr == rd_ptr);

  always @(posedge clk) begin
    if (!rstn) begin
      wr_ptr <= 0; rd_ptr <= 0; err_burst_too_long <= 1'b0;
    end else begin
      if (s_awvalid && s_awready) begin
        idq[wr_ptr[FIFO_LG-1:0]] <= s_awid;
        wr_ptr <= wr_ptr + 1'b1;
      end
      if (s_wvalid && s_wready && s_wlast && !fifo_empty)
        rd_ptr <= rd_ptr + 1'b1;

      // Sticky, and deliberately not cleared by anything but reset: a truncated length
      // means memory was already corrupted, so the flag should survive to be read.
      if ((s_awvalid && s_awready && s_awlen > 8'd15) ||
          (s_arvalid && s_arready && s_arlen > 8'd15))
        err_burst_too_long <= 1'b1;
    end
  end

  assign m_wid   = fifo_empty ? s_awid : idq[rd_ptr[FIFO_LG-1:0]];
  assign m_wdata = s_wdata;
  assign m_wstrb = s_wstrb;
  assign m_wlast = s_wlast;
  assign m_wvalid = s_wvalid;
  assign s_wready = m_wready;

  // ---- responses: straight through ----
  assign s_bid    = m_bid;
  assign s_bresp  = m_bresp;
  assign s_bvalid = m_bvalid;
  assign m_bready = s_bready;

  assign s_rdata  = m_rdata;
  assign s_rresp  = m_rresp;
  assign s_rlast  = m_rlast;
  assign s_rvalid = m_rvalid;
  assign m_rready = s_rready;

`ifdef FORMAL_OR_SIM
  always @(posedge clk) if (rstn) begin
    if (s_awvalid && s_awready && s_awlen > 8'd15)
      $error("axi4_to_axi3: AWLEN=%0d exceeds the AXI3 16-beat limit", s_awlen);
    if (s_arvalid && s_arready && s_arlen > 8'd15)
      $error("axi4_to_axi3: ARLEN=%0d exceeds the AXI3 16-beat limit", s_arlen);
  end
`endif
endmodule
