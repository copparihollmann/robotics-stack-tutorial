#!/usr/bin/env python3
"""Load a decoupled-RoCC-engine bitstream and run a program on it.

Identical to run_rocket_micrgb.py except for the MAGIC it insists on.  The SoC is
register-compatible with 0x5A5A0006 for everything the other labs touch -- same UART,
microphone, GPIO and DRAM window -- so an image built for either boots on the other.  What
differs is a RoCC in hart 1's tile answering custom-1, and an image that issued custom-1 on
the full-feature build would take an illegal-instruction trap and report nothing useful.

ONE RUNNER, THE MAGIC KEYED BY ITS NAME.  The engine family shares this file; each build's name
is a symlink to it (run_rocket_roccmoonmul.py, run_rocket_roccmoon2a.py, run_rocket_roccmoonall.py,
run_rocket_roccmoon2b.py, run_rocket_roccmoonlanes.py, run_rocket_roccmoonlanes2.py,
run_rocket_roccmoonlut.py), and the MAGIC it
insists on is looked up from the name it was invoked as -- strictly: a name not in the table is
refused, and a bitstream reporting any other MAGIC is refused at load.  The labs scp the runner
under its own name, so the lookup works on the board too.

MAGIC registry (fpga/pynq-z2/MAGIC_REGISTRY.md):
  0x5A5A0010  roccmoon     the decoupled RoCC engine on hart 1 (ROCC_DECOUPLED.md section 8)
  0x5A5A0011  roccmoonmul  + the big core's pipelined multiplier (section 8.15.3)
  0x5A5A0012  roccmoon2a   engine revision 2a (section 8.15.5)
  0x5A5A0028  roccmoonall  revision 2a + the multiplier + 0092's skipped clean Release (8.15.9)
  0x5A5A0013  roccmoon2b   revision 2b + the WEIGHT LANE on FCLK1 into S_AXI_HP2 (MEMORY_BANDWIDTH.md 9.9-9.12)
  0x5A5A0029  roccmoonlanes   0028 + the attention unit and the normalisation lane inside the
                              engine (LAYERNORM_LANE.md sections 13-17).  The bitstream is
                              archive/bitstreams/0x5A5A0029_roccmoonlanes_3710420a.bit; the tcl
                              variant has since moved to 002A, so this entry exists to keep the
                              archived bitstream runnable.
  0x5A5A002C  roccmoonlut     002A + T4's LUT lane (mbxl_lut as lane 4).  Bitstream
                              archive/bitstreams/0x5A5A002C_roccmoonlut_fc26e76d.bit.  The
                              LUT lane is IDLE in every run so far -- nothing has dispatched
                              to it; the attention unit and the norm lane are 002A's.
  0x5A5A0030  roccmoonf40  0x5A5A002E's SoC, engine RTL pinned byte for byte, TIMED AND RUN
                            at FCLK0 = 40.0000 MHz -- the highest this design closes at
                            (B79).  ITS GUEST MUST BE BUILT FOR chipyard_pynqz1_micrgb_f40:
                            a 34483 guest here garbles the console and runs mtime 16 % fast.
  0x5A5A0031  roccmoonint6f40  0x5A5A002F's engine -- the int6 weight unpacker at the read
                            port -- at FCLK0 = 40.0000 MHz.  md5 de4ec983.  ITS GUEST MUST BE
                            BUILT FOR chipyard_pynqz1_micrgb_f40, like 0x5A5A0030's.
  0x5A5A0032  roccmoonint6f41667  the same engine at FCLK0 = 41.6667 MHz (1000/24), which is
                            the rung B79 called the ceiling and B81 falsified on a clean tree.
                            ITS GUEST MUST BE BUILT FOR chipyard_pynqz1_micrgb_f41667: a
                            34483 guest reads 139,353 baud here and an f40 guest 120,077,
                            against 115,200 -- both garble the console rather than failing.
                            Lab B83.
  0x5A5A0036  roccmoonnch8f40b98boled   0x5A5A0035 + a TLI2C at 0x1004_0000 (the SSD1306
                            OLED bus on P16/P15).  md5 6c4a3366.  ITS GUEST MUST BE BUILT
                            FOR chipyard_pynqz1_oled_f40 -- the PLIC renumbers (I2C 1,
                            UART 1 -> 2, GPIO 2..7 -> 3..8) and a micrgb_f40 guest gets
                            the CONSOLE wrong, which looks like a dead board.  Lab B135.
  0x5A5A0037  roccmoonnch8f40b98bpanel  0x5A5A0036 + BTN0..BTN3 on GPIO pins 6..9 (D19,
                            D20, L20, L19), the controller widened 6 -> 10.  md5 f1f07632.
                            GPIO takes PLIC 3..12, riscv,ndev 12, UART still 2.  ITS GUEST
                            MUST BE BUILT FOR chipyard_pynqz1_panel_f40.  B135's
                            deliverable, and the tutorial panel.
  0x5A5A002A  roccmoonlanes2  0029 + the streamer's two-pass replay, so groupnorm_s16 is
                              reachable through the unit (LAYERNORM_LANE.md section 18).  Built
                              by the SAME tcl variant and so the SAME .bit filename as 0029 --
                              pass it with --bitstream; only the MAGIC distinguishes them, which
                              is exactly what this table is for.

A NAME NOT IN THE TABLE IS REFUSED, and the refusal looks like a bad bitstream: the MAGIC is
read correctly off the PL and then rejected.  Two people have now lost a board session to that,
once for a missing entry and once because script 50 defaults to the `mic` runner for a `micrgb`
SoC.  If a load fails with "*** MISMATCH ***" on a MAGIC you believe is right, check this table
before you suspect the build.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

EXPECT_BY_RUNNER = {
    "run_rocket_roccmoon.py":    0x5A5A_0010,
    "run_rocket_roccmoonmul.py": 0x5A5A_0011,
    "run_rocket_roccmoon2a.py":  0x5A5A_0012,
    "run_rocket_roccmoonall.py": 0x5A5A_0028,
    "run_rocket_roccmoonlanes.py": 0x5A5A_0029,
    "run_rocket_roccmoonlut.py": 0x5A5A_002C,
    "run_rocket_roccmoonlut2.py": 0x5A5A_002D,
    "run_rocket_roccmoondrain.py": 0x5A5A_002E,
    "run_rocket_roccmoonint6.py": 0x5A5A_002F,
    "run_rocket_roccmoonf40.py": 0x5A5A_0030,
    "run_rocket_roccmoonint6f40.py": 0x5A5A_0031,
    "run_rocket_roccmoonint6f41667.py": 0x5A5A_0032,
    # B96: the widened array (NCH = 8) at 40 MHz.  Its guest is pynqz1_micrgb_f40.
    # 0x5A5A0033 IS REFUSED (run_rocket.py REFUSED_MD5): its weight plane 7 is silently
    # discarded.  The name stays so a stale invocation gets the REFUSED message rather than
    # "not an engine-family runner name", which would look like a typo.
    "run_rocket_roccmoonnch8f40.py": 0x5A5A_0033,
    # B98: the same array with mbxr_whalf's port index widened to four bits -- the CORRECTED
    # NCH = 8 build.  Its guest is pynqz1_micrgb_f40 AND must be built -DMBXR_NCH=8.
    "run_rocket_roccmoonnch8f40b98.py": 0x5A5A_0034,
    # B98: the same array with the attention lane's plane layout and mbxa_unit.v:248
    # taking NCH.  0x5A5A0034 is engine-correct but refuses every attention dispatch.
    "run_rocket_roccmoonnch8f40b98b.py": 0x5A5A_0035,
    # B135: 0x5A5A0035 PLUS A TLI2C at 0x1004_0000 (the OLED bus), and nothing else.
    # ITS GUEST MUST BE BUILT FOR chipyard_pynqz1_oled_f40, not chipyard_pynqz1_micrgb_f40:
    # the TLI2C takes PLIC source 1, so the UART moves 1 -> 2 and the GPIO 2..7 -> 3..8.
    # A micrgb_f40 guest here points the console's interrupt at the I2C controller and the
    # board LOOKS DEAD rather than failing -- the MAGIC gate below is what stops the
    # reverse mistake, and only the board choice stops this one.
    "run_rocket_roccmoonnch8f40b98boled.py": 0x5A5A_0036,
    # B135: the same machine plus BTN0..BTN3 on GPIO pins 6..9 (the controller widened
    # 6 -> 10).  GPIO takes PLIC sources 3..12 and riscv,ndev is 12; the UART is still 2.
    # ITS GUEST MUST BE BUILT FOR chipyard_pynqz1_panel_f40.  This is B135's deliverable.
    "run_rocket_roccmoonnch8f40b98bpanel.py": 0x5A5A_0037,
    # B137: EVERY INTERFACE AT ONCE -- 0x5A5A0037's panel PLUS the camera's ospi capture DMA
    # at 0x1008_0000, and WITHOUT TACIT, which is what paid for it.  The ospi takes PLIC
    # source 13 and riscv,ndev goes 12 -> 13; the I2C is still 1, THE CONSOLE IS STILL 2 and
    # the GPIO is still 3..12, so a panel_f40 guest boots here with a working console and
    # simply cannot see the camera.  ITS GUEST SHOULD BE BUILT FOR chipyard_pynqz1_all_f40.
    # NOTE WHAT IS GONE: no trace encoder and no trace sink.  samples/tacit_boot and
    # samples/membench must keep to 0x5A5A0035/36/37, which still have them.
    "run_rocket_roccmoonnch8f40b98ball.py": 0x5A5A_0038,
    "run_rocket_roccmoonlanes2.py": 0x5A5A_002A,
    "run_rocket_roccmoon2b.py":  0x5A5A_0013,
}
# THE CLOCK EACH BUILD IS TIMED AT, keyed the same way as the MAGIC and for the same reason.
# Every build in this family is timed at 1000/29 MHz except 0x5A5A0030, which IS the clock
# change (0x5A5A002E's logic at FCLK0 = 40.0000 MHz; MAGIC_REGISTRY.md 0x5A5A0030).
#
# run_rocket.py programs pynq.ps.Clocks.fclk0_mhz ONLY on the load path and only from --fclk,
# whose default this sets. A 40 MHz bitstream loaded with the family default would be clocked
# at 34.4828 -- it would run, and every cycle count taken on it would be attributed to the
# wrong clock. So the default follows the name; the labs pass --fclk as well, and fclk.py
# reads the SLCR back afterwards, because one guard on a silent failure is not enough.
DEFAULT_FCLK_BY_RUNNER = {"run_rocket_roccmoonf40.py": 40.0,
                          "run_rocket_roccmoonint6f40.py": 40.0,
                          # 1000/24.  Written to four places like the family default
                          # below; the labs derive the Hz they divide by from N = 24,
                          # not from this rounded MHz, so the two never drift.
                          "run_rocket_roccmoonint6f41667.py": round(1000.0 / 24.0, 4),
                          # 1000/25, exact.  0x5A5A0033 is TIMED at 40 MHz and closes with
                          # only +0.208 ns; loading it at the 34.4828 family default would
                          # run it slow and attribute every cycle to the wrong clock.
                          "run_rocket_roccmoonnch8f40.py": 40.0,
                          # 0x5A5A0034, B98's corrected widening: same clock as 0x5A5A0033.
                          "run_rocket_roccmoonnch8f40b98.py": 40.0,
                          "run_rocket_roccmoonnch8f40b98b.py": 40.0,
                          # 0x5A5A0036 and 0x5A5A0037 are 0x5A5A0035's machine with an
                          # MMIO device added and (for the panel) four GPIO pins; both are
                          # TIMED at FCLK0 = 40.0000 MHz = 1000/25, exact on this PS7.
                          # 0x5A5A0037 closes with WNS +0.009 ns, so loading it at the
                          # family's 34.4828 default would not merely misattribute cycles
                          # -- but it is still the clock it was timed at that must be set.
                          "run_rocket_roccmoonnch8f40b98boled.py": 40.0,
                          "run_rocket_roccmoonnch8f40b98bpanel.py": 40.0,
                          # 0x5A5A0038 is the same machine again at 1000/25: the clock is
                          # the one thing B137 was not allowed to spend.
                          "run_rocket_roccmoonnch8f40b98ball.py": 40.0}
_name = os.path.basename(sys.argv[0])
if _name not in EXPECT_BY_RUNNER:
    sys.exit(f"{_name}: not an engine-family runner name ({', '.join(sorted(EXPECT_BY_RUNNER))})")
run_rocket.EXPECT_MAGIC = EXPECT_BY_RUNNER[_name]
# 1000 MHz / 29, to four places. Written as the division so the provenance is in the file.
run_rocket.DEFAULT_FCLK = DEFAULT_FCLK_BY_RUNNER.get(_name, round(1000.0 / 29.0, 4))

if __name__ == "__main__":
    run_rocket.main()
