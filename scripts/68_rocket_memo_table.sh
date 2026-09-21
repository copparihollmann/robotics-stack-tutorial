#!/usr/bin/env bash
# Lab B31 -- what a memo table costs at a DECODER's dispatch size (ROCC_DECOUPLED.md s8.15.16).
#
#   scripts/with_board.sh ./scripts/68_rocket_memo_table.sh
#   scripts/with_board.sh ./scripts/68_rocket_memo_table.sh --bit ... --magic ... --runner ...
#
# WHY.  Every per-element rate this programme composes a decoder with was measured on an ENCODER
# dispatch -- 172,332 elements for GELU, 217,800 for softmax -- and a decoder's are 48 and 1,152.
# A memo kernel costs a fill plus a per-element rate; at 172 k the fill is invisible and at 48 it is
# nearly all of it.  samples/memo_table_bench times both kernels at both ends on one silicon.
#
# THE CONTROL IS THE POINT: at the encoder's own dispatch sizes the bench must reproduce what Lab
# B26 measured through ModelBlaster, READ from that lab's committed record rather than compiled in
# here (--reference / B31_REFERENCE names it; the rate, its model and its n go into run.json).  If it does
# not, the bench is measuring something else and no small-n number from it may be used.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

NAME="rocket_memo_table"
BOARD="chipyard_pynqz1_micrgb"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonall_z1/pynqz1_rocket_micrgb_roccmoonall.bit"
RUNNER="run_rocket_roccmoonall.py"
SAMPLE="$IISWC_ROOT/samples/memo_table_bench"
WANT_MAGIC="0x5A5A0028"; FCLK_CORE=34.4828; SECONDS_READ=300
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    # the control's expected rates are READ from this record, never compiled in
    --reference) B31_REFERENCE="${2:?}"; shift 2 ;;
    # which operator groups the one ELF runs: gelu, softmax, residue (comma separated, default all)
    --ops) OPS="${2:?}"; shift 2 ;;
    --reference-model) B31_REFERENCE_MODEL="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    # NEVER HOLD THE BOARD ACROSS A BUILD.  Step 1 needs no board at all, so it can be done off
    # the lock and handed to the board run:
    #   ./scripts/68_rocket_memo_table.sh --build-only
    #   scripts/with_board.sh ./scripts/68_rocket_memo_table.sh --prebuilt out/rocket_memo_table_prebuilt
    --build-only) BUILD_ONLY=1; shift ;;
    --prebuilt) PREBUILT="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
# 0x5A5A0028: this lab runs no accelerator, but it must still not run on an unidentified build.
BIT_ACCEPTED="${BIT_ACCEPTED:-} 32d10e5d47a4ca1f120f6f6d34e04b4e"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"
[ -n "${BUILD_ONLY:-}" ] && RUN="$IISWC_OUT/${NAME}_prebuilt"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/3  build the guest ($BOARD)"
OPS="${OPS:-gelu,softmax,residue}"
OPS_CFLAGS=""
for g in gelu softmax residue; do
  case ",$OPS," in *",$g,"*) ;; *) OPS_CFLAGS="$OPS_CFLAGS -DMEMO_OPS_$(echo "$g" | tr a-z A-Z)=0" ;; esac
done
if [ -n "${PREBUILT:-}" ]; then
  # the image was built off the board lock by --build-only; the ops list is recorded there
  need_file "$PREBUILT/zephyr.bin" "no prebuilt image in $PREBUILT (run --build-only first)"
  cp "$PREBUILT/zephyr.bin" "$PREBUILT/zephyr.elf" "$RUN/"
  cp "$PREBUILT/build.log" "$RUN/build.log" 2>/dev/null || true
  [ -r "$PREBUILT/ops.txt" ] && OPS="$(cat "$PREBUILT/ops.txt")"
  info "prebuilt image from $PREBUILT (built off the board lock), ops=$OPS"
