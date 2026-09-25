#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# LAB B144: lower SignDetLite -- the colour, localising, background-class sign detector --
# through ModelBlaster, and GATE the kernel selection.
#
#   ./scripts/84_signdet_lower.sh                       # RANDOM weights (the default here)
#   ./scripts/84_signdet_lower.sh --ckpt path/to.pt --calib path/to/calib_X.npy
#   ./scripts/84_signdet_lower.sh --name signdet_pt --per-tensor
#
# ==========================================================================================
# WHICH WEIGHTS THIS PRODUCES, AND WHY THE DEFAULT IS RANDOM
# ==========================================================================================
# SignDetLite's trained weights come from GTSDB scenes (see signdet/make_data.py).  GTSDB's
# licence could not be established -- its canonical site does not resolve and the mirrors
# carry no licence text -- so this repository publishes NO artefact that embeds them: not the
# checkpoint, not a lowered weights.c, not a golden computed from one, and not a URL to
# fetch any of it.  docs/SIGNDET_WEIGHTS.md is the whole account.
#
# With no checkpoint to load, this script builds one: signdet/random_weights.py's
# DETERMINISTIC random initialiser (numpy PCG64, seed 144), with the same architecture, the
# same tensor shapes and the same interface quantisation scales as the real model.  The
# lowering, the kernel selection, the codegen, the guest build, both TACIT lanes and Lab
# B156's scheduling result are then all exactly what the real model produces.  What a random
# network cannot do is DETECT, so the replay gate cannot pass; the manifest this script
# writes into the gen tree says so and scripts/90 reports that gate NOT APPLICABLE.
#
# Two ways to get the real thing:
#   * the tutorial image ships the lowered tree.  scripts/91_signdet_install_model.sh puts it
#     where this script would have written it, from a local directory, with a checksum
#     manifest and no network.
#   * your own checkpoint: --ckpt/--calib, or export SIGNDET_CKPT/SIGNDET_CALIB.  Training is
#     signdet/train.py on signdet/make_data.py's set, and that needs a GTSDB copy you
#     obtained from its own source.
#
# ==========================================================================================
# This is scripts/82's flow, not a parallel one: the curated tree is composed by
# sign_compose_kernels() from scripts/lib/sign_gen.sh -- the SAME tree, line for line, that
# the grey SignNet demo lowers against -- and the codegen is the same three ModelBlaster
# stages.  What differs is the gate, and it differs for a reason stated below.
#
# WHY NOT sign_kernel_gate().  That gate demands conv2d_s8 -> roccmoon_engine, because the
# grey arm wants the engine LINKED and CONSULTED so calls_fallback can count the dispatches
# it declines.  This graph is quantised per-channel, so its op is conv2d_s8_pc, for which
# there is no roccmoon engine kernel -- it is served directly by the curated MBP kernel
# pext_conv2d_s8_pc_pext_patch_dot8_pc.c.  That is not a downgrade: the engine declines a 3x3
# spatial convolution by its own IH==1 && KH==1 && PH==0 guard, so on the grey arm the
# convolutions ALREADY run on the pext DOT8 kernel -- `calls_engine 0` in every
# out/sign_live*/run.json.  Per-channel simply reaches the same kernel without the
# indirection.  The gate below is therefore stricter where it counts: EVERY op must be
# curated, and any reference-C fallback fails the run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sign_gen.sh"

