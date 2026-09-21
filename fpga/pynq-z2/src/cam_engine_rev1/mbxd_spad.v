// SPDX-License-Identifier: Apache-2.0
//
// mbxd_spad -- the banked BRAM scratchpad, addressed flat, and double buffered.
//
// SAME PARTITION AS mbx_spad, TWO CHANGES.
//
//   * The fill port takes a FLAT word address and derives the bank from its high bits,
//     because mbxd_dma's destination is a running word counter across a whole tile and
//     splitting it inside the engine would put an adder and a comparator in the fill
//     path for nothing.  mbx_spad wanted (bank, addr) because its DMA retired in order
//     and knew which row it was on.
//
//   * GRP is 4 rather than 3, so each read port's group splits cleanly in half and the
//     high address bit IS the buffer select.  THAT IS THE ENTIRE COST OF DOUBLE
//     BUFFERING: the fill port can already write any bank while the read ports read any
//     other, so "compute from one buffer while the engine streams into the other" is one
//     bit of the tile descriptor and no hardware.  The bit is registered in the engine
//     so the flip is one instruction, not a recomputed base address.
//
// WHY BANKS AND NOT A WIDER MEMORY.  A RAMB36E1 in SDP x72 mode delivers 9 bytes per
// cycle.  The port this unit exists to escape delivers, measured, 1.34.  Five read ports
// of 8 bytes is 40 B/cycle into the array against the L2's measured 2.82 and the
// register file's 16 -- and ROCC_STUDY.md 7.2 measured that read ports are nearly free
// when each owns its banks: spad_9x2 has 9 ports and 72 B/cycle for 434 LUT, within two
// LUT of spad_5x3's 5 ports and 40 B/cycle.  The cost of capacity is the per-port bank
// mux at 19.5 LUT per BRAM36, and the storage itself is free.
//
// The read path is a GRP:1 mux downstream of the BRAM output register, never an
// (NRD*GRP):1 one, so widening the array costs banks and not crossbar.

module mbxd_spad #(
  parameter NRD   = 5,      // read ports: 1 activation + NCH weight words
  parameter GRP   = 4,      // banks per read port; even, so the top bit is the buffer
  parameter DEPTH = 512     // words per bank (512 x 64b = one RAMB36E1)
) (
  input  wire                     clk,
  // NRD read ports.  Address is {bank_within_group, word}, flattened.
  input  wire [NRD*16-1:0]        rd_addr,
  output wire [NRD*64-1:0]        rd_data,
  // one fill port, flat word address over the whole scratchpad, any bank
  input  wire                     wr_en,
  input  wire [15:0]              wr_word,
  input  wire [63:0]              wr_data
);
  localparam BANKS = NRD * GRP;
  localparam AW    = $clog2(DEPTH);
  localparam SW    = (GRP > 1) ? $clog2(GRP) : 1;
  localparam BW    = $clog2(BANKS);

  wire [BW-1:0] wbank = wr_word[AW +: BW];
  wire [AW-1:0] wword = wr_word[AW-1:0];

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
        wire       we = wr_en && (wbank == (p*GRP + g));

        always @(posedge clk) begin
          if (we) begin
            mem[wword] <= wr_data;
          end
          dout <= mem[ra];
        end
        assign bo[g*64 +: 64] = dout;
      end

      assign rd_data[p*64 +: 64] = bo[sel_q*64 +: 64];
    end
  endgenerate
endmodule
