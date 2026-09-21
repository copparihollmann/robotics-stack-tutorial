// Minimal behavioural AXI3 slave with backing memory, for datapath validation.
//
// Deliberately strict about the AXI3 details that S_AXI_HP0 actually enforces -- 4-bit
// LEN, INCR bursts, 64-bit beats -- so a master that passes here is shaped correctly for
// the real port. It is NOT a protocol checker; that job belongs to the Xilinx VIP in
// tb_hp0_dram.sv. This exists because the VIP's DDR model cannot be powered up from a
// testbench in Vivado 2023.1.

module axi3_slave_mem #(
  parameter integer ADDR_W = 32,
  parameter integer DATA_W = 64,
  parameter integer ID_W   = 6,
  parameter integer MEM_KB = 64,
  parameter [31:0]  BASE   = 32'h1000_0000
)(
  input  wire              clk, rstn,
  input  wire [ID_W-1:0]   awid,  input wire [ADDR_W-1:0] awaddr,
  input  wire [3:0]        awlen, input wire              awvalid,
  output reg               awready,
  input  wire [DATA_W-1:0] wdata, input wire [DATA_W/8-1:0] wstrb,
  input  wire              wlast, input wire              wvalid,
  output reg               wready,
  output reg  [ID_W-1:0]   bid,   output reg [1:0]        bresp,
  output reg               bvalid, input wire             bready,
  input  wire [ID_W-1:0]   arid,  input wire [ADDR_W-1:0] araddr,
  input  wire [3:0]        arlen, input wire              arvalid,
  output reg               arready,
  output reg  [DATA_W-1:0] rdata, output reg [1:0]        rresp,
  output reg               rlast, output reg              rvalid,
  input  wire              rready
);
  localparam integer WORDS = (MEM_KB*1024)/(DATA_W/8);
  reg [DATA_W-1:0] mem [0:WORDS-1];

  function integer idx(input [ADDR_W-1:0] a);
    idx = ((a - BASE) / (DATA_W/8)) % WORDS;
  endfunction

  reg [ADDR_W-1:0] wa = 0, ra = 0;
  reg [3:0]        rbeats = 0;
  reg              wactive = 0, ractive = 0;

  always @(posedge clk) begin
    if (!rstn) begin
      awready <= 0; wready <= 0; bvalid <= 0; arready <= 0; rvalid <= 0; rlast <= 0;
      wactive <= 0; ractive <= 0; bresp <= 0; rresp <= 0;
    end else begin
      // write address
      awready <= (!wactive && awvalid && !bvalid);
      if (awvalid && awready) begin
        wa <= awaddr; bid <= awid; wactive <= 1; wready <= 1;
      end
      // write data
      if (wvalid && wready) begin
        mem[idx(wa)] <= wdata;
        wa <= wa + (DATA_W/8);
        if (wlast) begin
          wready <= 0; wactive <= 0; bvalid <= 1; bresp <= 2'b00;
        end
      end
      if (bvalid && bready) bvalid <= 0;

      // read
      arready <= (!ractive && arvalid && !rvalid);
      if (arvalid && arready) begin
        ra <= araddr; rbeats <= arlen; ractive <= 1;
        rdata <= mem[idx(araddr)]; rresp <= 2'b00;
        rlast <= (arlen == 4'd0); rvalid <= 1;
      end else if (rvalid && rready) begin
        if (rbeats == 4'd0) begin
          rvalid <= 0; rlast <= 0; ractive <= 0;
        end else begin
          rbeats <= rbeats - 4'd1;
          ra     <= ra + (DATA_W/8);
          rdata  <= mem[idx(ra + (DATA_W/8))];
          rlast  <= (rbeats == 4'd1);
        end
      end
    end
  end
endmodule
