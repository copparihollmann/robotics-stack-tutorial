# SPDX-License-Identifier: Apache-2.0
#
# Identify the bitstream a lab actually loaded, by CONTENT and not by MAGIC.
#
# WHY THIS EXISTS.  SOC_MAGIC identifies the CONFIGURATION, not the build:
# fpga/pynq-z2/tcl/build_rocket.tcl sets 0x5A5A0005 for the mic + P-ext variant, and it
# stays 0x5A5A0005 however the RTL inside that variant changes.  So a `grep -q 'MAGIC =
# 0x5A5A0005'` proves the board is running THAT CONFIG and says nothing about which build
# of it.
#
# That is not hypothetical.  pynqz1_rocket_mic.bit was rebuilt in commit b81b5b3 to drop
# TACIT's branch predictor -- 40,561 -> 34,724 LUT, same config, same MAGIC, different
# silicon -- while fpga/pynq-z2/docs/SPEECH_ON_ROCKET.md section 7 attributed its numbers
# to the earlier md5 and claimed the MAGIC check would catch exactly this.  It would not
# have.  The document recorded a hash; the lab gated on a string; nothing connected them.
#
# So every speech lab now md5s the file it loads, prints it, records it in run.json beside
# the cycle counts, and refuses to run on a build nobody has validated.  The number and
# the silicon travel together.
#
#   bitstream_identify <path>     -> sets BIT_MD5, BIT_NOTE; prints both
#   bitstream_gate                -> dies unless BIT_MD5 is in BIT_ACCEPTED
#
# BIT_ACCEPTED is deliberately a LIST.  Two builds of this config are validated and the
# measurements agree on both (SPEECH_ON_ROCKET.md section 7); pinning one would make the
# labs fail on a perfectly good bitstream, and pinning none is what got us here.

