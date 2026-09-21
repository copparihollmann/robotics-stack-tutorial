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
//   * READ ENABLE PER BANK, AND ONLY IN A CYCLE THE ARRAY IS ACTUALLY READING (rd_en).  A bank
//     reads only when its read port selects it AND the sequencer is stepping.  The outputs are
//     unchanged -- the group mux already took only the selected bank, one cycle later.
//
//     rd_en IS NOT COSMETIC (added 2026-09-17).  Without it `re = (sel == g)` is a comparison
//     against an address bus that the engine drives from HELD registers -- rd_addr for every
//     weight port is {t_wbuf, w_addr}, and neither stops changing when no tile runs -- so one bank
//     per port was read-enabled on EVERY cycle of the engine's life, idle included.  Across two
//     clocks that is a read/write collision on a true dual-port BRAM whenever the lane is filling
//     the buffer the held address still names, and the fill protocol does not exclude it: the
//     engine's `ld_buf_bad` refuses a load into the tile's buffer only while a tile is RUNNING
//     (`t_busy`), and between tiles nothing stops one.  A single-clock bench cannot show it -- with
//     one clock the primitive's write mode defines the result and the data is discarded anyway --
//     which is why it survived every gate this engine has.  With rd_en the banks are enabled only
//     in the cycles the array consumes, and no idle cycle can collide with a fill.
//
// Same flat word address as mbxd_spad: bank = wr_word[AW +: BW] = {port, buffer, top word bit}.

module mbxd_spad2 #(
  parameter NRD   = 5,
  parameter GRP   = 4,
  parameter DEPTH = 512
) (
  input  wire                     clk,          // read side
  input  wire                     rd_en,        // the sequencer is stepping this cycle
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
        wire       re = rd_en && (sel == g);
        if (p == 0) begin : wa
          wire we = wa_en && (abank == (p*GRP + g));
          always @(posedge wa_clk) begin
            if (we) mem[aword] <= wa_data;
          end
        end else begin : ww
`ifdef MBXR_TB_WSKEW
          // SIMULATION ONLY, and it is a MODEL OF THE BOARD'S PHYSICS, not part of the design.
          // One write port fans out to twenty banks; on the routed 2b design those paths are not
          // the same length, and the two boards' identity runs show an error rate that rises
          // monotonically with the read-port index (plane 3 at 96-100 %, plane 0 at 43-58 %).  A
          // zero-delay bench cannot express that: here every bank sees the write on the same edge.
          // MBXR_TB_WSKEW=<n> delays the write into read port p by p*n wclk cycles, so the bench
          // can ask whether a per-port skew reproduces the four-part signature (ROCC_DECOUPLED.md
          // 8.15.9).  The VERDICT still comes from kernel_linear_s8, never from the engine.
          localparam integer SKEW = (p - 1) * `MBXR_TB_WSKEW;
          reg [SKEW:0]    we_d;      // [0] is this cycle
          reg [15:0]      wd_word [0:SKEW];
          reg [63:0]      wd_data [0:SKEW];
          integer si;
          wire we_now = ww_en && (wbank == (p*GRP + g));
          always @(posedge ww_clk) begin
            we_d[0] <= we_now; wd_word[0] <= wword; wd_data[0] <= ww_data;
            for (si = 1; si <= SKEW; si = si + 1) begin
              we_d[si] <= we_d[si-1]; wd_word[si] <= wd_word[si-1]; wd_data[si] <= wd_data[si-1];
            end
            if (SKEW == 0) begin if (we_now) mem[wword] <= ww_data; end
            else if (we_d[SKEW]) mem[wd_word[SKEW]] <= wd_data[SKEW];
          end
`else
          wire we = ww_en && (wbank == (p*GRP + g));
          always @(posedge ww_clk) begin
            if (we) mem[wword] <= ww_data;
          end
`endif
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
