#!/usr/bin/env bash
# B86 -- the attention staging rewrite: byte-for-byte equivalence, the poison arms, and the
# instruction account.  Host only: no board, no bitstream, no lock.
#
# WHAT IT GATES.  `mbxa_build_q` and `mbxa_build_w` are the s2.2 contract, and MBP_B86
# restructures both.  This is a RESTRUCTURING, NOT AN ARITHMETIC CHANGE -- no golden is
# rebuilt, the comparison is the SHIPPED builders' own output against the B86 builders'
# output, byte for byte, over every image word including the padding the array reads.
# The two arms are EXTRACTED FROM THE SHIPPED KERNEL AT GATE TIME (lines 87..367 of
# roccmoon_attention_s8_roccmoon_lane.c, between its own section markers), not copied, so
# the gate cannot go stale against the file it is gating.
#
# THREE POISON ARMS, one per new route, each of which the gate must REJECT:
#   1 the q run copy   2 the k run copy   3 the v^T 4-plane gather
# A copy has no arithmetic to absorb a perturbation, so a flipped bit in a staged byte is
# the only poison that can work -- and it must show up in the image.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
# shellcheck disable=SC1091
source "$root/env.sh" >/dev/null 2>&1 || true
KSRC="$root/fpga/pynq-z2/modelblaster/kernels/roccmoon/roccmoon_attention_s8_roccmoon_lane.c"
w="${B86_ATTN_OUT:-$(mktemp -d)}"; mkdir -p "$w"

# ---- extract the builders region from the shipped kernel, mechanically -------------------
python3 - "$KSRC" "$w/builders.inc" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read().split("\n")
beg = next(i for i, l in enumerate(src) if l.startswith("/* ---- the two image builders"))
end = next(i for i, l in enumerate(src) if i > beg and l.startswith("/* ---- the softmax term"))
body = "\n".join(src[beg:end])
assert "mbxa_build_q" in body and "mbxa_build_w" in body, "extraction missed a builder"
assert "MBP_B86" in body, "extraction missed the gate"
open(sys.argv[2], "w").write("#include <stdint.h>\n#include <stddef.h>\n\n" + body + "\n")
print("extracted lines %d..%d of the shipped kernel" % (beg + 1, end))
PYEOF

# ---- the gate: shipped vs B86, byte for byte, over a shape sweep -------------------------
cat > "$w/gate.c" <<'CEOF'
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define mbxa_build_q  bq_ship
#define mbxa_build_w  bw_ship
#define mbxa_width    wd_ship
#define mbxa_run      rn_ship
#define mbxa_zrun     zr_ship
#define mbxa_u32      u32_ship
#define mbxa_u64      u64_ship
#define MBP_B86 0
#include "builders.inc"
#undef mbxa_build_q
#undef mbxa_build_w
#undef mbxa_width
#undef mbxa_run
#undef mbxa_zrun
#undef mbxa_u32
#undef mbxa_u64
#undef MBP_B86

#define mbxa_build_q  bq_b86
#define mbxa_build_w  bw_b86
#define mbxa_width    wd_b86
#define mbxa_run      rn_b86
#define mbxa_zrun     zr_b86
#define mbxa_u32      u32_b86
#define mbxa_u64      u64_b86
#define MBP_B86 1
#include "builders.inc"

static int8_t q[200 * 64] __attribute__((aligned(64)));
static int8_t k[1100 * 64] __attribute__((aligned(64)));
static int8_t v[1100 * 64] __attribute__((aligned(64)));
static int8_t qa[1024 * 8] __attribute__((aligned(64))), qb[1024 * 8] __attribute__((aligned(64)));
static int8_t wa[4 * 512 * 8] __attribute__((aligned(64))), wb[4 * 512 * 8] __attribute__((aligned(64)));

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }

int main(void)
{
	/* The encoder's own shape first (T=165, D=36, N=165 -- the 48 lane commands), then the
	 * decoder's and a sweep that exercises the ranged paths: D not a multiple of 4, N past
	 * gp*8, a column group straddling D, and the degenerate N=1. */
	int shapes[][3] = {
		{165, 36, 165}, {165, 36, 64}, {64, 16, 64}, {33, 24, 97},
		{165, 36, 1}, {8, 16, 8}, {165, 35, 165}, {17, 6, 23},
		{165, 36, 120}, {40, 33, 40}, {12, 9, 200}, {165, 36, 33},
	};
	long cases = 0, bytes = 0, bad = 0;
	unsigned s;

	for (s = 0; s < sizeof shapes / sizeof *shapes; s++) {
		int T = shapes[s][0], D = shapes[s][1], N = shapes[s][2];
		int gs = (D + 7) / 8, qs = (N + 3) / 4, gp = (N + 7) / 8, qp = (D + 3) / 4;
		int lgpw = 9, kbase = 0, vtbase = qs * (gs + 1);
		int i;

		if (vtbase + qp * (gp + 1) > (1 << lgpw)) { printf("  skip %dx%dx%d\n", T, D, N); continue; }
		for (i = 0; i < T * D; i++) q[i] = (int8_t)(rnd() & 0xff);
		for (i = 0; i < N * D; i++) k[i] = (int8_t)(rnd() & 0xff);
		for (i = 0; i < N * D; i++) v[i] = (int8_t)(rnd() & 0xff);
		memset(qa, 0xAA, sizeof qa); memset(qb, 0xAA, sizeof qb);
		memset(wa, 0xAA, sizeof wa); memset(wb, 0xAA, sizeof wb);

		bq_ship(q, T, D, gs, qa);
		bq_b86 (q, T, D, gs, qb);
		bw_ship(k, v, N, D, gs, qs, gp, qp, lgpw, kbase, vtbase, wa);
		bw_b86 (k, v, N, D, gs, qs, gp, qp, lgpw, kbase, vtbase, wb);

		for (i = 0; i < T * gs * 8; i++) { bytes++; if (qa[i] != qb[i]) bad++; }
		for (i = 0; i < 4 * (1 << lgpw) * 8; i++) { bytes++; if (wa[i] != wb[i]) bad++; }
		cases++;
	}
	printf("MB_B86_ATTN_GATE shapes=%ld bytes=%ld mismatches=%ld %s\n",
	       cases, bytes, bad, bad ? "FAIL" : "PASS");
	return bad ? 1 : 0;
}
CEOF

cc -O2 -I"$w" -o "$w/gate" "$w/gate.c"
echo "--- equivalence ---"
"$w/gate"

echo "--- poison arms (each MUST be rejected) ---"
rc_all=0
for p in 1 2 3; do
  cc -O2 -I"$w" -DMBP_B86_POISON=$p -o "$w/gate_p$p" "$w/gate.c" 2>/dev/null
  if "$w/gate_p$p" >"$w/p$p.txt" 2>&1; then
    echo "  poison $p: NOT REJECTED  <<< GATE IS BLIND"; rc_all=1
  else
    echo "  poison $p: rejected      ($(grep -o 'mismatches=[0-9]*' "$w/p$p.txt"))"
  fi
done

# ---- the instruction account, on spike, at the ENCODER's own head shape ------------------
CROSS="${CROSS_COMPILE:-riscv64-zephyr-elf-}"
command -v "${CROSS}gcc" >/dev/null 2>&1 || \
  CROSS="$root/zephyr-chipyard-sw/tools-manual/zephyr-sdk-1.0.0-beta1/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-"
SPIKE="${TACIT_SPIKE:-$root/third_party/riscv-isa-sim/build/spike}"
IC="$root/fpga/pynq-z2/modelblaster/check/icount"
SHIM="$root/fpga/pynq-z2/modelblaster/check/shim"
SW="$root/fpga/pynq-z2/sw"
if [ -x "$SPIKE" ] && [ -f "$here/b86_attn_icount_main.c" ]; then
  echo "--- instruction account (spike, M=165 Dk=Dv=36 S=165, one head) ---"
  "${CROSS}gcc" -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding \
    -fno-builtin-printf -Wall -ffunction-sections -fdata-sections -falign-loops=4 \
    -I"$SW" -I"$SHIM" -I"$w" -DMB_PEXT_HW=1 -c "$here/b86_attn_icount_main.c" -o "$w/ic.o"
  "${CROSS}gcc" -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding \
    -I"$SW" -I"$SHIM" "$IC/crt.S" "$IC/htif.c" "$w/ic.o" -nostdlib -nostartfiles \
    -Wl,--no-relax -Wl,--gc-sections -static -T "$IC/link.ld" -o "$w/ic.elf" -lgcc
  "$SPIKE" "$w/ic.elf" 2>&1 | grep MB_B86_ATTN || true