else
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- -DBOARD_ROOT="$IISWC_ROOT" \
    ${OPS_CFLAGS:+-DEXTRA_CPPFLAGS="$OPS_CFLAGS"} \
    > "$RUN/build.log" 2>&1 || { tail -20 "$RUN/build.log"; die "build failed"; }
  cp "$RUN/build/zephyr/zephyr.bin" "$RUN/build/zephyr/zephyr.elf" "$RUN/"
fi
info "image: $(fsize "$RUN/zephyr.bin")"
printf '%s\n' "$OPS" > "$RUN/ops.txt"
if [ -n "${BUILD_ONLY:-}" ]; then
  info "built, no board touched.  Now:  scripts/with_board.sh $0 --prebuilt $RUN"
  exit 0
fi

step "2/3  load the PL and run"
need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"; bitstream_gate
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$RUN/zephyr.bin" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream"; }
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE"; }
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ --idle 60 > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  t=5
  while [ \$t -lt $SECONDS_READ ] && ! grep -q MEMO_DONE console.out; do sleep 5; t=\$((t+5)); done
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  echo waited=\$t bytes=\$(wc -c < console.out)
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
[ -s "$RUN/console.txt" ] || { cat "$RUN/boot.log"; die "0 console bytes"; }
grep -q MEMO_DONE "$RUN/console.txt" || { tail -20 "$RUN/console.txt"; die "the bench did not finish"; }
grep -E "^MEMO_" "$RUN/console.txt" | sed 's/^/    /'

step "3/3  fill and per-element rate, fitted from the two ends"
export BIT_MD5 WANT_MAGIC IISWC_ROOT B31_REFERENCE B31_REFERENCE_MODEL OPS
python3 - "$RUN" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run = sys.argv[1]
IISWC_ROOT = os.environ["IISWC_ROOT"]
txt = open(os.path.join(run, "console.txt"), errors="replace").read()
CLK = 34482759.0
g = [{"n": int(n), "distinct": int(d), "cycles": int(c)} for n, d, c in
     re.findall(r"MEMO_GELU n=(\d+) distinct=(\d+) cycles=(\d+)", txt)]
s = [{"what": w, "M": int(M), "K": int(K), "n": int(n), "cycles": int(c)} for w, M, K, n, c in
     re.findall(r'MEMO_SMX2 what="([^"]*)" M=(\d+) K=(\d+) n=(\d+) cycles=(\d+)', txt)]
fill = re.search(r"MEMO_SMX2_FILL M=1 K=1 cycles=(\d+)", txt)
# the four residue operators, each at three sizes (ROCC_DECOUPLED.md 8.15.17)
ops = [{"op": o, "kernel": k, "M": int(M), "K": int(K), "n": int(n), "cycles": int(c),
        "reps": int(rp), "out_distinct": int(od), "out_sum": int(osum)}
       for o, k, M, K, n, c, rp, od, osum in re.findall(
           r"MEMO_OP op=(\w+) kernel=(\w+) M=(\d+) K=(\d+) n=(\d+) cycles=(\d+) "
           r"per_el=[\d.]+ reps=(\d+) out_distinct=(\d+) out_sum=(-?\d+)", txt)]
out = {"lab": "B31 memo_table", "bitstream_md5": os.environ.get("BIT_MD5"),
       "soc_magic": os.environ.get("WANT_MAGIC"),
       "fclk": json.load(open(os.path.join(run, "fclk.json"))),
       "gelu": g, "softmax_memo2": s, "residue_ops": ops,
       "ops_requested": os.environ.get("OPS"),
       "softmax_fill_cycles_measured": int(fill.group(1)) if fill else None}
for r in g + s + ops:
    r["cycles_per_element"] = r["cycles"] / r["n"]
