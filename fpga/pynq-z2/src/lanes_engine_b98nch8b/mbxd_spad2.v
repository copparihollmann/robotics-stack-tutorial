// SPDX-License-Identifier: Apache-2.0
//
// mbxd_spad2 -- rtl_study/rocc/mbxd_spad.v with its one fill port split in two, for engine
// revision 2 (ROCC_DECOUPLED.md 8.15.5; MEMORY_BANDWIDTH.md 9.9 P1/P2).  A proposal copy:
// the measured mbxd_spad.v is left as it was built.
//
//   * TWO WRITE PORTS ON DISJOINT BANKS.  Port A writes only the activation group (read port
//     0); port W writes only the weight groups (read ports 1..NRD-1).  Each has its own clock
//     input.  Revision 2a ties both to the engine clock; 2b gives W the memory-bus clock, and
//     every weight bank is then a simple dual-port BRAM with independent write and read clocks.
//   * READ ENABLE PER BANK.  A bank reads only in a cycle where its read port selects it.  The
//     outputs are unchanged -- the group mux already took only the selected bank, one cycle
//     later -- but a bank that is being filled is never read, so across two clocks there is no
//     read/write collision whatever the BRAM's write mode.  That rests on the fill protocol
//     (the fill writes the buffer the running tile does NOT read), which the engine enforces
//     with a sticky error.
//
// Same flat word address as mbxd_spad: bank = wr_word[AW +: BW] = {port, buffer, top word bit}.

module mbxd_spad2 #(
  parameter NRD   = 5,
  parameter GRP   = 4,
  parameter DEPTH = 512
) (
  input  wire                     clk,          // read side
  input  wire [NRD*16-1:0]        rd_addr,
  output wire [NRD*64-1:0]        rd_data,
  input  wire                     wa_clk,       // activation fill
  input  wire                     wa_en,
  input  wire [15:0]              wa_word,
  input  wire [63:0]              wa_data,
  input  wire                     ww_clk,       // weight fill
  input  wire                     ww_en,
  input  wire [15:0]              ww_word,
  input  wire [63:0]              ww_data
);
  localparam BANKS = NRD * GRP;
  localparam AW    = $clog2(DEPTH);
  localparam SW    = (GRP > 1) ? $clog2(GRP) : 1;
  localparam BW    = $clog2(BANKS);

  wire [BW-1:0] abank = wa_word[AW +: BW];
  wire [AW-1:0] aword = wa_word[AW-1:0];
  wire [BW-1:0] wbank = ww_word[AW +: BW];
  wire [AW-1:0] wword = ww_word[AW-1:0];

  genvar p, g;
  generate
    for (p = 0; p < NRD; p = p + 1) begin : port
      wire [AW-1:0] ra  = rd_addr[p*16 +: AW];
      wire [SW-1:0] sel = (GRP > 1) ? rd_addr[p*16 + AW +: SW] : {SW{1'b0}};
      reg  [SW-1:0] sel_q;
      wire [GRP*64-1:0] bo;

      always @(posedge clk) begin
        sel_q <= sel;
      end

      for (g = 0; g < GRP; g = g + 1) begin : bank
        (* ram_style = "block" *) reg [63:0] mem [0:DEPTH-1];
        reg [63:0] dout;
        wire       re = (sel == g);
        if (p == 0) begin : wa
          wire we = wa_en && (abank == (p*GRP + g));
          always @(posedge wa_clk) begin
            if (we) mem[aword] <= wa_data;
          end
        end else begin : ww
          wire we = ww_en && (wbank == (p*GRP + g));
          always @(posedge ww_clk) begin
            if (we) mem[wword] <= ww_data;
          end
        end
        always @(posedge clk) begin
          if (re) dout <= mem[ra];
        end
        assign bo[g*64 +: 64] = dout;
      end

      assign rd_data[p*64 +: 64] = bo[sel_q*64 +: 64];
    end
  endgenerate
endmodule
