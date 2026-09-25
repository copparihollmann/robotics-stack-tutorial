"""Where this workstream's inputs and outputs live, with NO path baked into a default.

Every tool in this directory used to carry an absolute default into one machine's scratch
directory.  That is right on exactly one bench and wrong -- silently, as a missing file or,
worse, as somebody else's file -- everywhere else.  The two roots below are resolved from
this file's own location and can be overridden by environment, so a clone works unmodified:

    IISWC_OUT     run outputs.  Default <repo>/out, the same directory env.sh gives the
                  shell scripts, so `out("signdet/gen")` and `$IISWC_OUT/signdet/gen` are
                  the same tree.

    SIGNDET_WORK  the TRAINING side: datasets, checkpoints, per-lab probe outputs.  Default
                  <repo>/out/signdet_work.  It is separate from IISWC_OUT because it holds
                  the things this repository deliberately does not ship -- a GTSDB copy you
                  obtained yourself, and any checkpoint trained from it -- and keeping them
                  under one name makes it obvious what an operator has to supply and what is
                  merely generated.

NOTHING HERE IMPLIES THE DATA EXISTS.  work() builds a path; it does not create or fetch
anything.  GTSDB in particular must be obtained from its own source (see make_data.py).
"""
from __future__ import annotations
import os

HERE = os.path.dirname(os.path.abspath(__file__))
#          signdet/  modelblaster/  pynq-z2/   fpga/     <repo>
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

OUT_ROOT = os.environ.get("IISWC_OUT") or os.path.join(ROOT, "out")
WORK_ROOT = os.environ.get("SIGNDET_WORK") or os.path.join(OUT_ROOT, "signdet_work")


def out(*parts: str) -> str:
    """A path under $IISWC_OUT (default <repo>/out)."""
    return os.path.join(OUT_ROOT, *parts)


def work(*parts: str) -> str:
    """A path under $SIGNDET_WORK (default <repo>/out/signdet_work)."""
    return os.path.join(WORK_ROOT, *parts)