# THE CONTROL: the encoder's own dispatch size must reproduce Lab B26's measured rates -- and the
# expected values are READ from Lab B26's committed record, not compiled in here.  A control that
# hard-codes the answer stops being a control the moment the reference is re-measured: it would
# then gate this run against a number nobody holds any more, and pass.  The record, the model it
# came from and the rate all go into run.json, so a reader can see what was compared with what.
# A LIST, because no single record has every kernel this bench runs: the q16 profile has
# gelu/softmax/rope/add measured with the curated kernels, and layernorm's pext_int_rsqrt rate
# exists only in the pext_nl encoder run.  Searched in order; the first record with a matching
# (kind, KERNEL) wins, and which one it was goes into run.json.
REF_LIST = [p for p in (os.environ.get("B31_REFERENCE") or "").split(",") if p] or [
    os.path.join(IISWC_ROOT, "fpga/pynq-z2/modelblaster/moonshine/board/b30_q16r_run.json"),
    os.path.join(IISWC_ROOT, "fpga/pynq-z2/modelblaster/moonshine/board/b28_enc_run.json")]
REF = REF_LIST[0]
REF_MODEL = os.environ.get("B31_REFERENCE_MODEL", "")


# THE KERNEL HAS TO MATCH, not just the kind.  A Lab B26 run holds several encoder images and
# "softmax_s8" names pext_int_row in one of them and pext_int_memo2 in another -- 214.1 c/el
# against 39.975, a 5.4x difference under one kind name.  Taking the first model that carries the
# kind would gate this bench against a kernel it does not run.  These are the kernels
# samples/memo_table_bench compiles; a reference that has no model running them is an error, not
# a fallback.
WANT_KERNEL = {"gelu_s8": "pext_int_lut", "softmax_s8": "pext_int_memo2"}


