#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""RTF_e2e from the two board records -- composed arithmetically, and saying so.

    python3 model_rtf_e2e.py --enc out/e2e_enc_qatu/run.json --dec out/dec_cse_on/run.json

WHY THIS WAS REWRITTEN (2026-09-18).  The previous version read `steady_cycles` from each
record and added the two RTFs.  Three things were wrong with that, and all three produced a
number rather than an error:

  * `steady_cycles` meant two different things.  The decoder lab computed it as
    `rows - image` while its rows did NOT contain the image build; the encoder lab computed it
    the same way while its rows DID.  One of the two halves of the headline 6.885 was wrong and
    nothing in the composition could see it.  Both labs now publish
    `cycles_accounting.definition`, and THIS SCRIPT REFUSES A RECORD THAT DOES NOT CARRY ONE.
  * the per-step row sums put the ENTIRE weight image build inside step 0 (the runtime images
    each layer's weights on first use, which for the decoder is step 0).  Summing the first
    ~12 steps therefore charged every utterance a 416 M-cycle one-time cost.  The steady
    composition now subtracts it and says so; the cold one keeps it.
  * the rows themselves were joined to the IR by op NAME, and the unrolled decoder has 80
    names borne by 24 ops each.  Fixed in the labs, not here -- but this script now checks
    `join_key` and refuses a record parsed the old way.

WHAT THIS NUMBER IS NOT.  It is a COMPOSITION, not a measurement of one run.  The harness runs
one model per image (`samples/modelblaster_pext` takes a single MODEL_DIR), so the encoder and
the decoder cannot be run as one on this board without building a multi-model image, which
would be a different experiment.  The assumptions are listed in the output under `assumes` and
every one of them is a way this number could be optimistic.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
R = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))

# THE PER-OP KERNEL MANIFEST, shared with the labs rather than re-implemented here.  Two
# decoder arms matched on soc_magic, bitstream_md5, roccmoon_md5 AND kernel_cflags and still
# ran silu_s8 on different kernels -- 7.82x, 18 % of the decoder -- and this script composed
# one of them into a headline number before an op-by-op diff of two archived runs found it.
sys.path.insert(0, os.path.join(R, "fpga", "pynq-z2", "scripts"))
try:
    import kernel_manifest as KM
except ImportError:                                   # refused at the point of use, not here
    KM = None


class Refuse(Exception):
    pass


def model_of(rec: dict) -> dict:
    ms = rec.get("models") or {}
    if len(ms) != 1:
        raise Refuse("record has %d models, expected exactly 1" % len(ms))
    return next(iter(ms.values()))


def vet(m: dict, which: str) -> None:
    """Refuse a record this composition cannot read honestly."""
    acct = m.get("cycles_accounting") or {}
    if not acct.get("definition"):
        raise Refuse("%s record has no cycles_accounting.definition -- it was written by a "
                     "reporter that ASSUMED which convention applied. Re-run its report step."
                     % which)
    if acct["definition"] == "unresolved":
        raise Refuse("%s record's rows and image build do not reconcile with its wall clock "
                     "under either convention; no per-iteration figure exists" % which)
    if m.get("join_key") != "dispatch_id":
        raise Refuse("%s record was parsed with join_key=%r; rows joined by op name are not "
                     "trustworthy on an unrolled graph. Re-run its report step."
                     % (which, m.get("join_key")))
    if m.get("console_duplicate_ids"):
        raise Refuse("%s record has duplicate dispatch ids on its console" % which)
    if m.get("max_abs_err_meaning") != "matched":
        raise Refuse("%s record's max_abs_err is %r (%s), not a verified match"
                     % (which, m.get("max_abs_err"), m.get("max_abs_err_meaning")))
    if m.get("dispatches_profiled") != m.get("dispatches_in_ir"):
        raise Refuse("%s record profiled %s of %s dispatches"
                     % (which, m.get("dispatches_profiled"), m.get("dispatches_in_ir")))
    if m.get("cycles_per_iteration") is None:
        raise Refuse("%s record carries no cycles_per_iteration" % which)


def manifest(m: dict, which: str) -> dict:
    """The record's op -> kernel mapping, DERIVED from its own rows and checked against the
    digest it recorded.  A record that predates the field still yields a mapping; a record
    whose recorded digest disagrees with its own rows is refused, because the two copies of
    the derivation (this one and the one archived inside the run's report.py) can drift and a
    digest nobody re-derives is a digest that can go quietly wrong."""
    if KM is None:
        raise Refuse("fpga/pynq-z2/scripts/kernel_manifest.py is not importable, so the kernel "
                     "sets of the two halves cannot be recorded. This composition refuses "
                     "rather than publish a number with no record of which kernels produced it")
    try:
        return KM.manifest_of("(%s record)" % which, which, m)
    except KM.Refuse as e:
        raise Refuse(str(e))