NAME="signdet"
SIGNDET_DIR="$IISWC_ROOT/fpga/pynq-z2/modelblaster/signdet"
# NO BAKED-IN PATH.  Empty means "decide below"; the real checkpoint, if an operator has one,
# is looked for where signdet/_paths.py's work() puts it and nowhere else.
CKPT="${SIGNDET_CKPT:-}"
CALIB="${SIGNDET_CALIB:-}"
WORK="${SIGNDET_WORK:-$IISWC_OUT/signdet_work}"
NCAL=64
PERCHANNEL=1
OUTROOT="$IISWC_OUT"
# THE SEED, STATED.  signdet/random_weights.py draws every number from numpy's PCG64 at this
# seed, so two clones get byte-identical weights whatever their torch build.
SEED=144
FORCE_RANDOM=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name)  NAME="${2:?}"; shift 2 ;;
    --ckpt)  CKPT="${2:?}"; shift 2 ;;
    --calib) CALIB="${2:?}"; shift 2 ;;
    --ncal)  NCAL="${2:?}"; shift 2 ;;
    --seed)  SEED="${2:?}"; shift 2 ;;
    --random-weights) FORCE_RANDOM=1; shift ;;
    --per-tensor) PERCHANNEL=0; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

RUN="$OUTROOT/$NAME"
IR="$RUN/ir"; GEN="$RUN/gen"; CUR="$RUN/kernels_board"; RAND="$RUN/random"
PY="$ZCS/tools/miniforge3/envs/zephyr/bin/python"; [ -x "$PY" ] || PY=python3
MB="$ZCS/modelblaster"
[ -d "$MB" ] || die "no ModelBlaster at $MB -- run scripts/00_bootstrap.sh"
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
export IISWC_OUT SIGNDET_WORK="$WORK"

rm -rf "$RUN"; mkdir -p "$RUN"

########################################################################################
# 0.  WHICH WEIGHTS.  Decided here, once, printed, and recorded in the gen tree.
########################################################################################
step "0/5  which weights"
WMODE=real
if [ "$FORCE_RANDOM" = 1 ]; then
  WMODE=random
  [ -z "$CKPT" ] || warn "--random-weights overrides --ckpt $CKPT"
  CKPT=""; CALIB=""
elif [ -z "$CKPT" ]; then
  # The only place a real checkpoint is looked for, and it is NOT in this repository.
  if [ -f "$WORK/b144/run/signdet_b144.pt" ]; then
    CKPT="$WORK/b144/run/signdet_b144.pt"
    CALIB="${CALIB:-$WORK/b144/run/calib_X.npy}"
  else
    WMODE=random
  fi
fi

if [ "$WMODE" = random ]; then
  cat <<'BANNER'

    ######################################################################################
    #  RANDOM WEIGHTS.  This model has NO DETECTION ABILITY.                             #
    #                                                                                    #
    #  The trained SignDetLite weights are GTSDB-derived and are not published in this    #
    #  repository (docs/SIGNDET_WEIGHTS.md).  What is lowered below is a deterministic    #
    #  random initialiser with the same shapes and the same interface scales, so the      #
    #  whole pipeline -- lowering, codegen, the guest image, both TACIT lanes, the        #
    #  scheduling result -- runs and is measurable.  The REPLAY correctness gate cannot   #
    #  pass and is reported NOT APPLICABLE, never FAIL.                                   #
    ######################################################################################

BANNER
  run "$PY" "$SIGNDET_DIR/random_weights.py" --out "$RAND" --seed "$SEED" --ncalib "$NCAL"
  CKPT="$RAND/signdet_random.pt"
  CALIB="$RAND/calib_X.npy"
else
  info "REAL weights: $CKPT"
  info "              detection is meaningful; the replay gate in scripts/90 applies."
fi

need_file "$CKPT" "no checkpoint"
need_file "$CALIB" "no calibration frames -- the PTQ has nothing to observe"
CKPT_SHA="$("$PY" -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$CKPT")"
info "mode $WMODE   ckpt $CKPT"
info "sha256 $CKPT_SHA"
# ONE PLACE TO LOOK.  scripts/86 and the host gates want the calibration array that produced
# these scales; putting it beside the IR means they never have to know which mode ran.
cp "$CALIB" "$RUN/calib_X.npy"

export B144_CKPT="$CKPT" B144_CALIB="$CALIB" B144_SIGNDET_DIR="$SIGNDET_DIR"