def b26_rate_any(kind, kernel):
    """the same read, for a kind whose kernel this bench names itself (the residue operators)."""
    # Among the models that match (kind, kernel), take the one measured at the LARGEST dispatch
    # size: that is the encoder's own dispatch, which is what this bench's top rung reproduces.
    # A control model (ctrl_ffn) carries the same kernel at a smaller n and would otherwise win
    # on file order alone.
    best = None
    for ref in REF_LIST:
        d = json.load(open(ref))
        for name, m in d.get("models", {}).items():
            if REF_MODEL and name != REF_MODEL:
                continue
            k = ((m or {}).get("per_kind", {})).get(kind)
            if not (k and k.get("cycles_per_element") and k.get("kernel") == kernel):
                continue
            n = (k["elements"] // k["dispatches"]) if k.get("dispatches") else 0
            cand = (float(k["cycles_per_element"]),
                    "%s/%s" % (os.path.basename(ref).replace("_run.json", ""), name),
                    n or None, k.get("kernel"))
            if best is None or (n or 0) > (best[2] or 0):
                best = cand
    return best


def b26_rate(kind):
    """cycles/element for `kind` AND the kernel this bench runs, out of a Lab B26/B30 run.json."""
    got = b26_rate_any(kind, WANT_KERNEL[kind])
    if got:
        return got
    saw = []
    for ref in REF_LIST:
        for name, m in json.load(open(ref)).get("models", {}).items():
            k = ((m or {}).get("per_kind", {})).get(kind)
            if k and k.get("cycles_per_element"):
                saw.append("%s/%s/%s" % (os.path.basename(ref), name, k.get("kernel")))
    raise SystemExit("Lab B31 control: no %s measured with %s in %s (saw %s).  The control must "
                     "compare the same kernel at the same size, so point --reference at a run that "
                     "has one." % (kind, WANT_KERNEL[kind],
                                   ", ".join(os.path.basename(r) for r in REF_LIST),
                                   ", ".join(saw) or "nothing"))


ctl = {"gelu": next((r for r in g if r["n"] >= 100000), None),
       "softmax": next((r for r in s if r["n"] >= 100000), None)}
g_ref, g_model, g_n, g_kern = b26_rate("gelu_s8")
s_ref, s_model, s_n, s_kern = b26_rate("softmax_s8")
out["control"] = {
    "reference_run": [os.path.relpath(x, IISWC_ROOT) for x in REF_LIST],
    "reference_bitstream_md5": [json.load(open(x)).get("bitstream_md5") for x in REF_LIST],
    "gelu_per_element": ctl["gelu"]["cycles_per_element"] if ctl["gelu"] else None,
    "gelu_b26_measured": g_ref, "gelu_b26_model": g_model,
    "gelu_b26_n": g_n, "gelu_b26_kernel": g_kern,
    "softmax_per_element": ctl["softmax"]["cycles_per_element"] if ctl["softmax"] else None,
    "softmax_b26_measured": s_ref, "softmax_b26_model": s_model,
    "softmax_b26_n": s_n, "softmax_b26_kernel": s_kern}
ok = True
for k, meas, want in (("gelu", out["control"]["gelu_per_element"], g_ref),
                      ("softmax", out["control"]["softmax_per_element"], s_ref)):
    if meas is None or abs(meas - want) / want > 0.15:
        ok = False
out["control_reproduces_b26"] = ok

# EACH RESIDUE OPERATOR CARRIES ITS OWN CONTROL: its largest size IS the encoder's dispatch size,
# so it must reproduce the rate Lab B26 measured for that kernel, read from the same record.  An
# operator whose control misses is reported and its small-n rows are marked unusable -- one bad
# operator does not invalidate the others, which is why this is per-operator and not a single gate.
OP_KIND = {"layernorm_s8": ("layernorm_s8", "layernorm_pc_s8"), "add_pc_s8": ("add_pc_s8", "add_s8"),
           "rope_s8": ("rope_s8",), "mul_s8": ()}
# THE GATE MULTIPLY HAS NO ENCODER TWIN -- Moonshine's encoder has no elementwise multiply -- so
# its known-answer control is a different one: the same kernel, on the same LCG-generated inputs,
# run on the HOST, where the output is bit-exact because the arithmetic is integer.  These are the
# outputs the host produced (samples/memo_table_bench built with gcc); a board that disagrees is
# not running the kernel this bench thinks it is, whatever its timing says.
HOST_OUT = {("layernorm_s8", 288): (134, -14), ("layernorm_s8", 2880): (178, -47),
            ("layernorm_s8", 47520): (190, -24),
            ("add_pc_s8", 288): (119, 949), ("add_pc_s8", 2880): (152, 935),
            ("add_pc_s8", 47520): (159, -5525),
            ("rope_s8", 288): (112, 590), ("rope_s8", 2880): (142, 715),
            ("rope_s8", 47520): (156, -9834),
            ("mul_s8", 1152): (153, -2135), ("mul_s8", 11520): (177, -1823),
            ("mul_s8", 190080): (180, 5945)}
# gated on the two pure-integer kernels; reported for the two that decode float scales, where a
# host/target difference would be a rounding question and not a wrong kernel
HOST_GATED = ("add_pc_s8", "mul_s8")
for r in ops:
    want = HOST_OUT.get((r["op"], r["n"]))
    r["host_out"] = list(want) if want else None
    r["matches_host"] = (None if not want else
                         (r["out_distinct"], r["out_sum"]) == tuple(want))
op_ctl = {}
for name in sorted(set(r["op"] for r in ops)):
    rows = sorted((r for r in ops if r["op"] == name), key=lambda r: r["n"])
    big = rows[-1]
    entry = {"n": big["n"], "measured": big["cycles_per_element"],
             "out_distinct": big["out_distinct"]}
    ref = None
    for kind in OP_KIND.get(name, ()):
        try:
            ref = b26_rate_any(kind, big["kernel"])
        except SystemExit:
            ref = None
        if ref:
            break
    if ref:
        entry.update(b26_measured=ref[0], b26_model=ref[1], b26_n=ref[2], b26_kernel=ref[3],
                     reproduces=abs(big["cycles_per_element"] - ref[0]) / ref[0] <= 0.15)
    else:
        entry["reproduces"] = None            # no encoder twin: mul_s8 has no encoder dispatch
    hm = [r["matches_host"] for r in rows if r["matches_host"] is not None]
    entry["matches_host"] = (all(hm) if hm else None)
    if entry["reproduces"] is None and name in HOST_GATED and hm:
        entry["reproduces"] = all(hm)         # the host IS this operator's known answer
        entry["control"] = "bit-exact against the host"
    if entry["out_distinct"] < 8:
        entry["reproduces"] = False           # a degenerate output is not a rate
        entry["degenerate_output"] = True
    op_ctl[name] = entry
out["residue_op_control"] = op_ctl
# what twelve softmax dispatches cost a decoder token, measured rather than carried
self_d = next((r for r in s if r["n"] == 48), None)
cross_d = next((r for r in s if r["n"] == 1320), None)
if self_d and cross_d:
    tok = 6 * self_d["cycles"] + 6 * cross_d["cycles"]
    out["decoder_softmax_ms_per_token"] = tok / CLK * 1e3
    out["decoder_softmax_composed_ms"] = 9.52
gelu_dec = next((r for r in g if r["n"] == 1152), None)
if gelu_dec:
    out["decoder_silu_ms_per_token_if_gelu_shaped"] = 6 * gelu_dec["cycles"] / CLK * 1e3
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)
print("   control vs %s (%s / %s): gelu %s c/el (B26 %.3f at n=%s), softmax %s c/el (B26 %.3f at "
      "n=%s) -> %s" % (
    ", ".join(os.path.basename(x) for x in REF_LIST), g_model, s_model,
    round(out["control"]["gelu_per_element"], 2) if ctl["gelu"] else "?", g_ref, g_n,
    round(out["control"]["softmax_per_element"], 2) if ctl["softmax"] else "?", s_ref, s_n,
    "REPRODUCES" if ok else "DOES NOT REPRODUCE -- no small-n number from this run may be used"))