def decoder_steps(m: dict) -> tuple[list[int], int]:
    """Per-step dispatch cycles, and the image build that sits inside step 0."""
    per = collections.Counter()
    for r in m["rows"]:
        per[r["step"]] += r["cycles"]
    ks = sorted(per)
    if ks != list(range(len(ks))):
        raise Refuse("decoder steps are not 0..N-1: %s" % ks[:5])
    img = (m.get("engine") or {}).get("image_cycles") or 0
    return [per[k] for k in ks], img


def take(steps: list[int], n: float) -> float:
    """Cost of the first `n` steps, `n` fractional (the measured mean token count)."""
    if n > len(steps):
        raise Refuse("mean token count %.3f exceeds the %d steps the graph was unrolled to; "
                     "the record cannot price an utterance that long" % (n, len(steps)))
    whole = int(n)
    c = float(sum(steps[:whole]))
    if whole < len(steps):
        c += (n - whole) * steps[whole]
    return c


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--enc", required=True)
    ap.add_argument("--dec", required=True)
    ap.add_argument("--mean-steps", type=float, default=11.976470588235294,
                    help="measured mean emitted tokens per utterance")
    ap.add_argument("--mean-steps-source",
                    default="decoder_tokens_dev.json models.R.mean (dev_clean, 765 utterances)")
    ap.add_argument("--json", default=os.path.join(HERE, "model_rtf_e2e.json"))
    a = ap.parse_args()

    enc_rec, dec_rec = json.load(open(a.enc)), json.load(open(a.dec))
    E, D = model_of(enc_rec), model_of(dec_rec)
    for m, w in ((E, "encoder"), (D, "decoder")):
        vet(m, w)

    clk = E["clock_hz"]
    win = E["window_s"]
    if D["clock_hz"] != clk or D["window_s"] != win:
        raise Refuse("the two records were taken at different clock/window: %s/%s vs %s/%s"
                     % (clk, win, D["clock_hz"], D["window_s"]))
    for k in ("soc_magic", "bitstream_md5"):
        if E.get(k) != D.get(k):
            raise Refuse("the two records are not the same %s: %r vs %r"
                         % (k, E.get(k), D.get(k)))
    # WHICH SOFTWARE, beside which silicon.  `roccmoon_md5` lives at the TOP level of a record
    # (it is a property of the tree the image was built from, not of the model).  Records that
    # predate the field carry None, and a None is recorded rather than refused -- but two
    # halves built from DIFFERENT runtime sources are not one configuration.
    rm_e, rm_d = enc_rec.get("roccmoon_md5"), dec_rec.get("roccmoon_md5")
    if rm_e and rm_d and rm_e != rm_d:
        raise Refuse("the two records were built from different roccmoon trees: %s vs %s"
                     % (rm_e, rm_d))
    # AND WHICH KERNELS.  The encoder and the decoder are DIFFERENT GRAPHS, so a shared op
    # resolving differently is legitimate and is NOT refused: the encoder's layernorm_s8 runs
    # 165x288 and wins on the lane, the decoder's runs 1x288 and does not.  What was missing
    # was any record at all of what each half selected -- so both manifests are recorded, and
    # every shared op that differs is named in the output and in `assumes`.
    KE, KD = manifest(E, "encoder"), manifest(D, "decoder")
    shared = {op: [KE["ops"][op], KD["ops"][op]] for op in sorted(set(KE["ops"]) & set(KD["ops"]))
              if KE["ops"][op] != KD["ops"][op]}

    steps, dec_img = decoder_steps(D)
    steps_steady = list(steps)
    steps_steady[0] -= dec_img          # the build is once per boot, not once per utterance
    if steps_steady[0] <= 0:
        raise Refuse("subtracting the image build empties decoder step 0")

    enc_iter, enc_cold = E["cycles_per_iteration"], E["cycles_cold"]
    dec_iter = take(steps_steady, a.mean_steps)
    dec_cold = take(steps, a.mean_steps)

    def rtf(c):
        return c / (clk * win)

    rec = {
        "what": "RTF_e2e on silicon, composed from two board records",
        "composed_not_measured": True,
        "labels": {
            "model": "Moonshine Tiny; encoder %s (%s), decoder %s (%s)"
                     % (E.get("candidate"), os.path.basename(os.path.dirname(a.enc)),
                        D.get("candidate"), os.path.basename(os.path.dirname(a.dec))),
            "clock_hz": clk, "window_s": win,
            "eval_set": "timing on the baked calibration window; the mean token count is "
                        + a.mean_steps_source,
            "cold_or_steady": "both, reported separately and never added",
            "stage": "generated C, backend roccmoon, curated MBP kernels; SoC %s bitstream %s"
                     % (E.get("soc_magic"), E.get("bitstream_md5")),
            "scope": "per-token path fully int8 on the board. THE CROSS-ATTENTION PROLOGUE IS "
                     "NOT IN THIS NUMBER: it is float, computed once per utterance off-board, "
                     "and is not in either image. This is therefore an encoder+decoder figure, "
                     "not a whole-pipeline one.",
        },
        "encoder": {"record": os.path.abspath(a.enc),
                    "accounting": E["cycles_accounting"]["definition"],
                    "cycles_per_iteration": enc_iter, "rtf_per_iteration": rtf(enc_iter),
                    "cycles_cold": enc_cold, "rtf_cold": rtf(enc_cold),
                    "image_cycles_once": E.get("image_cycles_once")},
        "decoder": {"record": os.path.abspath(a.dec),
                    "accounting": D["cycles_accounting"]["definition"],
                    "steps_unrolled": len(steps), "mean_steps": a.mean_steps,
                    "image_cycles_once": dec_img,
                    "step_cycles_incl_image": steps,
                    "step_cycles_steady": steps_steady,
                    "cycles_per_iteration": dec_iter, "rtf_per_iteration": rtf(dec_iter),
                    "cycles_cold": dec_cold, "rtf_cold": rtf(dec_cold)},
        "provenance": {
            "soc_magic": E.get("soc_magic"), "bitstream_md5": E.get("bitstream_md5"),
            "roccmoon_md5": rm_e if rm_e == rm_d else {"encoder": rm_e, "decoder": rm_d},
            "board": {"encoder": enc_rec.get("board"), "decoder": dec_rec.get("board")},
            "kernel_digest": {"encoder": KE["digest"], "decoder": KD["digest"]},
            "kernel_manifest": {"encoder": KE["ops"], "decoder": KD["ops"]},
            "shared_ops_resolving_differently": shared,
        },
        "rtf_e2e_per_iteration": rtf(enc_iter) + rtf(dec_iter),
        "rtf_e2e_cold": rtf(enc_cold) + rtf(dec_cold),
        "assumes": [
            "the two halves were measured in separate board runs and are ADDED; the harness "
            "runs one model per image, so they cannot be run as one without a multi-model "
            "build. Nothing here measures the transition between them.",
            "the decoder's per-token cost is independent of the encoder having just run. In a "
            "real pipeline the decoder would start with the encoder's working set in cache, "
            "not its own -- so this composition is, if anything, optimistic about the decoder "
            "and pessimistic about nothing.",
            "the mean token count is %s; it was measured for candidate R's decoder, not for "
            "the exact decoder graph priced here." % a.mean_steps_source,
            "the weight image build is charged once per BOOT, not once per utterance: the "
            "per-iteration figures subtract it (decoder step 0 carries all of it) and the cold "
            "figures keep it. A deployment that re-images per utterance pays the cold number.",
            "the cross-attention prologue (float, off-board) is not counted at all.",
            "the two halves ran the kernel sets recorded under provenance.kernel_manifest. "
            "They are different graphs, so a shared op may legitimately resolve differently "
            "-- but a half whose kernel set is not the one the configuration intended prices "
            "the wrong thing, and nothing outside that record says which was intended. "
            "Compare two arms of ONE half with fpga/pynq-z2/scripts/kernel_manifest.py.",
        ],
    }

    L = ["RTF_e2e -- COMPOSED from two board records, not measured as one run", ""]
    L.append("  encoder  %-18s per-iteration %12d = RTF %6.3f   cold %12d = RTF %6.3f"
             % (rec["encoder"]["accounting"], enc_iter, rtf(enc_iter), enc_cold, rtf(enc_cold)))
    L.append("  decoder  %-18s per-iteration %12.0f = RTF %6.3f   cold %12.0f = RTF %6.3f"
             % (rec["decoder"]["accounting"], dec_iter, rtf(dec_iter), dec_cold, rtf(dec_cold)))
    L.append("           (%.3f of %d unrolled steps; image build %d removed from step 0)"
             % (a.mean_steps, len(steps), dec_img))
    L.append("")
    L.append("  kernels  encoder digest %s (%d ops), decoder digest %s (%d ops)"
             % (KE["digest"], KE["n_ops"], KD["digest"], KD["n_ops"]))
    if shared:
        L.append("           shared ops resolving differently: %s"
                 % "; ".join("%s %s/%s" % (op, v[0], v[1]) for op, v in shared.items()))
    L.append("")
    L.append("  RTF_e2e  per-iteration %.3f      cold %.3f"
             % (rec["rtf_e2e_per_iteration"], rec["rtf_e2e_cold"]))
    L.append("")
    L.append("  goal RTF_e2e < 1.0 -> %s (per-iteration is %.1fx over)"
             % ("MET" if rec["rtf_e2e_per_iteration"] < 1.0 else "NOT MET",
                rec["rtf_e2e_per_iteration"]))
    print("\n".join(L))
    print("\n  assumes:")
    for s in rec["assumes"]:
        print("   - " + s)
    json.dump(rec, open(a.json, "w"), indent=1)
    print("\nwrote %s" % a.json)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Refuse as e:
        print("REFUSED: %s" % e, file=sys.stderr)
        sys.exit(2)