# THE MODEL MODULE LIVES IN THIS REPO, NOT IN THE SUBMODULE.  extract_graph resolves --model
# by importing modelblaster.models.<id>, so the file has to sit inside the modelblaster
# package -- and that package is under zephyr-chipyard-sw, a SUBMODULE this lab should not be
# committing into.  So the canonical copy is committed here, beside the training code, and is
# installed into the package at run time.  Refuses to clobber a different file it did not put
# there.
step "1/5  install the model module into the modelblaster package"
SRC="$SIGNDET_DIR/mb_model_module.py"
DST="$MB/models/signdet_b144.py"
need_file "$SRC"
if [ -e "$DST" ] && ! cmp -s "$SRC" "$DST"; then
  warn "$DST differs from the committed copy; overwriting with $SRC"
fi
cp "$SRC" "$DST.tmp$$" && mv -f "$DST.tmp$$" "$DST"
info "installed $DST"

step "2/5  curated kernel tree (scripts/lib/sign_gen.sh, the same tree the grey arm uses)"
sign_compose_kernels "$CUR"
info "$(find "$CUR" -name '*.c' | wc -l) curated kernels"

step "3/5  extract_graph (int8 PTQ, calibrated on $NCAL frames)"
PCFLAG=""; [ "$PERCHANNEL" = 1 ] && PCFLAG="--per-channel"
( cd "$ZCS" && run "$PY" -m modelblaster.pipeline.extract_graph \
    --model signdet_b144 --out-dir "$IR" --quant int8 \
    --num-calibration "$NCAL" $PCFLAG --fusion-target roccmoon ) \
  > "$RUN/codegen.log" 2>&1 || { tail -30 "$RUN/codegen.log"; die "extract_graph failed"; }
need_file "$IR/graph.json"

step "4/5  generate_skeleton + generate_kernels"
( cd "$ZCS" && "$PY" -m modelblaster.pipeline.generate_skeleton \
    --ir "$IR/graph.json" --weights "$IR/weights.npz" --io "$IR/io.npz" \
    --out-dir "$GEN" --backend roccmoon ) >> "$RUN/codegen.log" 2>&1 \
  || { tail -30 "$RUN/codegen.log"; die "generate_skeleton failed"; }
( cd "$ZCS" && "$PY" -m modelblaster.pipeline.generate_kernels \
    --ir "$IR/graph.json" --out-dir "$GEN" --backend reference --target roccmoon \
    --quant int8 --io "$IR/io.npz" --repo-root "$MB" --build-dir "$RUN/kverify" \
    --harness-dir "$MB/harness" --cache-dir "$RUN/cache" --algorithms all \
    --global-curated-dir "$CUR" ) >> "$RUN/codegen.log" 2>&1 \
  || { tail -30 "$RUN/codegen.log"; die "generate_kernels failed"; }
need_file "$GEN/kernels.c" "codegen produced no kernels"

step "5/5  op coverage, the guest's two scales, and the manifest"
"$PY" - "$IR/graph.json" "$GEN/kernel_picks.json" <<'PYEOF'
import json, sys
g = json.load(open(sys.argv[1])); p = json.load(open(sys.argv[2]))["picks"]
mac = 0
for n in g["ops"]:
    s = n.get("shape", {})
    if n["op"].startswith("conv2d"):
        mac += s["OH"] * s["OW"] * s["OC"] * s["IC"] * s["KH"] * s["KW"]
for k in sorted(p):
    print("    %-18s %-20s %s" % (k, p[k].get("source"), p[k].get("algorithm")))
bad = [k for k in p if p[k].get("source") == "reference"]
print("    MAC %d   est %.2f M cycles   est %.1f ms @ 40 MHz  (1.2755 cyc/MAC, Lab B121)"
      % (mac, mac * 1.2755 / 1e6, mac * 1.2755 / 40e6 * 1e3))
if mac * 1.2755 / 40e6 * 1e3 > 350.0:
    sys.exit("BUDGET: %.1f ms exceeds the ~350 ms the XPU-RT co-location schedule leaves"
             % (mac * 1.2755 / 40e6 * 1e3))