# md5 -> what it is.  Add a line here only after re-running the labs against it.
bitstream_note () {
  case "$1" in
    7712bc03ff1d53bfdd4673cfd71b3296)
      echo "mic + P-ext, WITH the TACIT branch predictor (commit 1fc9927, 40,561 LUT)" ;;
    566bc5402d0cab22130942bf9904bfdb)
      echo "mic + P-ext, without the TACIT branch predictor (commit b81b5b3, 34,724 LUT)" ;;
    4c8f7bf79e2f2464908eca8656abd691)
      echo "FULL-FEATURE: mic + RGB GPIO + P-ext, no TACIT branch predictor (35,358 LUT)" ;;
    # Bandwidth-lab builds (scripts/43_rocket_bwlab.sh, MEMORY_BANDWIDTH.md).  NAMED here so
    # a run never calls them unknown; deliberately NOT in BIT_ACCEPTED below -- no speech lab
    # has been re-measured on them, and 43_rocket_bwlab.sh accepts them for itself.
    737d2f5707857105be90c24c7f6610a2)
      echo "0x5A5A0007 bandwidth lab, lever 1: full-feature + TileLink instrument (36,067 LUT) -- not validated for speech labs" ;;
    f507f18f8a42cd42993e9f35ab9a787f)
      echo "0x5A5A0008 bandwidth lab, lever 2: + memory bus on FCLK1 (36,455 LUT) -- not validated for speech labs" ;;
    62ea1a99280c6a6920557ea4c845291d)
      echo "0x5A5A0009 bandwidth lab, lever 3: + second memory channel into S_AXI_HP1 (36,378 LUT) -- not validated for speech labs" ;;
    e18c817d7600045c1f628ed4f4355f98)
      echo "0x5A5A000A bandwidth lab, lever 4: + 128-bit TileLink system bus (38,710 LUT) -- not validated for speech labs" ;;
    49d2a1f420e37f7659970942bd7be85a)
      echo "0x5A5A000E AS BUILT -- a MAGIC collision (bwlab/errata.csv): bandwidth lab, lever 4 at 256 bits, first build (46,782 LUT); the config is now 0x5A5A000F -- not validated for speech labs" ;;
    d3478730fcfcc5f7efc882fe420c26be)
      echo "0x5A5A000F bandwidth lab, lever 4 at 256 bits: + 256-bit TileLink system bus (46,782 LUT) -- not validated for speech labs" ;;
    0df4d1d1204f9c18faf047183ac8818b)
      echo "0x5A5A0014 bandwidth lab, bwbypassl2: lever 3 with channel 1 on S_AXI_HP2 (36,359 LUT) -- not validated for speech labs" ;;
    aee7e9879ab378381841984009101331)
      echo "0x5A5A0020 interface ceiling (MEMORY_BANDWIDTH.md s7): PS7 + four raw AXI3 masters on S_AXI_HP0..3, no SoC (11,426 LUT; in closure <= 125 MHz) -- not a speech-lab build" ;;
    c17d1a2b0f7ec45e1a62298cf625507c)
      echo "0x5A5A0015 bandwidth lab, bwbypass: L2-bypass instrument on MBUS, HP0+HP2, memory bus on FCLK1 (40,221 LUT) -- not validated for speech labs" ;;
    b13f237d3a99e102babe790ccfc5b69a)
      echo "0x5A5A0016 bandwidth lab, bwbypass01: L2-bypass instrument on MBUS, HP0+HP1, memory bus on FCLK1 (40,217 LUT) -- not validated for speech labs" ;;
    cab144c148fbe1f665483946d1c66e02)
      echo "0x5A5A000B bandwidth lab, L2 miss path: 12 L2 MSHRs (39,666 LUT) -- not validated for speech labs" ;;
    1188777ed23ae6ecc18865e37f1a2f14)
      echo "0x5A5A000C bandwidth lab, L2 miss path: 256 KB L2 (36,027 LUT, 113.5 BRAM36) -- not validated for speech labs" ;;
    0a49d75637908ce6b99afc206fe6194a)
      echo "0x5A5A000D bandwidth lab, L2 miss path: tiles on FCLK0, L2+uncore on FCLK1 built for 34.4828 MHz, patch 0090 (37,635 LUT) -- not validated for speech labs" ;;
    b03f2ab3a26e8842a3902da2678a33bd)
      echo "0x5A5A000D bandwidth lab, L2 miss path: tiles on FCLK0, L2+uncore on FCLK1 built for 40.0000 MHz, patch 0090 (37,716 LUT) -- not validated for speech labs" ;;
    7e2d9b3c6eaf8d6fefdc0f6b43cd0320)
      echo "0x5A5A000D at FCLK1 43.4783 MHz: FAILS TIMING (uncore WNS -0.271) -- a Fmax data point, NOT for measurement -- not validated for speech labs" ;;
    9f9dfd8f5e99890649cf4118404b66cb)
      echo "0x5A5A000D at FCLK1 45.4545 MHz, before patch 0090: FAILS TIMING (uncore WNS -1.722) -- NOT for measurement -- not validated for speech labs" ;;
    b710950bbef060fe3cc37b4a4ec7a9be)
      echo "0x5A5A000D at FCLK1 34.4828 MHz BEFORE patch 0090: unsynchronised TraceSinkDMA crossing -- NOT for measurement -- not validated for speech labs" ;;
    0981f7d29572010b1b3cd6e3bf32318b)
      echo "0x5A5A000D at FCLK1 40 MHz BEFORE patch 0090: unsynchronised TraceSinkDMA crossing -- NOT for measurement -- not validated for speech labs" ;;
    b69c1f52a571e1f2190b3303692acac3)
      echo "0x5A5A000E bandwidth lab, L2 miss path: ReleaseAck-first TLCacheCork, patch 0091, characterisation only (36,083 LUT) -- not validated for speech labs" ;;
    a028626c995b243c92ce9be46d432e77)
      echo "0x5A5A001A bandwidth lab, L2 miss path: skip clean Release, patch 0092 (36,078 LUT) -- not validated for speech labs" ;;
    f271cf9fb2d3df559707c2ee726591db)
      echo "0x5A5A0018 first build -- REFUSED (bitstream_refused): ChipTop axi4_mem_0 was 128-bit (WithEdgeDataBits without WithExtMemBeatBytes) into a 64-bit S_AXI_HP0; 0 console bytes, no rows" ;;
    36e753fd798551682115e0e1b0affa2d)
      echo "0x5A5A0018 bandwidth lab, L2 miss path: 128/128-bit L2 + skip clean Release (0092) + memory bus on FCLK1 timed at 100 MHz, ExtMem pinned 64-bit (40,291 LUT, WNS +1.256 core / +0.507 mem) -- not validated for speech labs" ;;
    d4674e1705028a55af174c644f577fa2)
      echo "0x5A5A0019 bandwidth lab, L2 miss path: as 0x5A5A0018 with 12 MSHRs (42,794 LUT, WNS +0.262 core / +0.380 mem) -- not validated for speech labs" ;;
    0d449ffd1b6b3d7696d43010cfb9574e)
      echo "0x5A5A0019 first build -- REFUSED (bitstream_refused): ChipTop axi4_mem_0 was 128-bit (WithEdgeDataBits without WithExtMemBeatBytes) into a 64-bit S_AXI_HP0; never loaded, no rows" ;;
    387cbb78742641e58273e42d26ea5354)
      echo "0x5A5A0016 bandwidth lab, bwbypass01 f111 (FCLK1 target 9 ns) -- not validated for speech labs" ;;
    bacbe69b7b1a080399dfba2351ac9f7d)
      echo "0x5A5A0016 bandwidth lab, bwbypass01 f125 (FCLK1 target 8 ns, runnable at 111.1 MHz) -- not validated for speech labs" ;;
    bf600a3b1de77d34487ac1399b05aea1)
      echo "0x5A5A0017 bandwidth lab, bwbypass4: L2-bypass instrument, 4 lanes on HP0-HP3, memory bus on FCLK1 (44,277 LUT) -- not validated for speech labs" ;;
    6ae531badb647ccf2c8a2cadcd755ac7)
      echo "0x5A5A001C bwwin, first build (FCLK1 target 10 ns): FAILS TIMING (FCLK0 WNS -0.002, one L2 scheduler endpoint; FCLK1 -0.885) -- a data point, NOT for measurement (48,569 LUT) -- not validated for speech labs" ;;
    0a3026ade7857ae3c6def89340e18c99)
      echo "0x5A5A001C bwwin f91: BwWindow (4 x 128-bit core-clock lanes) + DMA aperture, HP0-HP3, memory bus timed at 90.909 MHz; closed via ROCKET_POSTROUTE_PHYSOPT (FCLK1 WNS -0.054 -> +0.018 at 11 ns, fragile; FCLK0 +0.869, WHS +0.011 / +0.044) (48,547 LUT) -- not validated for speech labs" ;;
    659c6db6ecdbe091a7ff4494881f4e2e)
      echo "0x5A5A001E HM01B0 camera on the Z1 shield: 0x5A5A0010 + ospi capture with DMA (0x1008_0000) + TLI2C (0x1004_0000), engine RTL pinned to revision 1 by src/cam_engine_rev1 (41,080 LUT, 86.0 BRAM, WNS +1.126 / WHS +0.037 on clk_fpga_0. NOTE: the build log's TIMING_WNS is -1.566 and that is NOT the SoC clock -- it is the camera's input budget against a 36 MHz cam_pclk, the datasheet maximum this design cannot drive; the same routed design is +13.544 with 0 failing endpoints at 17.241 MHz, its fastest MCLK, and +71.5 at the lab's 5.747 MHz. Every failing endpoint is launched by a camera input port; none is register-to-register. CAMERA_Z1.md s7.5). Its PLIC differs from 0x5A5A0006/0010: I2C 1, UART 2, GPIO 3..8, so it needs the chipyard_pynqz1_cam board -- not validated for speech labs" ;;
    0a3737e5a1cea00b88fc5908925b55f2)
      echo "0x5A5A0013 roccmoon2b with the engine's two crossing fixes (fd949eb Gray counter, dc8a02a latched write destination): 39,411 LUT, 23,179 FF, 111 DSP, 85.5 BRAM36, WNS +0.451 FCLK0 / +0.532 FCLK1, report_cdc 0 unsafe. MEASURED: the W lane fills at 7.645 B per lane cycle, 764.5 MB/s at cap 4 (3.02x 0x5A5A0028), fill counter exact at 1,245,224 beats. STILL WRONG ARITHMETIC: 40 of 40 random exactness cases fail, non-deterministically, and the cause is not the descriptor, the cap, the ready handshake or the lane clock (MEMORY_BANDWIDTH.md 9.14.4) -- a bandwidth build, NOT a working accelerator, and not validated for speech labs" ;;
    033b351d815abc52f2002827ca2f2a7a)
      echo "0x5A5A0013 roccmoon2b, THE BUILD TO MEASURE: 0x5A5A0028 plus the WEIGHT LANE -- the engine's weight half on FCLK1 = 100.0000 MHz with its own AXI4 read lane into S_AXI_HP2 (39,350 LUT, 23,142 FF, 111 DSP, 85.5 BRAM36; WNS +1.118 FCLK0 / +0.713 FCLK1, WHS +0.024 / +0.073). Gates: W-lane gate on the nine engine files, tb_mbxr, MBP RTL selftest 3,055 checks, MEM_PORT_CONTRACT_OK, WLANE_RESET_FREE 18 flops, WLANE_XDC_QUERY 12 queries, WLANE_CDC_BOUND +3.239/+8.463 ns, report_cdc 0 unsafe 0 unknown with 739 endpoints waived by ID. The engine/lane crossings are BOUNDED at 10 ns both ways (src/pynqz2_wlane.xdc), worst 6.863 ns post-route (MEMORY_BANDWIDTH.md 9.12) -- not validated for speech labs" ;;
    074afc4c2a18023ee180721a8c64a6b6)
      echo "0x5A5A0013 roccmoon2b, SUPERSEDED by 033b351d and not to be measured: 0x5A5A0028 plus the WEIGHT LANE -- the engine's weight half on FCLK1 = 100.0000 MHz with its own AXI4 read lane into S_AXI_HP2 (39,347 LUT, 23,142 FF, 111 DSP, 85.5 BRAM36; WNS +0.839 FCLK0 / +0.383 FCLK1, WHS +0.012 / +0.133). Gates: W-lane gate on the nine engine files, tb_mbxr, MEM_PORT_CONTRACT_OK, WLANE_RESET_FREE 18 flops. KNOWN CONSTRAINT DEFECT: src/pynqz2_wlane.xdc's two set_max_delay lines matched 0 cells (wrong hierarchy names) and would have been overridden by set_clock_groups -asynchronous anyway, so the engine/lane crossings are unbounded in this build; measured worst 6.165 ns forward / 2.493 ns back against >= 2 lane cycles of protocol separation (MEMORY_BANDWIDTH.md 9.11) -- not validated for speech labs" ;;
    # The lane bitstreams (MAGIC_REGISTRY.md 0x5A5A0029/002A/002B/002C).  NAMED here so a lane
    # lab never calls them unknown; what is IN each one is fpga/pynq-z2/MAGIC_FEATURES.tsv's
    # answer, and feature_gate.py is what refuses a lab that dispatches to a lane a build lacks.
    3710420ad34e9cd93eacb2ca84b4e991)
      echo "0x5A5A0029 roccmoonlanes: 0x5A5A0028 PLUS THE TWO LANES (mbxr_ln + mbxa_core), engine rev 2a, one clock (44,295 LUT, 141 DSP, 90.5 BRAM36, WNS +0.512). Its LN streamer reads its word range ONCE" ;;
    1e8ea02d47dc9c2c7590a879de6c1d77)
      echo "0x5A5A002A roccmoonlanes2: 0x5A5A0029 plus ten lines of LN streamer (44,323 LUT, WNS +0.551). A range past the 1,024-word activation buffer still WRAPS SILENTLY; groupnorm_s16 is NOT reachable" ;;
    6145f18bd6b393c4b7db96dc3d5d9dcf)
      echo "0x5A5A002B lanesdev: the LANE DEVELOPMENT CONFIG -- 002A minus TACIT, the mic, the RGB GPIO, the P-EXTENSION and hart 0's pipelined multiplier (39,538 LUT, WNS +1.104). It refuses words > 1,024. A DIFFERENT MACHINE: it says nothing about fit or timing, and an image for it must emit no P-ext" ;;
    1bae0310c1e13048b22b4da9c72901ab)
      echo "0x5A5A002D roccmoonlut2: 0x5A5A002C with mbxl_lut's out_valid PULSED instead of held (44,897 LUT, 95.68 % slices, WNS +0.374, WHS +0.022). The LUT lane is dispatchable: arm A hung on 002C because mbxr_st pushes on every cycle in_valid is high and a held valid overflowed its FIFO" ;;
    995798bedfb15cff077ab58710af3bf8)
      echo "0x5A5A0035 roccmoonnch8f40b98b: NCH = 8 WITH THE ATTENTION LANE USABLE at FCLK0 = 40.0000 MHz -- 0x5A5A0034 with ONE LINE of mbxa_unit.v (qs*4 -> qs<<clog2(NCH), the hardware half of the attention image's plane-count contract). 0x5A5A0034 is engine-correct but its attention lane refuses every dispatch (attn_aerr 4 = err[2]) and a fused-attention graph runs 7.71x SLOWER with max_abs_err 0. Post-route 49,115 LUT (92.32 %), 27,567 FF, 13,295 slices (99.96 %, FIVE SPARE), 189 DSP, 106.5 BRAM36, WNS +0.102 / WHS +0.034, 0 failing of 96,978, WITH the post-route pass. Gated on all FOUR arms before P&R: run_nch8_gate.sh MBXR_NCH8_GATE_OK exit 0 -- engine 119 cases at NCH=8 and exact Gets/Puts/cycles at NCH=4, ATTN_TB_OK 0 differ at BOTH widths, MBXR_LANES_OK at both. Guest chipyard_pynqz1_micrgb_f40 built -DMBXR_NCH=8; load with --fclk 40" ;;
    0d89fe1077d22738d68aaa221c113516)
      echo "0x5A5A0034 roccmoonnch8f40b98: THE MAC ARRAY WIDENED TO NCH = 8 (64 MAC/cycle) at FCLK0 = 40.0000 MHz, WITH WEIGHT PLANE 7 ACTUALLY WRITTEN -- 0x5A5A0033 with ONE LINE of mbxr_engine.v changed (mbxr_whalf's port index 3 bits -> 4, so plane 7 addresses port 8 instead of wrapping to port 0 and being discarded). Post-route 49,098 LUT (92.29 %), 27,597 FF, 13,256 slices (99.67 %), 189 DSP, 106.5 BRAM36, WNS +0.137 / WHS +0.036, 0 failing of 96,988, WITH the post-route pass. GATED ON SIMULATION BEFORE P&R: run_nch8_gate.sh MBXR_NCH8_GATE_OK -- MBXR_TB_OK 119 cases at NCH = 8 and the shipping machine's exact Gets/Puts/cycles at NCH = 4. Its guest must be chipyard_pynqz1_micrgb_f40 AND built -DMBXR_NCH=8 (scripts/57/58/74 select it by MAGIC); load with --fclk 40" ;;
    275c728234a980f69689e22058b3470b)
      echo "0x5A5A0033 roccmoonnch8f40: THE MAC ARRAY WIDENED TO NCH = 8 (64 MAC/cycle) at FCLK0 = 40.0000 MHz -- 0x5A5A0032's engine with mbxa_core taking the NCH parameter it was never given (49,102 LUT, 99.79 % slices, 189 DSP, 106.5 BRAM36, WNS +0.208 WITH the post-route pass, which it needs). Its guest must be chipyard_pynqz1_micrgb_f40; load with --fclk 40" ;;
    # B135, the OLED/button panel on 0x5A5A0035's machine.  NAMED here so a run never calls
    # them unknown; deliberately NOT in BIT_ACCEPTED -- no speech lab has been re-measured on
    # either, and scripts/81_rocket_panel_board.sh accepts them for itself.
    f1f076322d221eceb6f096bbe42cf45f)
      echo "0x5A5A0037 roccmoonnch8f40b98bpanel: 0x5A5A0035's machine PLUS a TLI2C at 0x1004_0000 (SSD1306 bus, SCL = P16, SDA = P15) and BTN0..BTN3 on GPIO pins 6..9 (D19/D20/L20/L19), the controller widened 6 -> 10 pins. fclk 40 MHz, engine snapshot src/lanes_engine_b98nch8b unchanged and its collateral byte-identical to 0x5A5A0035's. Post-route 49,583 Slice LUTs (93.20 %), 27,879 FF, 13,297 slices (99.98 %, TWO SPARE), 189 DSP, 106.5 BRAM36; WNS +0.009 after the post-route phys_opt pass, 0 failing endpoints. ITS GUEST MUST BE chipyard_pynqz1_panel_f40: the PLIC renumbers (I2C 1, UART 2, GPIO 3..12, riscv,ndev 12), so a chipyard_pynqz1_micrgb_f40 guest gets the CONSOLE wrong and the board LOOKS DEAD. Load with run_rocket_roccmoonnch8f40b98bpanel.py --fclk 40. Lab B135 -- not validated for speech labs" ;;
    6c4a33661dd811bd1716051eb7435ad7)
      echo "0x5A5A0036 roccmoonnch8f40b98boled: 0x5A5A0035's machine PLUS a TLI2C at 0x1004_0000 and NOTHING ELSE -- B135's step-1 fit probe, kept because it is the machine to run if the buttons are not wanted. GPIO stays six pins. WNS +0.149 after the post-route pass. ITS GUEST MUST BE chipyard_pynqz1_oled_f40 (I2C 1, UART 2, GPIO 3..8, riscv,ndev 8). Load with run_rocket_roccmoonnch8f40b98boled.py --fclk 40. Lab B135 -- not validated for speech labs" ;;
    fc26e76dc83e7826206252bd0be64bbe)
      echo "0x5A5A002C roccmoonlut: 0x5A5A002A plus T4's LUT lane (44,904 LUT, 95.62 % slices, WNS +0.552). Nothing has ever dispatched to that lane" ;;
    # B137's EVERY-INTERFACE build.  NAMED here so a camera run does not call it unknown --
    # Lab B27 loaded it on both boards on 2026-09-21 and captured frames through it.  NOT in
    # BIT_ACCEPTED: no speech lab has been re-measured on it, and scripts/66 accepts it for
    # itself through its own --variant table.
    ced0aab0c7b52f25338eeffe8f678e4f)
      echo "0x5A5A0038 roccmoonnch8f40b98ball: EVERY INTERFACE AT ONCE at fclk 40 MHz -- the nch = 8 RoCC engine, the MBP P-extension on hart 0, the PDM mic, the six RGB pins, a TLI2C at 0x1004_0000, BTN0..BTN3 on GPIO 6..9 and the HM01B0 capture DMA at 0x1008_0000, with TACIT traded away to pay for it. Post-route 47,543 LUT (89.37 %) in 13,223 of 13,300 slices; clk_fpga_0 WNS +0.022 / WHS +0.035, 0 of 88,772 endpoints failing. THE DESIGN'S OVERALL WNS IS NEGATIVE AND THAT IS THE CAMERA'S PAD CONSTRAINT, NOT THE SoC: 387 cam_pclk endpoints against a 36 MHz constraint the design cannot drive (CAMERA_Z1.md 7.5). ITS GUEST MUST BE chipyard_pynqz1_all_f40 (I2C 1, UART 2, GPIO 3..12, ospi 13). Load with run_rocket_roccmoonnch8f40b98ball.py --fclk 40. CAMERA PROVEN ON SILICON, Lab B27 2026-09-21, both boards: one whole 326x324-byte frame per capture, DMA_STATUS 0x0a, PS checksum match (CAMERA_Z1.md 9.5)" ;;
    # B138, the TRACE bitstream.  NAMED here so a run never calls it unknown; deliberately
    # NOT in BIT_ACCEPTED -- it has no RoCC engine at all, so no speech lab can run on it.
    54838985885eacd88c28cc38cb0c829a)
      echo "0x5A5A0039 tracepanelcam: THE TRACE BITSTREAM -- TACIT on BOTH harts (encoders 0x300_0000/0x300_1000, sinks 0x301_0000/0x301_1000; TacitEncoder 895 LUT in RocketTile_1 and TacitEncoder_19 929 LUT in RocketTile, read out of the routed hierarchy report), the MBP P-extension on hart 0, the PDM mic, the six RGB pins, a TLI2C at 0x1004_0000, BTN0..BTN3 on GPIO 6..9 and the HM01B0 capture DMA at 0x1008_0000 -- and NO ROCCMOON ENGINE. fclk 40 MHz. Post-route 37,493 Slice LUTs (70.48 %), 22,174 FF, 11,009 slices (82.77 %), 63 DSP, 66 BRAM36; clk_fpga_0 WNS +0.005 / WHS +0.024, 0 failing of 70,556 -- WITHOUT any post-route pass. THE DESIGN'S OVERALL WNS IS -1.659 AND THAT IS THE CAMERA'S INPUT-CAPTURE CONSTRAINT, NOT THE SoC: all 387 failing endpoints are in the cam_pclk group, and the shipped camera bitstream 0x5A5A001E fails the same way (-1.566, the same 387). ***HART 1 HAS NO RoCC DECODE TABLE: every ModelBlaster custom-1 dispatch raises mcause 2.*** ITS GUEST MUST BE chipyard_pynqz1_trace_f40 (I2C 1, UART 2, GPIO 3..12, ospi 13, riscv,ndev 13). Load with run_rocket_tracepanelcam.py --fclk 40. Lab B138 -- BUILT, NEVER LOADED ON SILICON" ;;
    *) echo "UNKNOWN -- no speech lab has been validated against this build" ;;
  esac
}

