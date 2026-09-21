#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Does the generated model reproduce its OWN baked golden, on the HOST, before any board?

WHY THIS EXISTS, and it cost four board arms to learn.  2026-09-19, Lab B97: `scripts/74
--replay` reported `max_abs_err = 70` on 0x5A5A0032 and I took it for a correctness failure of
the shipping bitstream.  It reproduced at 70 on 0x5A5A002D, at 70 on a second run, at 70 with
B57's kernels and at 70 with the kernel feature macros on -- four board arms, two bitstreams,
two clocks, one number.  THE IDENTICAL VALUE WAS THE EVIDENCE: a marginal or bitstream-specific
fault does not reproduce a magnitude.  One host compile settled it -- the model does not
reproduce its own golden with MB_PEXT_HW=0 either, so no board was ever the variable.

The defect is in the GEN step, not in the stored tensors: `io.npz` bf32c927 is byte-identical
across out/decint8/ir, out/b89b/G8/ir and the passing arm's IR, and the SAME io.npz yields two
different `test_golden.bin` --

    f02d7c7e   decint8/gen_eng, decint8/gen_nl, b57_dec_tokens/gen, b97/gen   HOST err 70
    cbb8f067   b87ln_ctl/dec_q16/gen                                          HOST err 0

-- so a correct golden for these tensors demonstrably EXISTS and one codegen path bakes one the
model does not compute.  That is why this check reports WHICH golden it is holding rather than
only that it disagrees: "mismatch" sends you to the board, "your golden is f02d7c7e and a
known-good one for the same io.npz is cbb8f067" sends you to the generator.

It is the 438eb27 lie inverted.  That was `max_abs_err = 0` over 0 bytes compared; this is
`max_abs_err = 70` against something that is not a golden.  A number against an unvalidated
reference is worse than no number, because it looks like a measurement.

    golden_preflight.py <gen dir> [--weights-o <path>]   -> exit 0 clean, 1 mismatch
"""
import argparse, hashlib, json, os, subprocess, sys, tempfile

# Goldens whose gen path is known good / known bad for this decoder io.npz (B97, 2026-09-19).
KNOWN_GOOD = {"cbb8f067": "b87ln_ctl/dec_q16/gen (scripts/58 dec_q16 path)"}
KNOWN_BAD = {"f02d7c7e": "decint8/gen_eng, decint8/gen_nl, b57_dec_tokens/gen, b97/gen "
                         "-- HOST max_abs_err 70 against the model generated beside it"}

CHK = r"""
#include <stdio.h>
#include <stdint.h>
#include "model.h"
#include "test_io.h"
static model_output_t model_output[MODEL_OUTPUT_SIZE];   /* exactly as the sample declares it */
int main(void) {
    model_run_test(model_output, NULL);
    int mx = 0; long first = -1, n = 0;
    for (int i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
        int d = (int)model_output[i] - (int)model_test_golden[i];
        if (d < 0) d = -d;
        if (d) { n++; if (first < 0) first = i; }
        if (d > mx) mx = d;
    }
    printf("%d %ld %ld %d\n", mx, n, first, (int)MODEL_TEST_OUTPUT_LEN);
    return 0;
}
"""


def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 22), b""):
            h.update(c)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("gen")
    ap.add_argument("--weights-o", default=None,
                    help="prebuilt weights.o; compiled here if omitted (77 MB of C, ~1 min)")
    ap.add_argument("--json", default=None)
    a = ap.parse_args()
    gen = os.path.abspath(a.gen)
    # The two -I paths below are inside THIS repo. Resolve them from this file's own
    # location (scripts/lib/ -> repo root), not from an absolute path that only exists
    # on the machine it was written on. $IISWC_ROOT still wins if a caller sets it.
    root = os.environ.get("IISWC_ROOT") or os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for f in ("model.c", "kernels.c", "buffers.c", "test_io.S", "test_golden.bin"):
        if not os.path.exists(os.path.join(gen, f)):
            sys.exit("golden_preflight: %s has no %s" % (gen, f))
    gmd5 = md5(os.path.join(gen, "test_golden.bin"))

    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "chk.c")
        open(src, "w").write(CHK)
        wo = a.weights_o
        if not wo:
            wo = os.path.join(td, "weights.o")
            subprocess.run(["cc", "-O0", "-c", "-w", "-I", gen,
                            os.path.join(gen, "weights.c"), "-o", wo], check=True)
        exe = os.path.join(td, "chk")
        cmd = ["cc", "-O2", "-w", "-std=gnu11", "-ffp-contract=off", "-DMB_PEXT_HW=0",
               "-I%s/fpga/pynq-z2/modelblaster/check/shim" % root, "-I" + gen,
               "-I%s/fpga/pynq-z2/sw" % root, src] + \
              [os.path.join(gen, f) for f in ("model.c", "kernels.c", "buffers.c", "test_io.S")] + \
              [wo, "-o", exe, "-lm"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            sys.exit("golden_preflight: host build failed\n" + r.stderr[-2000:])
        out = subprocess.run([exe], capture_output=True, text=True)
        if out.returncode:
            sys.exit("golden_preflight: the host model crashed (rc %d)" % out.returncode)
        mx, ndiff, first, total = (int(x) for x in out.stdout.split())

    rec = {"gen": gen, "golden_md5": gmd5, "host_max_abs_err": mx,
           "bytes_differing": ndiff, "bytes_total": total, "first_diff_byte": first,
           "verdict": "clean" if mx == 0 else "GOLDEN MISMATCH"}
    if a.json:
        json.dump(rec, open(a.json, "w"), indent=1)
    if mx == 0:
        print("    golden pre-flight: HOST max_abs_err=0 over %d bytes, golden md5 %s -- this "
              "gen reproduces its own golden, so a BOARD max_abs_err means the board"
              % (total, gmd5[:8]))
        return 0

    print("    golden pre-flight: FAILED WITHOUT A BOARD.")
    print("      HOST max_abs_err=%d over %d bytes; %d differ; first at byte %d"
          % (mx, total, ndiff, first))
    print("      this gen's golden md5 is %s" % gmd5[:8])
    if gmd5[:8] in KNOWN_BAD:
        print("      that golden is KNOWN BAD: %s" % KNOWN_BAD[gmd5[:8]])
    for k, v in KNOWN_GOOD.items():
        print("      a known-good golden for this decoder io.npz is %s, from %s" % (k, v))
    print("      io.npz is NOT the problem -- the same stored tensors produce both goldens.")
    print("      A BOARD max_abs_err MEANS NOTHING HERE: it would measure this mismatch, not")
    print("      the machine.  Fix the gen path or use the arm that does not need a golden")
    print("      (the token comparison against dec_driver.c).  Refusing the board.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
