#!/usr/bin/env python3
"""Load 0x5A5A0013 (the W lane) and set the LANE CLOCK, FCLK1, from this file's own name.

    run_rocket_wlane_f100.py   FCLK1 = 100      MHz   the frequency the design is timed at
    run_rocket_wlane_f50.py    FCLK1 =  50      MHz
    run_rocket_wlane_f34.py    FCLK1 =  34.4828 MHz   the same clock as the engine's

WHY A RUNNER AND NOT A FLAG.  scripts/51_rocket_roccmoon.sh scp's the runner it is told to use and
invokes it twice -- once to load the bitstream and hold the SoC, once to place the ELF -- with a
fixed argument list.  There is no way to pass it an extra flag, and the engine family's runner
(run_rocket_roccmoon.py) belongs to another workstream, so this file keys the lane clock by its own
name exactly as that one keys MAGIC by its name.  Nothing else about the run changes.

WHY THE LANE CLOCK IS WORTH SWEEPING.  0x5A5A0013 returns wrong bytes for short weight loads and the
wrong answers are NOT REPRODUCIBLE -- the count of wrong elements moves run to run and one case that
failed once passed the next time (MEMORY_BANDWIDTH.md 9.14.3).  That is a race between the engine's
two clock domains.  If the errors thin out or vanish as FCLK1 slows, the fault is setup time on the
FCLK0/FCLK1 boundary; if they are unchanged at a third of the frequency, it is not setup time and the
remaining suspect is the engine's own concurrency.  Slowing a clock a design closed timing at is
safe: setup margin only grows, and hold does not depend on the period.

FCLK1 IS SET BEFORE THE PL IS LOADED, while the SoC is still in reset, and read back afterwards by
the lab's own fclk.py call.  The value that reaches run.json is the READING, never this number.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

FCLK1_BY_RUNNER = {
    "run_rocket_wlane_f100.py": 100.0,
    "run_rocket_wlane_f50.py": 50.0,
    "run_rocket_wlane_f34.py": round(1000.0 / 29.0, 4),
}
_name = os.path.basename(sys.argv[0])
if _name not in FCLK1_BY_RUNNER:
    sys.exit(f"{_name}: not a W-lane sweep runner name ({', '.join(sorted(FCLK1_BY_RUNNER))})")

run_rocket.EXPECT_MAGIC = 0x5A5A_0013
run_rocket.DEFAULT_FCLK = round(1000.0 / 29.0, 4)     # FCLK0, as every engine build is timed

if "--no-load" not in sys.argv:
    want = FCLK1_BY_RUNNER[_name]
    try:
        from pynq.ps import Clocks
        before = Clocks.fclk1_mhz
        Clocks.fclk1_mhz = want
        print(f"FCLK1 (W lane): {before:.4f} -> {Clocks.fclk1_mhz:.4f} MHz (asked for {want})")
    except Exception as e:                            # noqa: BLE001 -- report and carry on; fclk.py gates
        print(f"warning: could not set FCLK1 ({e}); the lab's fclk.py read-back is what counts")

run_rocket.main()
