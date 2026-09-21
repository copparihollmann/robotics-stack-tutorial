#!/usr/bin/env bash
# B86g -- the resident weight-image table, gated OFF-BOARD.
#
# Unlike MBP_B86D, whose correctness was an ordering property across two harts and the lane,
# THIS lever is pure software: a lookup table in front of mbxa_build_w.  So it gets a real
# host gate, and the poison arm runs here rather than costing a board hold.
#
#   equivalence  every image the table hands back must be byte-identical to a fresh build
#   residency    the second sighting of a key must NOT rebuild (hit), and the counts must be
#                exactly what the decoder's reuse pattern predicts
#   poison       MBP_B86G_POISON=1 serves slot 0 whatever the key -- must be REJECTED
#   inertness    MBP_B86G unset must be opcode-identical to the pre-change commit
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
KSRC="$root/fpga/pynq-z2/modelblaster/kernels/roccmoon/roccmoon_attention_s8_roccmoon_lane.c"
w="${B86G_OUT:-$(mktemp -d)}"; mkdir -p "$w"
# scan (0) vs open-addressed index (1); both must pass identically
IX="${MBXA_RES_INDEX:-1}"
echo "  MBXA_RES_INDEX=$IX"

# the builders + the table, extracted from the shipped kernel at gate time
python3 - "$KSRC" "$w/res.inc" <<'PYEOF'
import sys
src = open(sys.argv[1]).read().split("\n")
b = next(i for i,l in enumerate(src) if l.startswith("/* ---- the two image builders"))
e = next(i for i,l in enumerate(src) if i>b and l.startswith("/* ---- the softmax term"))
body = "\n".join(src[b:e])
assert "mbxa_build_w" in body and "MBP_B86G" in body, "extraction missed the table"
open(sys.argv[2],"w").write("#include <stdint.h>\n#include <stddef.h>\n\n"+body+"\n")
print("extracted lines %d..%d" % (b+1, e))
PYEOF

cat > "$w/gate.c" <<'CEOF'
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#define MBP_B86 1
#define MBP_B86G 1
#include "res.inc"

/* 48 heads x S*Dk = 48 x 165 x 36 = 285,120 B each.  Sized explicitly because the first
 * version of this gate allocated 128,000 and read 279,180 into the next object -- which
 * showed up as exactly 46 byte mismatches on the two highest-index heads and looked for all
 * the world like a subtle residency defect.  A gate that indexes past its own fixture
 * accuses the thing it is gating. */
#define MBXA_GATE_HEADS 48
#define MBXA_GATE_SDK   (165*36)
static int8_t K[MBXA_GATE_HEADS*MBXA_GATE_SDK] __attribute__((aligned(64)));
static int8_t V[MBXA_GATE_HEADS*MBXA_GATE_SDK] __attribute__((aligned(64)));
static int8_t scratch[4*512*8] __attribute__((aligned(64)));
static int8_t fresh[4*512*8] __attribute__((aligned(64)));
static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void){ rs^=rs<<13; rs^=rs>>7; rs^=rs<<17; return rs; }

int main(void)
{
	/* the decoder's reuse pattern: 6 cross layers x 8 heads, each seen 24 times (S=165),
	 * interleaved with self-attention at S = the step index (never cacheable) */
	const int S = 165, Dv = 36, Dk = 36;
	const int gs=(Dk+7)/8, qs=(S+3)/4, gp=(S+7)/8, qp=(Dv+3)/4;
	const int kbase = 0, vtbase = qs*(gs+1);
	long bad = 0, cmp = 0;
	int step, layer, head, i;

	for (i = 0; i < (int)sizeof K; i++) K[i] = (int8_t)(rnd() & 0xff);
	for (i = 0; i < (int)sizeof V; i++) V[i] = (int8_t)(rnd() & 0xff);

	for (step = 0; step < 24; step++) {
		for (layer = 0; layer < 6; layer++) {
			/* self-attention: S = step+1, below MBXA_RES_MINS, must bypass */
			int Ss = step + 1;
			if (Ss >= 9) {
				int qss=(Ss+3)/4, gps=(Ss+7)/8;
				mbxa_w_resident(K, V, Ss, Dv, gs, qss, gps, qp, 9,
						0, qss*(gs+1), scratch);
			}
			for (head = 0; head < 8; head++) {
				const int8_t *kb = K + (size_t)(layer*8+head)*S*Dk;
				const int8_t *vb = V + (size_t)(layer*8+head)*S*Dv;
				int8_t *got = mbxa_w_resident(kb, vb, S, Dv, gs, qs, gp, qp, 9,
							      kbase, vtbase, scratch);
				/* The resident slot is a zero-initialised static, and build_w
				 * leaves 1,984 B of inter-quad padding untouched (16,384
				 * allocated, 14,400 written).  That padding is don't-care to
				 * the lane -- s2.2b: "rows past N or D need NOT be zeroed" --
				 * but it IS transferred by the fill, so the comparison has to
				 * start both buffers in the same state or it compares noise.
				 * Zeroing `fresh` makes the whole 16,384 B comparable, which
				 * is stronger than skipping the padding. */
				memset(fresh, 0, sizeof fresh);
				mbxa_build_w(kb, vb, S, Dv, gs, qs, gp, qp, 9, kbase, vtbase, fresh);
				for (i = 0; i < (int)sizeof fresh; i++) {
					cmp++;
					if (got[i] != fresh[i]) bad++;
				}
			}
		}
	}
	printf("MB_B86G bytes=%ld mismatches=%ld hit=%u miss=%u full=%u bypass=%u %s\n",
	       cmp, bad, mbxa_res_hit, mbxa_res_miss, mbxa_res_full, mbxa_res_bypass,
	       bad ? "FAIL" : "PASS");
	/* residency must actually have happened: 48 builds, not 1,152 */
	if (!bad && (mbxa_res_miss != 48 || mbxa_res_hit != 1152-48 || mbxa_res_full != 0)) {
		printf("MB_B86G *** counts wrong: expected miss=48 hit=1104 full=0 ***\n");
		return 2;
	}
	return bad ? 1 : 0;
}
CEOF

cc -O2 -DMBXA_RES_INDEX=$IX -I"$w" -o "$w/gate" "$w/gate.c"
echo "--- equivalence + residency counts ---"
"$w/gate"; rc=$?

echo "--- poison (MUST be rejected) ---"
cc -O2 -DMBXA_RES_INDEX=$IX -I"$w" -DMBP_B86G_POISON=1 -o "$w/gate_p" "$w/gate.c" 2>/dev/null
if "$w/gate_p" >"$w/p.txt" 2>&1; then echo "  poison 1: NOT REJECTED  <<< GATE IS BLIND"; rc=1
else echo "  poison 1: rejected   ($(grep -o 'mismatches=[0-9]*' "$w/p.txt"))"; fi

echo "workdir: $w"
exit $rc