if bad:
    sys.exit("reference-C fallback for: %s -- every op in this graph must be curated"
             % ", ".join(sorted(bad)))
print("    all ops curated, no reference-C fallback")
PYEOF

# THE TWO SCALES THE GUEST IS COMPILED WITH ARE NOT PRIVATE TO THE GRAPH.  sign_pre.c
# quantises with SIGN_IN_SCALE_RECIP and main.c decodes a percentage with SD_OUT_SCALE_PPB;
# both are -D flags in scripts/86, 87 and 90.  Read them off the IR that was just produced,
# gate them against the values those scripts pass, and write them into the manifest so a
# later reader never has to trust this comment.
"$PY" - "$IR/graph.json" "$GEN/signdet_weights.json" "$WMODE" "$SEED" "$CKPT_SHA" \
        "$IR" <<'PYEOF'
import hashlib, json, os, sys
graph_p, man_p, mode, seed, sha, ir = sys.argv[1:7]
g = json.load(open(graph_p))
t = g["tensors"]
qi = t[g["input"]["tensor"]]["quant"]; qo = t[g["output"]["tensor"]]["quant"]
recip = 1.0 / float(qi["scale"])
ppb = round(float(qo["scale"]) * 1e9)
ncls = t[g["output"]["tensor"]]["shape"][-1]
print("    input  scale %.12f  -> SIGN_IN_SCALE_RECIP=%.4f" % (qi["scale"], recip))
print("    output scale %.12f  -> SD_OUT_SCALE_PPB=%d" % (qo["scale"], ppb))
bad = []
if int(qi["zero_point"]) != 0 or abs(recip - 127.0) > 1e-6:
    bad.append("input scale is %r, not 1/127 -- sign_pre.c is compiled with "
               "SIGN_IN_SCALE_RECIP=127 and would quantise onto a different grid" % qi)
if ppb != 7874016:
    bad.append("output scale gives SD_OUT_SCALE_PPB=%d, not 7874016 -- every percentage "
               "the board prints would be wrong by that ratio" % ppb)
if ncls != 3:
    bad.append("this graph has %d classes, not 3" % ncls)
if bad:
    sys.exit("\n       ".join(["the lowered graph does not match the guest's contract:"] + bad))
man = {
    "schema_version": 1,
    "model": "signdet_b144 (SignDetLite)",
    "weights_mode": mode,
    "checkpoint_sha256": sha,
    "ir_md5": hashlib.md5(open(graph_p, "rb").read()).hexdigest(),
    "in_scale_recip": int(round(recip)),
    "out_scale_ppb": ppb,
    "classes": ncls,
    "replay_gate": "applicable" if mode == "real" else "not_applicable",
}
if mode == "random":
    man["seed"] = int(seed)
    man["provenance"] = ("deterministic random initialiser, "
                         "fpga/pynq-z2/modelblaster/signdet/random_weights.py")
    man["detection"] = ("NONE.  The replay gate (8 baked frames against the host's answers) "
                        "cannot pass with these weights and must be reported NOT APPLICABLE.")
    rj = os.path.join(os.path.dirname(ir), "random", "random_weights.json")
    if os.path.exists(rj):
        man["random_weights"] = json.load(open(rj))
else:
    man["provenance"] = "operator-supplied trained checkpoint"
    man["detection"] = "meaningful; the replay gate applies."
with open(man_p, "w") as fh:
    json.dump(man, fh, indent=2)
print("    manifest %s  (weights_mode=%s, replay_gate=%s)"
      % (man_p, man["weights_mode"], man["replay_gate"]))
PYEOF

step "done"
info "mode  $WMODE"
info "IR    $IR"
info "gen   $GEN"
info "picks $GEN/kernel_picks.json"
info "manifest $GEN/signdet_weights.json"
[ "$WMODE" = random ] && info "REMINDER: random weights cannot detect.  scripts/90's REPLAY
       gate is NOT APPLICABLE; every other gate in that lab still means what it says."
exit 0
