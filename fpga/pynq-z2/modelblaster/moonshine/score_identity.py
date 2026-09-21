#!/usr/bin/env python3
"""Score an identity-dispatch run -- board console, bench log or run.json -- against the four-part
signature ROCC_DECOUPLED.md 8.15.9 sets as the bar for reproducing the 0x5A5A0013 fault.

    python3 score_identity.py out/<run>/console.txt

The bands are the two boards' measurements, not a model: exact at G+1 = 37, 70-90 % wrong at
G+1 = 5 and 2, plane 3 at 96-100 % of its own output and plane 0 at 43-58 %, byte-in-word uniform.
A bench that reproduces the COUNT without the per-plane ordering is reproducing a different bug."""
import json, re, sys
BAND = {288: (0, 830, 0), 32: (461, 9216, 4608), 8: (115, 2304, 1152)}   # lo, hi, point
TOT = {288: 82944, 32: 9216, 8: 2304}
txt = open(sys.argv[1], errors="replace").read()
h = re.findall(r"RMB_ID_HARNESS K=(\d+) N=(\d+) G=(\d+) Q=(\d+) lgpw=(\d+) tiles=(\d+) ref_vs_weights_bad=(\d+)", txt)
print("harness (must be 0 before anything below is interpreted):")
for k, n, g, q, lg, ti, bad in h:
    print("  K=%-4s N=%-4s G=%-3s Q=%-3s lgpw=%-2s tiles=%-2s ref_vs_weights_bad=%s%s"
          % (k, n, g, q, lg, ti, bad, "" if bad == "0" else "   <-- HARNESS FAILED"))
rows = re.findall(r"RMB_ID K=(\d+) N=(\d+) rc=(-?\d+) bad=(\d+) of (\d+)\s+plane=([\d,]+)\s+byte=([\d,]+)\s+tile0_7=([\d,]+)", txt)
print("\nresult:")
for k, n, rc, bad, tot, pl, by, ti in rows:
    k, bad, tot = int(k), int(bad), int(tot)
    lo, hi, pt = BAND.get(k, (0, tot, 0))
    verdict = "IN BAND" if lo <= bad <= hi else ("BELOW" if bad < lo else "ABOVE")
    planes = [int(x) for x in pl.split(",")]
    top = max(planes) / bad * 100 if bad else 0.0
    print("  K=%-4d N=%-4s rc=%-3s bad=%6d of %6d (%6.2f %%)  predicted %d-%d (point %d) -> %s"
          % (k, n, rc, bad, tot, 100.0 * bad / tot, lo, hi, pt, verdict))
    print("      planes %s  (largest plane holds %.1f %% of the wrong bytes; >60 %% predicted for a bank collision)"
          % (pl, top))
    print("      byte-in-word %s" % by)
    print("      tiles 0..7   %s" % ti)
badr = re.findall(r"RMB_ID_BAD K=(\d+) m=(\d+) n=(\d+) exp=(-?\d+) got=(-?\d+) plane=(\d+) tile=(\d+) quad=(\d+) word=(\d+) bank=(\d+) byte=(\d+) from_n=(\d+) from_k=(\d+)", txt)
if badr:
    print("\nfirst wrong bytes (exp/got, and where the got byte came from):")
    for r in badr[:12]:
        print("  K=%s m=%s n=%s exp=%s got=%s  plane=%s tile=%s quad=%s word=%s bank=%s byte=%s  got came from n%%16=%s k%%8=%s"
              % r)
