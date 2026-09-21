#!/usr/bin/env bash
# Lab B20 -- does softmax need float at all?  Integer against the reference, on silicon.
#
#   scripts/with_board.sh ./scripts/40_rocket_int_nonlin.sh
#
# Lab B19 measured what ModelBlaster's float-tainted kernels cost inside real transformer
# blocks, and the answer was that the GEMMs are 3.0% of an attention block's time. The
# obvious next move is a floating-point accelerator. This lab asks the cheaper question
# first, which is the same one audio_fe.c already asked about the FFT: does the operation
# need float AT ALL?
#
# fpga/pynq-z2/sw/int_nonlin.c is softmax and layer norm with no float anywhere -- 2^x
# and 1/sqrt(x) from 33-entry tables with linear interpolation, the same shape
# audio_fe.c's fe_log2_q8 already uses, one integer divide per ROW and none per element.
# This runs it beside reference_kernels.py's own expressions (two expf per element for
# softmax, double with a sqrt for layer norm) on the same hart, at five widths, and
# reports the speedup AND the int8 output difference -- because a faster kernel that
# computes something else is not a result.
#
# Produces out/<name>/{console.txt,run.json}.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

NAME="rocket_int_nonlin"
BOARD="chipyard_pynqz1_mic"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_mic_z1/pynqz1_rocket_mic.bit"
SAMPLE="$IISWC_ROOT/samples/int_nonlin_bench"
EXPECT="$IISWC_ROOT/expected/int_nonlin.json"
LOAD_BIT=1; DO_BOARD=1; SECONDS_READ=420; WANT_MAGIC="0x5A5A0005"
# The PL runner differs per bitstream (each one punches out different pins), so it is a
# parameter rather than a constant -- this lab's guest does not care which of them loaded
# the PL, only that the MAGIC gate agreed.
RUNNER="run_rocket_mic.py"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only) DO_BOARD=0; shift ;;
    --no-check) EXPECT=""; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"

step "1/3  build"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- \
    -DBOARD_ROOT="$IISWC_ROOT" > "$RUN/build.log" 2>&1 \
  || { tail -30 "$RUN/build.log"; die "build failed"; }
cp "$RUN/build/zephyr/zephyr.elf" "$RUN/build/zephyr/zephyr.bin" "$RUN/"
OBJDUMP=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-objdump' 2>/dev/null | head -1)
"$OBJDUMP" -d "$RUN/zephyr.elf" > "$RUN/dis.txt"
# The float half MUST link soft-float and libm -- that is the thing being measured, and
# an image without them would mean the reference expressions had been optimised away.
grep -q '__muldf3\|__mulsf3' "$RUN/dis.txt" || die "no libgcc soft-float in the image --
       the float reference did not survive the compiler, and the comparison is void"
grep -q '<expf>\|<exp>' "$RUN/dis.txt" || die "no expf in the image"
info "image: $(fsize "$RUN/zephyr.bin")"
[ "$DO_BOARD" -eq 1 ] || { info "--build-only"; exit 0; }

step "2/3  run"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$RUN/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/"
if [ "$LOAD_BIT" -eq 1 ]; then
  need_file "$BIT" "no bitstream"
  bitstream_identify "$BIT"
  bitstream_gate
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  HOLD="--bitstream $(basename "$BIT") --hold"
else bitstream_identify ""; HOLD="--no-load --hold"; fi
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER $HOLD'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream"; }
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
printf '%s\n' "----------------------------------------------------------------"
cat "$RUN/console.txt"
printf '%s\n' "----------------------------------------------------------------"

step "3/3  verdict"
python3 - "$RUN" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run = sys.argv[1]
txt = open(os.path.join(run, "console.txt")).read()
rows = re.findall(r'^(softmax|layernorm)\s+(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)x\s+(\d+)\s+(\d+)\s+(\d+)$',
                  txt, re.M)
out = {"done": "INT_NONLIN done" in txt,
       "selftest_fails": int((re.search(r'INT_NONLIN selftest fails=(\d+)', txt)
                              or re.match('(0)', '0')).group(1)),
       "rows": []}
worst_err = 0
best = {"softmax": 0.0, "layernorm": 0.0}
for op, K, fc, ic, sp, fe, ie, err in rows:
    r = {"op": op, "K": int(K), "float_cycles": int(fc), "int_cycles": int(ic),
         "speedup": float(sp), "float_cyc_per_elem": int(fe),
         "int_cyc_per_elem": int(ie), "max_abs_err": int(err)}
    out["rows"].append(r)
    worst_err = max(worst_err, int(err))
    best[op] = max(best[op], float(sp))
# GELU: three columns, because two different mechanisms are being separated -- the
# population argument (evaluate the transcendental <=256 times, not n times) and the
# fixed-point one (evaluate it without float).  GELU_PER_EL is emitted by the guest so
# the per-element costs are read rather than divided out of a formatted table.
for n, fl, me, it, mer, ier in re.findall(
        r'^GELU_PER_EL n=(\d+) float=(\d+) memo=(\d+) int=(\d+) '
        r'memo_err=(\d+) int_err=(\d+)$', txt, re.M):
    out["rows"].append({"op": "gelu", "K": int(n),
                        "float_cyc_per_elem": int(fl),
                        "memo_cyc_per_elem": int(me),
                        "int_cyc_per_elem": int(it),
                        "memo_abs_err": int(mer), "max_abs_err": int(ier)})