for name, e in sorted(op_ctl.items()):
    print("   %-14s n=%-6d %8.2f c/el   control: %s" % (
        name, e["n"], e["measured"],
        "no encoder twin and no host answer" if e["reproduces"] is None else
        ("bit-exact against the host" if e.get("control") else
        ("REPRODUCES Lab B26's %.2f (%s, n=%s)" % (e["b26_measured"], e["b26_model"], e["b26_n"]))
        if e["reproduces"] else
        ("DOES NOT REPRODUCE %s -- this operator's small-n rows may not be used"
         % (("%.2f" % e["b26_measured"]) if "b26_measured" in e
            else "the host's own output" if e.get("matches_host") is False
            else "(degenerate output)")))))
for r in sorted(ops, key=lambda r: (r["op"], r["n"])):
    print("     %-14s n=%-7d %8.2f c/el  (out_distinct=%d, host %s)"
          % (r["op"], r["n"], r["cycles_per_element"], r["out_distinct"],
             "matches" if r["matches_host"] else "DIFFERS" if r["matches_host"] is False else "-"))
if "decoder_softmax_ms_per_token" in out:
    print("   12 softmax dispatches per token: %.2f ms, composed at %.2f" % (
        out["decoder_softmax_ms_per_token"], out["decoder_softmax_composed_ms"]))
if "decoder_silu_ms_per_token_if_gelu_shaped" in out:
    print("   6 GELU-shaped dispatches of 1,152: %.2f ms per token (SiLU's composed 27.03)" %
          out["decoder_silu_ms_per_token_if_gelu_shaped"])
print("   softmax fill, measured at M=K=1: %s cycles" % out["softmax_fill_cycles_measured"])
sys.exit(0 if ok else 1)
PY
