// -----------------------------------------------------------------------------
// MBX accumulator file.  NACC 64-bit accumulators, written NCH at a time.
//
// "An internal accumulator file with no register pressure" is one of the four
// things PEXT_FEASIBILITY.md section 3(c) lists in RoCC's favour.  This is what
// it costs.  The comparison point is section 3(b): a THIRD read port on Rocket's
// own 31x64 register file is +113 LUT and +0.168 ns, because Xilinx distributed
// RAM gives one read port per replica at 44 LUTs per replica.
// -----------------------------------------------------------------------------
module mbx_accbank #(
  parameter NACC = 16,
  parameter NCH  = 4
) (
  input  wire                clk,
  input  wire                we,
  input  wire [3:0]          wa,      // block index; writes NCH consecutive
  input  wire [64*NCH-1:0]   wd,
  input  wire [3:0]          ra,
  output wire [64*NCH-1:0]   rd
);
  reg [63:0] mem [0:NACC-1];
  integer i;
  always @(posedge clk)
    if (we)
      for (i = 0; i < NCH; i = i + 1)
        mem[(wa * NCH + i) % NACC] <= wd[i*64 +: 64];

  genvar c;
  generate
    for (c = 0; c < NCH; c = c + 1) begin : g_rd
      assign rd[c*64 +: 64] = mem[(ra * NCH + c) % NACC];
    end
  endgenerate
endmodule