# md5 -> why NO lab may load it.  Checked by bitstream_identify and bitstream_gate before, and
# regardless of, BIT_ACCEPTED -- a lab that widens its own accepted list (43 and 45 add the build
# they were pointed at) still cannot get past this.  host/run_rocket.py refuses the same md5s on
# the board, for a loader that never sources this file.  Each entry has a row in
# fpga/pynq-z2/bwlab/errata.csv.
bitstream_refused () {
  case "$1" in
    0a3026ade7857ae3c6def89340e18c99)
      echo "0x5A5A001C bwwin f91 -- REFUSED, under diagnosis: ladder step 1 at 08:47-08:50 on 2026-09-17 loaded it (MAGIC ok, FCLK0 34.4828 / FCLK1 90.9091 read back, saw_mem=1) and captured 0 console bytes; a TestHarness boot of the same RTL prints the Zephyr banner like 0017's; cause not established, deprioritised; 001C closed, not to be retried (MEMORY_BANDWIDTH.md s9.8)" ;;
    275c728234a980f69689e22058b3470b)
      echo "0x5A5A0033 roccmoonnch8f40 -- REFUSED, COMPUTES ONE OUTPUT CHANNEL IN EIGHT AS ZERO. mbxr_engine.v:512 is \`wire [2:0] pport = pr[2:0] + 3'd1\`: at NCH = 8 weight plane 7 addresses port 8, which does not fit three bits, so it wraps to port 0 -- whose banks only the ACTIVATION port writes -- and the write is silently discarded. \`pbad = (pr >= NCH)\` cannot catch it: the plane index is legal, the PORT NUMBER overflows. Measured in Verilator on the very sources this bitstream was built from: with a matched -DMBXR_NCH=8 guest, MBXR_TB_FAIL 109 of 119 cases, max_abs_err 114, and every wrong output n % 8 == 7 with got = 0. WITH THE SHIPPING MBXR_NCH=4 GUEST IT ONLY HANGS (B96: 0 of 4,125 dispatches, last_rc -4), which is why it looked loadable -- the moment a guest is built -DMBXR_NCH=8 to fix that hang, the dispatches complete and return wrong bytes with calls_engine > 0, calls_fallback = 0, last_rc = 0 and every scripts/74 gate GREEN. No id word can catch it: the engine reports NCH = 8 truthfully and implements seven usable planes. Never load (TODO.md, B98)" ;;
    52080a127204fc9ebe4fb89fd341510c)
      echo "B96 NCH=8 experiment -- REFUSED, COMPUTES ATTENTION WRONG AND BINDS THE SHIPPING MAGIC. mbxr_lanes.v:190 instantiates mbxa_core without passing NCH and mbxa_unit.v:202 fixes acc at [127:0], so the engine drives 256 bits and lanes 4-7 never reach the attention unit. Vivado logged Synth 8-689 at ERROR severity and still wrote a bitstream with BUILD_EXIT=0; it reports MAGIC 0x5A5A0032 like the shipping build, so the MAGIC check cannot catch it. Never load: it produces wrong answers silently (TODO.md, B96)" ;;
    f271cf9fb2d3df559707c2ee726591db|0d449ffd1b6b3d7696d43010cfb9574e)
      echo "build defective: 128-bit ExtMem into 64-bit HP0; 0 console bytes; no rows (the first builds of 0x5A5A0018/0019; rebuilt as 36e753fd/d4674e17; MEMORY_BANDWIDTH.md s6.9, bwlab/errata.csv)" ;;
    *) return 1 ;;
  esac
}

