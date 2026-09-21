// -----------------------------------------------------------------------------
// Rocket's integer register file, transcribed from
//   rocket-chip/src/main/scala/rocket/RocketCore.scala:1386-1405
//
//   val rf = Mem(n, UInt(w.W))                     <- combinational-read Mem
//   def read(addr)  = Mux(zero && addr===0, 0, rf(~addr))
//   def write(addr, data) = when (addr =/= 0) { rf(~addr) := data
//                             for ((raddr,rdata) <- reads)
//                               when (addr === raddr) { rdata := data } }
//
// i.e. 31 x 64, asynchronous read, synchronous write, with explicit same-cycle
// write-to-read forwarding on every read port.  READS is the number of read
// ports; the whole point of this module is to price READS=3 against READS=2.
// -----------------------------------------------------------------------------
module pext_regfile #(
  parameter READS = 2
) (
  input  wire        clk,
  input  wire [4:0]  ra0,
  input  wire [4:0]  ra1,
  input  wire [4:0]  ra2,
  input  wire [4:0]  wa,
  input  wire        wen,
  input  wire [63:0] wd,
  output wire [63:0] rd0,
  output wire [63:0] rd1,
  output wire [63:0] rd2
);
  reg [63:0] mem [0:31];

  always @(posedge clk)
    if (wen && (wa != 5'd0)) mem[~wa] <= wd;

  wire [63:0] raw0 = (ra0 == 5'd0) ? 64'd0 : mem[~ra0];
  wire [63:0] raw1 = (ra1 == 5'd0) ? 64'd0 : mem[~ra1];
  wire [63:0] raw2 = (ra2 == 5'd0) ? 64'd0 : mem[~ra2];

  // same-cycle write forwarding, exactly as the Chisel does
  wire fw0 = wen && (wa != 5'd0) && (wa == ra0);
  wire fw1 = wen && (wa != 5'd0) && (wa == ra1);
  wire fw2 = wen && (wa != 5'd0) && (wa == ra2);

  assign rd0 = fw0 ? wd : raw0;
  assign rd1 = fw1 ? wd : raw1;
  assign rd2 = (READS >= 3) ? (fw2 ? wd : raw2) : 64'd0;
endmodule

// Harness: registered address/data in, registered read data out, so the routed
// design has a real reg->RF->reg path to time.
module pext_regfile_harness #(
  parameter READS = 2
) (
  input  wire        clk,
  input  wire [4:0]  ra0_i, ra1_i, ra2_i, wa_i,
  input  wire        wen_i,
  input  wire [63:0] wd_i,
  output reg  [63:0] q
);
  reg [4:0]  ra0, ra1, ra2, wa;
  reg        wen;
  reg [63:0] wd;
  wire [63:0] rd0, rd1, rd2;
  always @(posedge clk) begin
    ra0 <= ra0_i; ra1 <= ra1_i; ra2 <= ra2_i; wa <= wa_i;
    wen <= wen_i; wd <= wd_i;
    q   <= rd0 ^ rd1 ^ rd2;
  end
  pext_regfile #(.READS(READS)) rf (
    .clk(clk), .ra0(ra0), .ra1(ra1), .ra2(ra2),
    .wa(wa), .wen(wen), .wd(wd), .rd0(rd0), .rd1(rd1), .rd2(rd2));
endmodule

module pext_regfile_2r1w (input wire clk, input wire [4:0] ra0_i, ra1_i, ra2_i, wa_i,
  input wire wen_i, input wire [63:0] wd_i, output wire [63:0] q);
  pext_regfile_harness #(.READS(2)) h (.clk(clk), .ra0_i(ra0_i), .ra1_i(ra1_i),
    .ra2_i(ra2_i), .wa_i(wa_i), .wen_i(wen_i), .wd_i(wd_i), .q(q));
endmodule

module pext_regfile_3r1w (input wire clk, input wire [4:0] ra0_i, ra1_i, ra2_i, wa_i,
  input wire wen_i, input wire [63:0] wd_i, output wire [63:0] q);
  pext_regfile_harness #(.READS(3)) h (.clk(clk), .ra0_i(ra0_i), .ra1_i(ra1_i),
    .ra2_i(ra2_i), .wa_i(wa_i), .wen_i(wen_i), .wd_i(wd_i), .q(q));
endmodule
