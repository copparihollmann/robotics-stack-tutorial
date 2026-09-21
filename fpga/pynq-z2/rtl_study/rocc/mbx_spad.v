// -----------------------------------------------------------------------------
// MBX scratchpad -- the thing the first revision of this study failed to cost.
//
// ROCC_STUDY.md r1 section 2.6 argued that 8 int8 MACs/cycle needs 16 B/cycle, that the
// register file is the only port on this SoC that supplies it, and that every memory
// port measures 7.03 / 2.82 / 1.34 B/cycle.  All of that is true and none of it is the
// device's limit: the shipped bitstream uses 64 of 140 BRAM36 and a 7-series BRAM36 in
// SDP mode reads 72 bits per cycle, so the 76 free ones are ~684 B/cycle of aggregate
// read bandwidth.  The wall was a property of the paths costed, not of the part.
//
// Organisation.  NRD independent read ports, each owning GRP banks of 512 x 64 bits
// (one RAMB36E1 each, 4 KB).  A STATIC partition, not a crossbar: read port p can only
// reach banks [p*GRP, p*GRP+GRP), so the read path is a GRP:1 mux and not an
// (NRD*GRP):1 one.  That is how a real design splits an activation scratchpad from a
// weight scratchpad, and it is what keeps the LUT cost of a big scratchpad bounded --
// the interesting measurement here is that the cost of scratchpad CAPACITY is the port
// mux, not the BRAM.
//
// The fill port writes any bank, so a DMA can refill one region while the MAC array
// reads another: that is the double buffering the decoupling argument needs.
//
//   NRD = 5  : one activation word + four weight words per cycle = 40 B/cycle,
//              which feeds an 8-lane x 4-channel broadcast MAC at 32 MACs/cycle.
//   NRD = 9  : 72 B/cycle, for the 8-channel array.
// -----------------------------------------------------------------------------
module mbx_spad #(
  parameter NRD   = 5,      // read ports
  parameter GRP   = 3,      // banks per read port
  parameter DEPTH = 512     // words per bank (512 x 64b = one RAMB36E1)
) (
  input  wire                     clk,
  // NRD read ports.  Address is {bank_select, word}, flattened.
  input  wire [NRD*16-1:0]        rd_addr,
  output wire [NRD*64-1:0]        rd_data,
  // one fill write port, any bank
  input  wire                     wr_en,
  input  wire [15:0]              wr_bank,   // 0 .. NRD*GRP-1
  input  wire [15:0]              wr_addr,
  input  wire [63:0]              wr_data
);
  localparam BANKS = NRD * GRP;
  localparam AW    = $clog2(DEPTH);
  localparam SW    = (GRP > 1) ? $clog2(GRP) : 1;

  genvar p, g;
  generate
    for (p = 0; p < NRD; p = p + 1) begin : g_port
      wire [15:0] a   = rd_addr[p*16 +: 16];
      wire [AW-1:0] wrd = a[AW-1:0];
      wire [SW-1:0] sel = (GRP > 1) ? a[AW +: SW] : {SW{1'b0}};
      reg  [SW-1:0] sel_q;
      always @(posedge clk) sel_q <= sel;

      wire [64*GRP-1:0] bo;
      for (g = 0; g < GRP; g = g + 1) begin : g_bank
        (* ram_style = "block" *) reg [63:0] mem [0:DEPTH-1];
        reg [63:0] dout;
        wire bank_we = wr_en && (wr_bank == (p*GRP + g));
        always @(posedge clk) begin
          if (bank_we) mem[wr_addr[AW-1:0]] <= wr_data;
          dout <= mem[wrd];
        end
        assign bo[g*64 +: 64] = dout;
      end
      // GRP:1 after the BRAM output register -- the whole LUT cost of the port
      assign rd_data[p*64 +: 64] = bo[sel_q*64 +: 64];
    end
  endgenerate
endmodule