# 995798be 0x5A5A0035 added 2026-09-20 on the user's explicit call, by the route this file's own
# text prescribes rather than a BIT_ACCEPTED= override.  It qualifies on measurement, not on being
# convenient: run_nch8_gate.sh reached exit 0 on all four arms BEFORE place-and-route (the ordering
# 0x5A5A0033 and 0x5A5A0034 did not get); it has a bitstream_note() entry and a MAGIC_FEATURES.tsv
# row; its board pairs read attn_lane 48/48, attn_fallback 0, max_abs_err 0 with the guest cflags
# checked against the bank's before any counter; and the banked encoder term 0.524584 was measured
# on it.  It is not in bitstream_refused() -- unlike 0x5A5A0033, which IS, for computing one output
# channel in eight as zero while passing every cycle-counter gate.
BIT_ACCEPTED="${BIT_ACCEPTED:-7712bc03ff1d53bfdd4673cfd71b3296 566bc5402d0cab22130942bf9904bfdb 995798bedfb15cff077ab58710af3bf8}"

bitstream_identify () {
  local path="$1"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    BIT_MD5="not-loaded"
    BIT_NOTE="this run did not load a bitstream (--no-bitstream): whatever was already on
       the board is what was measured, and nothing here can say what that was"
    export BIT_MD5 BIT_NOTE
    warn "bitstream: NOT LOADED by this run -- the silicon is unidentified"
    return 0
  fi
  BIT_MD5=$(md5sum "$path" | cut -d' ' -f1)
  BIT_NOTE=$(bitstream_note "$BIT_MD5")
  export BIT_MD5 BIT_NOTE
  if BIT_REFUSED=$(bitstream_refused "$BIT_MD5"); then
    die "bitstream $(basename "$path") md5 $BIT_MD5 is REFUSED -- no lab may load it:
       $BIT_REFUSED"
  fi
  info "bitstream: $(basename "$path")  md5 $BIT_MD5"
  info "           $BIT_NOTE"
}