fi

# ---- INERTNESS: with MBP_B86 unset the builders must be opcode-identical to git HEAD -------
# READ THIS BEFORE TRUSTING THE LINE IT PRINTS.  Against a HEAD that PREDATES B86 this is a
# real proof that the define ships inert -- that is how it was run and recorded (B86_ATTN_BAND
# s2: opcode-identical, 181 instructions, both builders forced emitted).  Once B86 is
# COMMITTED, HEAD contains the gate too and this degrades to a working-tree-vs-HEAD
# comparison, i.e. a drift check rather than an inertness proof.  Both are worth running; only
# the first is evidence that MBP_B86=0 is the shipped text.  To redo the real one, point at the
# commit before B86 landed:  B86_INERT_REF=<sha> b86_attn_gate.sh
INERT_REF="${B86_INERT_REF:-HEAD}"
echo "--- inertness (MBP_B86 unset vs $INERT_REF$([ "$INERT_REF" = HEAD ] && echo "  -- drift check; see the note above"))  ---"
git -C "$root" show "$INERT_REF:fpga/pynq-z2/modelblaster/kernels/roccmoon/roccmoon_attention_s8_roccmoon_lane.c" \
  > "$w/head.c" 2>/dev/null || { echo "  (no HEAD copy; skipped)"; echo "workdir: $w"; exit $rc_all; }
python3 - "$w/head.c" "$w/head_builders.c" <<'PYEOF'
import sys
src = open(sys.argv[1]).read().split("\n")
beg = next(i for i, l in enumerate(src) if l.startswith("/* ---- the two image builders"))
end = next(i for i, l in enumerate(src) if i > beg and l.startswith("/* ---- the softmax term"))
open(sys.argv[2], "w").write("#include <stdint.h>\n#include <stddef.h>\n\n" + "\n".join(src[beg:end]) + "\n")
PYEOF
for n in head builders; do
  src="$w/${n}_builders.c"; [ "$n" = builders ] && src="$w/builders.inc"
  cp "$src" "$w/${n}_drv.c"
  cat >> "$w/${n}_drv.c" <<'EOF'
/* A static unused function is discarded, which would make the comparison vacuous. */
void b86_drv_q(const int8_t *q,int T,int D,int gs,int8_t *i){ mbxa_build_q(q,T,D,gs,i); }
void b86_drv_w(const int8_t *k,const int8_t *v,int N,int D,int gs,int qs,int gp,int qp,
               int l,int kb,int vt,int8_t *i){ mbxa_build_w(k,v,N,D,gs,qs,gp,qp,l,kb,vt,i); }
EOF
  "${CROSS}gcc" -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding \
    -ffunction-sections -fdata-sections -falign-loops=4 -DMB_PEXT_HW=1 \
    -c "$w/${n}_drv.c" -o "$w/${n}d.o" 2>/dev/null
  "${CROSS}objdump" -d "$w/${n}d.o" | tail -n +3 | sed 's/^ *[0-9a-f]*://' \
    | sed 's/\t[0-9a-f ]*\t/\t/' > "$w/${n}d.dis"
done
n_head=$(grep -c $'\t' "$w/headd.dis" || true)
if diff -q "$w/headd.dis" "$w/buildersd.dis" >/dev/null; then
  echo "  PASS - opcode-identical, $n_head instructions emitted in each"
else
  echo "  FAIL - MBP_B86 is NOT inert when unset:"; diff "$w/headd.dis" "$w/buildersd.dis" | head -20
  rc_all=1
fi

echo "workdir: $w"
exit $rc_all
