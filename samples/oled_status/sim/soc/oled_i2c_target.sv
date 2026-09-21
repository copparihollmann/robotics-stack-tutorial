// SPDX-License-Identifier: Apache-2.0
//
// The SSD1306 target for the SoC TestHarness: a thin Verilog shell over the same
// sim/i2c_target.c and model/ssd1306_model.c the standalone TLI2C test and the host test use,
// through DPI. Clocked on the SoC clock (ChipTop's clock_uncore in the harness), so every
// cycle count it reports is in SoC cycles and comparable with scripts/55 --tli2c.
//
// It only ever pulls lines LOW (open-drain); the harness ANDs scl_low/sda_low into the lines
// ChipTop sees, beside the camera model's drives.
module oled_i2c_target #(
  parameter integer ADDR7 = 60   // 0x3c
) (
  input  wire clock,
  input  wire reset,
  input  wire scl,
  input  wire sda,
  output wire scl_low,
  output wire sda_low
);
  import "DPI-C" function void oled_tgt_init(input int addr);
  import "DPI-C" function int oled_tgt_eval(input int scl_in, input int sda_in);

  reg init_done = 1'b0;
  reg r_scl_low = 1'b0;
  reg r_sda_low = 1'b0;
  integer rv;

  always @(posedge clock) begin
    if (!init_done) begin
      oled_tgt_init(ADDR7);
      init_done <= 1'b1;
    end
    if (reset) begin
      r_scl_low <= 1'b0;
      r_sda_low <= 1'b0;
    end else begin
      rv = oled_tgt_eval(scl ? 1 : 0, sda ? 1 : 0);
      r_scl_low <= rv[0];
      r_sda_low <= rv[1];
    end
  end

  assign scl_low = r_scl_low;
  assign sda_low = r_sda_low;
endmodule