bitstream_gate () {
  if BIT_REFUSED=$(bitstream_refused "$BIT_MD5"); then
    die "bitstream md5 $BIT_MD5 is REFUSED -- no lab may load it, whatever BIT_ACCEPTED says:
       $BIT_REFUSED"
  fi
  case " $BIT_ACCEPTED " in
    *" $BIT_MD5 "*) return 0 ;;
  esac
  [ "$BIT_MD5" = "not-loaded" ] && return 0
  die "bitstream md5 $BIT_MD5 is not one this lab has been validated against.

       $BIT_NOTE

       The MAGIC check cannot catch this: SOC_MAGIC names the CONFIGURATION and every
       build of the mic + P-ext variant reports 0x5A5A0005, whatever changed inside it.

       If this is a legitimate new build, re-run the speech labs against it, confirm the
       headline numbers in SPEECH_ON_ROCKET.md section 7 still hold, and then add the md5
       to bitstream_note() and BIT_ACCEPTED in scripts/lib/bitstream_id.sh. Do not widen
       the list without re-measuring -- that is the whole point of it existing.

       To measure it anyway and knowingly: BIT_ACCEPTED=\"\$BIT_ACCEPTED $BIT_MD5\""
}

# ---- is the bitstream I am about to load the one this repo ships? ----------------------
#
# bitstream_identify()/bitstream_gate() above answer "what is in my hand"; they assume a
# file is already there.  bitstream_require() answers the question a fresh clone asks first:
# is the file there at all, is it intact, and -- if it is not in the checkout -- where else
# should I look.  It is what the board labs on the tutorial path call in place of the old
# `need_file "$BIT" "build it with ... build_pext_z1.sh"`, whose advice was addressed to
# someone with Vivado, a Chipyard tree and a day.
#
#   BIT="$(bitstream_require "$BIT")"
#
# Prints the resolved path on stdout; dies on absent-everywhere or on an md5 that disagrees
# with fpga/pynq-z2/bitstreams.csv.  A path that is not IN the manifest is returned unchanged
# and unverified -- exploratory builds do not have to register themselves, and making them
# would turn every RTL experiment into a manifest edit.
#
# Search order for a file that is not at the path given:
#   $IISWC_BIT_DIR/<basename>     an unpacked release tarball, or a mounted card
#   /opt/iiswc/bit/<basename>     the on-card layout used when bitstreams ship on the SD card
BIT_MANIFEST="${BIT_MANIFEST:-$IISWC_ROOT/fpga/pynq-z2/bitstreams.csv}"