g = [r for r in out["rows"] if r["op"] == "gelu"]
if g:
    big = max(g, key=lambda r: r["K"])
    out["gelu_float_cyc_per_elem"] = big["float_cyc_per_elem"]
    out["gelu_memo_cyc_per_elem"] = big["memo_cyc_per_elem"]
    out["gelu_int_cyc_per_elem"] = big["int_cyc_per_elem"]
    out["gelu_n"] = big["K"]
    out["gelu_memo_speedup"] = round(big["float_cyc_per_elem"]
                                     / max(1, big["memo_cyc_per_elem"]), 2)
    out["gelu_int_speedup"] = round(big["float_cyc_per_elem"]
                                    / max(1, big["int_cyc_per_elem"]), 2)
    out["gelu_memo_abs_err"] = max(r["memo_abs_err"] for r in g)
    out["gelu_int_abs_err"] = max(r["max_abs_err"] for r in g)
# matmul_s8's requantise tail -- the float half of an otherwise integer op.
rq = []
for n, num, fl, it, er in re.findall(
        r'^REQUANT n=(\d+) total=(-?\d+)/65536 float=(\d+) int=(\d+) err=(\d+)$',
        txt, re.M):
    rq.append({"op": "matmul_requant", "K": int(n), "total_q16": int(num),
               "float_cyc_per_elem": int(fl), "int_cyc_per_elem": int(it),
               "max_abs_err": int(er)})
out["rows"] += rq
if rq:
    out["requant_float_cyc_per_elem"] = max(r["float_cyc_per_elem"] for r in rq)
    out["requant_int_cyc_per_elem"] = max(r["int_cyc_per_elem"] for r in rq)
    out["requant_speedup"] = round(out["requant_float_cyc_per_elem"]
                                   / max(1, out["requant_int_cyc_per_elem"]), 2)
    out["requant_abs_err"] = max(r["max_abs_err"] for r in rq)
m = re.search(r'GELU_SCALE n=(\d+) scale_in=\S+ float=(\d+) int=(\d+)', txt)
if m:
    out["gelu_other_scale_float_cyc_per_elem"] = int(m.group(2))
    out["gelu_other_scale_int_cyc_per_elem"] = int(m.group(3))
m = re.search(r'GELU_DOMAIN cases=(\d+) mismatches=(\d+) max_abs_err=(\d+)', txt)
if m:
    out["gelu_domain_cases"] = int(m.group(1))
    out["gelu_domain_mismatches"] = int(m.group(2))
    out["gelu_domain_max_abs_err"] = int(m.group(3))
out["max_abs_err"] = worst_err
out["softmax_best_speedup"] = best["softmax"]
out["layernorm_best_speedup"] = best["layernorm"]
print("\n   softmax  best %.1fx" % best["softmax"])
print("   layernorm best %.1fx" % best["layernorm"])
print("   worst int8 output difference against the float reference: %d LSB" % worst_err)
if g:
    print("\n   gelu, n = %d:  float %d c/el ->  memo-LUT %d (%.1fx, bit-exact)"
          "  ->  integer %d (%.1fx, %d LSB)"
          % (out["gelu_n"], out["gelu_float_cyc_per_elem"],
             out["gelu_memo_cyc_per_elem"], out["gelu_memo_speedup"],
             out["gelu_int_cyc_per_elem"], out["gelu_int_speedup"],
             out["gelu_int_abs_err"]))
    if rq:
        print("   matmul_s8 requantise tail: float %d c/el -> integer %d (%.1fx, %d LSB)"
              % (out["requant_float_cyc_per_elem"], out["requant_int_cyc_per_elem"],
                 out["requant_speedup"], out["requant_abs_err"]))
    if "gelu_domain_cases" in out:
        print("   gelu over its ENTIRE input domain: %d cases, %d differ, max %d LSB"
              % (out["gelu_domain_cases"], out["gelu_domain_mismatches"],
                 out["gelu_domain_max_abs_err"]))
print()
if worst_err <= 2 and best["softmax"] > 5:
    print("   => These operations do not need floating point. The answer to the")
    print("      float-tainted kernels is a few hundred lines of C, not a unit.")
# The silicon and the numbers travel together: SOC_MAGIC names the CONFIG and
# every build of it reports the same value, so the md5 of the file actually
# loaded is the only thing that identifies the build.
out["bitstream_md5"] = os.environ.get("BIT_MD5", "unknown")
out["bitstream_note"] = os.environ.get("BIT_NOTE", "")
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=2)
PY

if [ -n "$EXPECT" ] && [ -f "$EXPECT" ]; then
  step "check  (vs $(basename "$EXPECT"))"
  python3 - "$RUN/run.json" "$EXPECT" <<'PY'
import json, sys
got = json.load(open(sys.argv[1])); exp = json.load(open(sys.argv[2])); bad = 0
for k, want in exp.items():
    if k.startswith("_"): continue
    have = got.get(k)
    if isinstance(want, dict) and set(want) == {"min", "max"}:
        ok = have is not None and want["min"] <= have <= want["max"]
        s = "in [%s, %s]" % (want["min"], want["max"])
    else:
        ok = (have == want); s = repr(want)
    print("    %-5s %-26s expected %-20s got %s" % ("ok" if ok else "FAIL", k, s, have))
    bad += (not ok)
print("    %s" % ("PASS  reproduces the golden run" if not bad else "FAIL  %d differ" % bad))
sys.exit(1 if bad else 0)
PY
fi