# bitstream_manifest_md5 <basename> -> md5 on stdout, empty if the file is not listed
bitstream_manifest_md5 () {
  [ -f "$BIT_MANIFEST" ] || return 0
  awk -F, -v b="$1" '!/^#/ && NR>1 { n=split($1,p,"/"); if (p[n]==b) { print $2; exit } }' "$BIT_MANIFEST"
}

bitstream_require () {
  local want="$1" base found=""
  base="$(basename "$want")"

  if [ -f "$want" ]; then
    found="$want"
  else
    local d
    for d in "${IISWC_BIT_DIR:-}" /opt/iiswc/bit; do
      [ -n "$d" ] && [ -f "$d/$base" ] && { found="$d/$base"; break; }
    done
  fi

  if [ -z "$found" ]; then
    die "bitstream not found: $base

       Looked in:  $want
                   \${IISWC_BIT_DIR}/$base   (IISWC_BIT_DIR=${IISWC_BIT_DIR:-unset})
                   /opt/iiswc/bit/$base

       This repo does NOT build bitstreams on the tutorial path and you do not need Vivado.
       fpga/pynq-z2/bitstreams.csv lists every bitstream the labs use, its md5, and whether
       it is tracked in git (a clone has it) or shipped alongside on the SD card / in the
       release tarball.  If it says 'git' and the file is missing, your checkout is
       incomplete: re-clone, or check git status.  If it says 'untracked', point
       IISWC_BIT_DIR at the unpacked tarball or mount the card.

       See the "Bitstreams" section of README.md."
  fi

  local want_md5; want_md5="$(bitstream_manifest_md5 "$base")"
  if [ -n "$want_md5" ]; then
    local got; got="$(md5sum "$found" | cut -d' ' -f1)"
    if [ "$got" != "$want_md5" ]; then
      die "bitstream $base is NOT the one this repo ships.

       file:     $found
       md5:      $got
       expected: $want_md5   (fpga/pynq-z2/bitstreams.csv)

       A bitstream that is not the one the goldens were measured against is not a smaller
       problem than no bitstream at all: every expected/*.json number was produced on the
       expected one.  Do not 'fix' this by editing the manifest -- find out which file you
       have.  scripts/check_bitstreams.sh reports every row at once."
    fi
  fi

  printf '%s\n' "$found"
}
