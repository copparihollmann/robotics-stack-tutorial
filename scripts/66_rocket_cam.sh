#!/usr/bin/env bash
# Lab B27 -- the HM01B0 camera on the Z1 shield, on bitstream 0x5A5A001E (docs/CAMERA_Z1.md).
#
#   scripts/with_board.sh ./scripts/66_rocket_cam.sh
#   scripts/with_board.sh ./scripts/66_rocket_cam.sh --mclkdiv 2
#   scripts/with_board.sh ./scripts/66_rocket_cam.sh --build-only
#   scripts/with_board.sh ./scripts/66_rocket_cam.sh --variant all_f40   # 0x5A5A0038, 40 MHz
#
# TWO BITSTREAMS CARRY THIS CAMERA, and the gate moves per variant rather than widening:
#
#   --variant cam      0x5A5A001E, the camera-only SoC at 34.4828 MHz, Zephyr board
#                      chipyard_pynqz1_cam, ospi on PLIC source 9.  The default.
#   --variant all_f40  0x5A5A0038, EVERY interface at once at 40 MHz -- the nch8 engine, the
#                      P-extension, the mic, the RGB LEDs, the I2C bus, four buttons AND this
#                      capture DMA, with TACIT traded away to pay for it (B137).  Zephyr
#                      board chipyard_pynqz1_all_f40, ospi on PLIC source 13.  This is the
#                      one the tutorial needs, and it is a PARAMETER: the MAGIC, the md5, the
#                      clock, the board, the runner and the devicetree check all move
#                      together, so a run cannot half-switch.
#
# samples/cam_capture, with or without the shield -- the shield was ordered 2026-09-15 and may not
# be on the board.  The guest decides which case it is in and says so on the console
# (CAM_SHIELD present=0|1); a board without the shield is a PASS of the no-shield checks, not a
# failure:
#
#   both      MAGIC 0x5A5A001E and the bitstream md5 (gated, always loaded by this run); FCLK0
#             read back from the SLCR; every ospi register at reset (CAPACITY 512, GEOM 324x244)
#   no shield PCLKCNT/FVLDCNT/LVLDCNT read 0 and do not move over 500 ms; a MODEL_ID read at 0x24
#             NACKs (-EIO); a DMA transfer armed with no PCLK stays BUSY in COLLECT with 0 bytes
#             for 1 s and is reported (it stays armed until the SoC is reset -- no abort in RTL)
#   shield    MODEL_ID = 0x01B0; MCLKDIV set (default 2: 5.747 MHz); MODE_SELECT = 1; PCLK Hz,
#             frames/s and lines/frame measured from the diagnostic counters over 1 s; one whole
#             frame through the DMA into DDR; the PS reads the same bytes over /dev/mem, the
#             checksum must match the guest's, and the frame is written to frame.pgm here
#
# AFTER THE SESSION (docs/EXPERIMENT_LOG_RULES.md): archive/tools/archive_run.py rocket_cam, then a
# Lab 35 health check (scripts/35_rocket_rgb_leds.sh) in the same board session.  If this run
# reports PS_HOLDS or 0 console bytes, stop all board work and tell the coordinator.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

SAMPLE="$IISWC_ROOT/samples/cam_capture"
VARIANT="cam"
MCLKDIV=2; IDLE_READ=90; DO_BOARD=1
NAME_OVR=""; BIT_OVR=""; BUILD_OVR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT="${2:?}"; shift 2 ;;
    --name) NAME_OVR="${2:?}"; shift 2 ;;
    --bit) BIT_OVR="${2:?}"; shift 2 ;;
    --build) BUILD_OVR="${2:?}"; shift 2 ;;
    --mclkdiv) MCLKDIV="${2:?}"; shift 2 ;;
    --idle) IDLE_READ="${2:?}"; shift 2 ;;
    --build-only) DO_BOARD=0; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Everything that identifies a machine moves together.  OSPI_IRQ is the ospi node's PLIC source
# in that bitstream's own bootrom DTB, and the devicetree check below refuses an image built
# against the other SoC's numbering -- which is a console that looks hung, not an error message.
case "$VARIANT" in
  cam)
    NAME="rocket_cam"
    BOARD="chipyard_pynqz1_cam"
    BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmooncam_z1"
    BIT="$BUILD/pynqz1_rocket_micrgb_roccmooncam.bit"
    RUNNER="run_rocket_roccmooncam.py"
    WANT_MAGIC="0x5A5A001E"
    CFGNAME="PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig"
    FCLK_CORE=34.4828; FCLK_EXPECT=34.4828; FCLK_ARG=""
    WANT_MTIME_HZ=34483; OSPI_IRQ=9
    # 659c6db6: 0x5A5A001E as built in this workstream, 2026-09-17 11:33 -- 16/16 camera pins
    # verified in the routed design, U13 unassigned, WHS positive on every clock, and the
    # camera, DMA and I2C checked in this config's own RTL first (scripts/65, 53 checks).
    VARIANT_ACCEPTED=659c6db6ecdbe091a7ff4494881f4e2e ;;
  all_f40)
    NAME="rocket_cam_all_f40"
    BOARD="chipyard_pynqz1_all_f40"
    BUILD="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98ball_z1"
    BIT="$BUILD/pynqz1_rocket_micrgb_roccmoonnch8f40b98ball.bit"
    RUNNER="run_rocket_roccmoonnch8f40b98ball.py"
    WANT_MAGIC="0x5A5A0038"
    CFGNAME="PynqZ2RocketBigLittlePextMicRgbRoccMoonAllNch8I2cBtnCamNoTacitConfig"
    FCLK_CORE=40; FCLK_EXPECT=40; FCLK_ARG="--fclk 40"
    WANT_MTIME_HZ=40000; OSPI_IRQ=13
    # ced0aab0: 0x5A5A0038 as built by B137, 2026-09-21 -- clk_fpga_0 WNS +0.022 / WHS +0.035,
    # 0 of 88,772 endpoints failing at 40 MHz (MAGIC_REGISTRY.md).  Never loaded before this lab.
    VARIANT_ACCEPTED=ced0aab0c7b52f25338eeffe8f678e4f ;;
  *) die "unknown --variant: $VARIANT (cam, all_f40)" ;;
esac
[ -n "$NAME_OVR" ]  && NAME="$NAME_OVR"
[ -n "$BUILD_OVR" ] && BUILD="$BUILD_OVR"
[ -n "$BIT_OVR" ]   && BIT="$BIT_OVR"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"

# This lab's own validated camera builds (md5), named in lib/bitstream_id.sh and NOT added to its
# shared BIT_ACCEPTED (a lab extends the gate rather than widening it; see scripts/43).
# The accepted md5 is THE SELECTED VARIANT'S, not a list of both: loading 0x5A5A0038's bitstream
# and booting 0x5A5A001E's guest is exactly the mistake the variant table exists to prevent.
CAM_ACCEPTED="${CAM_ACCEPTED:-$VARIANT_ACCEPTED}"
BIT_ACCEPTED="$CAM_ACCEPTED"

step "1/4  build the guest ($BOARD, MCLKDIV $MCLKDIV)"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- -DBOARD_ROOT="$IISWC_ROOT" \
  -DCAM_MCLKDIV="$MCLKDIV" > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed"; }
need_file "$RUN/build/zephyr/zephyr.bin" "build produced no raw image"
cp "$RUN/build/zephyr/zephyr.elf" "$RUN/build/zephyr/zephyr.bin" "$RUN/build/zephyr/zephyr.dts" "$RUN/"
grep -q '^CONFIG_I2C_SIFIVE=y' "$RUN/build/zephyr/.config" \
  || die "CONFIG_I2C_SIFIVE is not set: the i2c@10040000 node did not match sifive,i2c0 (boards/chipyard/pynqz1_cam)"
HZ=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$RUN/build/zephyr/.config" | cut -d= -f2)
[ "${HZ:-0}" = "$WANT_MTIME_HZ" ] || die "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ, expected $WANT_MTIME_HZ"
# The PLIC numbers 0x5A5A001E's generated DTS gives (the I2C took source 1, so the UART is 2).
python3 - "$RUN/zephyr.dts" "$OSPI_IRQ" <<'PY' || die "the built devicetree does not carry $WANT_MAGIC's interrupt numbers"
import re, sys
lines = open(sys.argv[1]).read().split("\n")
def props(node):
    for i, l in enumerate(lines):
        if re.search(r"\b%s \{" % re.escape(node), l):
            ind = len(l) - len(l.lstrip("\t"))
            body = []
            for m in lines[i + 1:]:
                if m.startswith("\t" * ind + "};"):
                    break
                body.append(re.sub(r"/\*.*?\*/", "", m).strip())
            return " ".join(body)
    return ""
want = {"uart@10020000": (2, 1), "i2c@10040000": (1, 1), "ospi@10080000": (int(sys.argv[2]), 1)}
bad = []
for node, (src, prio) in want.items():
    b = props(node)
    m = re.search(r"interrupts = <\s*(0x[0-9a-f]+|\d+)\s+(0x[0-9a-f]+|\d+)\s*>", b)
    if not m or (int(m.group(1), 0), int(m.group(2), 0)) != (src, prio) or 'status = "okay"' not in b:
        bad.append("%s: %s" % (node, m.group(0) if m else "no interrupts"))
print("    devicetree: uart 2, i2c 1, ospi %s -- %s" % (sys.argv[2], "ok" if not bad else "MISMATCH %s" % bad))
sys.exit(1 if bad else 0)
PY
info "image: $(fsize "$RUN/zephyr.bin")   mtime: $HZ Hz   i2c_sifive: in"
[ "$DO_BOARD" -eq 1 ] || { info "--build-only"; exit 0; }

step "2/4  identify the bitstream, load the PL, read the clocks back"
need_file "$BIT" "no bitstream -- build it with fpga/pynq-z2/scripts/build_roccmooncam_z1.sh"
bitstream_identify "$BIT"
bitstream_gate
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$IISWC_ROOT/fpga/pynq-z2/host/read_mem.py" \
      "$RUN/zephyr.bin" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") $FCLK_ARG --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
# Workstation time is the record; the board's clock is ~500 days behind.  Both, and the offset.
H0=$(date +%s.%N); B0=$("${SSH[@]}" "date +%s.%N" 2>/dev/null || echo ""); H1=$(date +%s.%N)
python3 -c "import json,sys,datetime; h0,h1=float(sys.argv[1]),float(sys.argv[2]); b=sys.argv[3]
out={'workstation_time': datetime.datetime.fromtimestamp((h0+h1)/2).astimezone().isoformat(timespec='seconds'),
     'board_time_epoch_s': float(b) if b else None,
     'board_minus_workstation_s': (float(b)-(h0+h1)/2) if b else None, 'ssh_round_trip_s': h1-h0}
json.dump(out, open(sys.argv[4],'w'), indent=1)" "$H0" "$H1" "$B0" "$RUN/clocks.json"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_EXPECT" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_EXPECT MHz"; }

step "3/4  boot, and read the console"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds 0 --idle $IDLE_READ > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
BYTES=$(wc -c < "$RUN/console.txt" 2>/dev/null || echo 0)
if [ "${BYTES:-0}" -eq 0 ] || grep -q "PS_HOLDS" "$RUN/boot.log"; then
  cat "$RUN/boot.log"
  die "0 console bytes or PS_HOLDS. STOP all board work and message the coordinator
       (docs/EXPERIMENT_LOG_RULES.md). Nothing from this run is a result."
fi
grep -E "^CAM_(BOOT|REGS_CHECK|DIAG|I2C_PROBE|SHIELD|NOSHIELD|DMA_TIMEOUT|SENSOR|MCLK|SREG|STREAM|PROBE|GEOM|STATS|SET|MOVE|EVICT|FRAME|FRAME2|RESULT) " "$RUN/console.txt" \
  || { tail -40 "$RUN/console.txt"; die "no CAM_ lines: the guest did not reach main (a wrong UART interrupt looks exactly like this)"; }

# The frames, from the PS side, if the guest captured any.  BOTH of them: CAM_FRAME is the
# baseline and CAM_FRAME2 is the one taken after the sensor was told to change (its readout
# flipped, then its analogue gain moved).  Two independently-read frames are what lets the
# report below say whether the bytes FOLLOW THE SENSOR, which no checksum can.
for TAG in CAM_FRAME CAM_FRAME2; do
  case "$TAG" in CAM_FRAME) OUT=frame ;; *) OUT=frame2 ;; esac
  FRAME_LINE=$(grep -E "^$TAG ok=1 " "$RUN/console.txt" | tail -1 || true)
  [ -n "$FRAME_LINE" ] || continue
  PHYS=$(printf '%s\n' "$FRAME_LINE" | grep -oE 'phys=0x[0-9a-f]+' | cut -d= -f2)
  W=$(printf '%s\n' "$FRAME_LINE" | grep -oE 'width=[0-9]+' | cut -d= -f2)
  H=$(printf '%s\n' "$FRAME_LINE" | grep -oE 'height=[0-9]+' | cut -d= -f2)
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 read_mem.py --phys $PHYS --bytes $((W * H)) --out $OUT.raw" \
    >> "$RUN/boot.log" 2>&1 || warn "read_mem.py failed for $TAG"
  scp -q "$PYNQ_HOST:$PYNQ_DIR/$OUT.raw" "$RUN/$OUT.raw" 2>/dev/null || warn "could not copy $OUT.raw"
done

step "4/4  run.json"
UTIL="$BUILD/reports/post_route_util.rpt"; TIM="$BUILD/reports/timing_summary.rpt"
LUT=""; FF=""; BRAM=""; DSP=""; WNS=""; WHS=""
if [ -f "$UTIL" ]; then
  LUT=$(awk -F'|' '/\| Slice LUTs +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  FF=$(awk -F'|' '/\| Slice Registers +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  BRAM=$(awk -F'|' '/\| Block RAM Tile +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
  DSP=$(awk -F'|' '/\| DSPs +\|/ {gsub(/ /,"",$3); print $3; exit}' "$UTIL")
fi
# The design summary puts WNS, TNS, TNS-failing, TNS-total, WHS, ... on ONE row under one header,
# so WHS is column 5 of the WNS row -- there is no line starting with WHS(ns) to match.
[ -f "$TIM" ] && { read -r WNS WHS <<< "$(awk '/^ *WNS\(ns\)/{getline; getline; print $1, $5; exit}' "$TIM")"; }
export BIT_MD5 WANT_MAGIC CFGNAME LUT FF BRAM DSP WNS WHS MCLKDIV VARIANT
python3 - "$RUN" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run = sys.argv[1]
txt = open(os.path.join(run, "console.txt"), errors="replace").read()
def kv(tag):
    out = []
    for line in re.findall(r"^%s (.*)$" % tag, txt, re.M):
        d = {}
        for k, v in re.findall(r"(\w+)=(\S+)", line):
            d[k] = int(v, 0) if re.fullmatch(r"-?(0x[0-9a-fA-F]+|\d+)", v) else v
        out.append(d)
    return out
# post_route.wns is the build's worst slack over ALL clocks; for 0x5A5A001E that is the camera's
# input budget at the 36 MHz datasheet maximum, not the SoC clock (docs/CAMERA_Z1.md 7.5).
# WHICH PHYSICAL BOARD.  Two PYNQ-Z1s run the same bitstream md5, so config + md5 does not
# identify a machine (fpga/pynq-z2/bwlab/boards.csv), and taking a lock does not select one.
out = {"lab": "B27 cam_capture", "board": os.environ.get("IISWC_BOARD", ""),
       "pynq_host": os.environ.get("PYNQ_HOST", ""),
       "variant": os.environ.get("VARIANT", ""), "bitstream_md5": os.environ.get("BIT_MD5", ""),
       "soc_magic": os.environ.get("WANT_MAGIC", ""), "config": os.environ.get("CFGNAME", ""),
       "mclkdiv": int(os.environ.get("MCLKDIV", "0")),
       "fclk": json.load(open(os.path.join(run, "fclk.json"))),
       "clocks": json.load(open(os.path.join(run, "clocks.json"))),
       "post_route": {k.lower(): os.environ.get(k, "") for k in ("LUT", "FF", "BRAM", "DSP", "WNS", "WHS")},
       "post_route_wns_note": ("worst over all clocks; for 0x5A5A001E a negative value is the camera "
                               "input budget at 36 MHz on cam_pclk, which this design cannot drive "
                               "(MCLK tops out at 17.241 MHz; +13.544 ns there). clk_fpga_0 was "
                               "+1.126 / WHS +0.037 in build 659c6db6 -- CAMERA_Z1.md 7.5")}
for tag in ("CAM_BOOT", "CAM_REGS", "CAM_REGS_CHECK", "CAM_DIAG", "CAM_I2C_PROBE", "CAM_SHIELD",
            "CAM_NOSHIELD", "CAM_DMA_TIMEOUT", "CAM_LEFT_ARMED", "CAM_SENSOR", "CAM_MCLK",
            "CAM_STREAM", "CAM_PROBE", "CAM_GEOM", "CAM_STATS", "CAM_SET", "CAM_MOVE",
            "CAM_EVICT", "CAM_FRAME", "CAM_FRAME2", "CAM_RESULT"):
    out[tag.lower()] = kv(tag)
out["cam_left_armed"] = kv("CAM_LEFT_ARMED")
res = out["cam_result"][-1] if out["cam_result"] else {}
frame = out["cam_frame"][-1] if out["cam_frame"] else {}
#
# IS IT AN IMAGE?  The checksum gate below proves the bytes the guest summed are the bytes in
# DDR.  It cannot tell a picture from a stuck bus, a constant fill or noise -- all three
# checksum perfectly well.  These statistics are computed HERE, from the bytes the PS read,
# independently of the guest's own arithmetic, and each excludes a different failure:
#
#   distinct, zeros, ffs        a stuck or unwritten bus lives in one or two bins
#   lag1 vs lag2 mean |delta|   THE DISCRIMINATOR.  In a BAYER MOSAIC of a real scene,
#     along rows and columns    neighbours are different colour channels and next-but-one
#                               neighbours are the same channel on a locally smooth image, so
#                               lag1 > lag2 in BOTH directions.  Uniform noise gives
#                               lag1 == lag2 == ~85.3; a constant gives 0; a smooth mono
#                               image gives lag1 < lag2.  No bus failure produces lag1 > lag2 > 0.
#   the four Bayer-site means   R, Gr, Gb, B under a colour filter array differ; on a mono
#                               part they do not.
#   frame vs frame2             the same scene after the sensor was told to change.  Identical
#                               bytes mean nothing moved; a frame2 that matches frame ROTATED
#                               means the sensor's own readout order followed a register write.
def stats(data, w, h):
    n = w * h
    if n == 0 or len(data) < n:
        return None
    hist = [0] * 256
    for b in data[:n]:
        hist[b] += 1
    rows = [data[y * w:(y + 1) * w] for y in range(h)]
    def lag_h(k):
        t = c = 0
        for r in rows:
            for i in range(w - k):
                t += abs(r[i] - r[i + k]); c += 1
        return t / c if c else 0.0
    def lag_v(k):
        t = c = 0
        for y in range(h - k):
            a, b = rows[y], rows[y + k]
            for i in range(w):
                t += abs(a[i] - b[i]); c += 1
        return t / c if c else 0.0
    q = [[0, 0], [0, 0]]
    qn = [[0, 0], [0, 0]]
    for y in range(h):
        r = rows[y]
        for x in range(w):
            q[y & 1][x & 1] += r[x]; qn[y & 1][x & 1] += 1
    mean = sum(data[:n]) / n
    var = sum((b - mean) ** 2 for b in data[:n]) / n
    return {"bytes": n, "width": w, "height": h,
            "min": min(data[:n]), "max": max(data[:n]), "mean": round(mean, 3),
            "stddev": round(var ** 0.5, 3),
            "zeros": hist[0], "ffs": hist[255], "distinct": sum(1 for v in hist if v),
            "lag1_h": round(lag_h(1), 3), "lag2_h": round(lag_h(2), 3),
            "lag1_v": round(lag_v(1), 3), "lag2_v": round(lag_v(2), 3),
            "bayer_site_mean": [[round(q[a][b] / qn[a][b], 3) for b in (0, 1)] for a in (0, 1)]}

# THE TWO TESTS THAT SEPARATE A COLOUR FILTER ARRAY FROM A FIXED PATTERN, and the one that
# finds the sensor's line padding.  A 2x2 periodic difference could be a CFA or it could be a
# fixed additive offset in the readout.  A CFA is MULTIPLICATIVE -- it is a difference in
# spectral throughput -- so its site spread scales with how bright that part of the scene is
# and changes with the scene's colour; an offset does not.  So measure the spread per
# quadrant and report it beside the quadrant's own mean.
def site_spread_by_region(data, w, h, nb=2):
    outr = []
    for ry in range(nb):
        for rx in range(nb):
            q = [[0, 0], [0, 0]]; qn = [[0, 0], [0, 0]]
            for y in range(ry * h // nb, (ry + 1) * h // nb):
                r = data[y * w:(y + 1) * w]
                for x in range(rx * w // nb, (rx + 1) * w // nb):
                    q[y & 1][x & 1] += r[x]; qn[y & 1][x & 1] += 1
            m = [q[a][b] / qn[a][b] for a in (0, 1) for b in (0, 1)]
            outr.append({"band": [ry, rx], "mean": round(sum(m) / 4, 3),
                         "site_spread": round(max(m) - min(m), 3),
                         "sites": [round(v, 3) for v in m]})
    return outr

# The HM01B0's line is wider than its pixel array.  Find how many leading columns are padding
# by looking for columns whose mean and code count are far below the rest of the line.
def leading_pad(data, w, h):
    cols = []
    for x in range(min(w, 8)):
        c = [data[y * w + x] for y in range(h)]
        cols.append({"col": x, "mean": round(sum(c) / h, 3), "distinct": len(set(c))})
    body = [data[y * w + x] for y in range(h) for x in range(8, w)]
    bmean = sum(body) / len(body)
    n = 0
    for c in cols:
        if c["mean"] < 0.25 * bmean and c["distinct"] < 24:
            n += 1
        else:
            break
    return {"leading_columns": cols, "body_mean": round(bmean, 3), "pad_columns": n,
            "pixel_width": w - n}

def verdict(st):
    if st is None:
        return "no frame"
    if st["distinct"] <= 2 or st["zeros"] + st["ffs"] > 0.98 * st["bytes"]:
        return "NOT AN IMAGE: a stuck or unwritten bus"
    if st["lag1_h"] > st["lag2_h"] and st["lag1_v"] > st["lag2_v"] and st["lag2_h"] > 0:
        return "BAYER MOSAIC of a structured scene (lag1 > lag2 both ways)"
    if abs(st["lag1_h"] - st["lag2_h"]) < 2 and st["lag1_h"] > 60:
        return "NOT AN IMAGE: consistent with uniform noise"
    if st["lag1_h"] < st["lag2_h"] and st["lag1_v"] < st["lag2_v"]:
        return "a smooth (non-mosaic) image: lag1 < lag2 both ways"
    return "inconclusive -- read the numbers"

raw = os.path.join(run, "frame.raw")
if frame.get("ok") == 1 and os.path.exists(raw):
    data = open(raw, "rb").read()
    out["ps_readback"] = {"bytes": len(data), "sum": sum(data), "matches_guest_sum": sum(data) == frame.get("sum")}
    with open(os.path.join(run, "frame.pgm"), "wb") as f:
        f.write(b"P5\n%d %d\n255\n" % (frame["width"], frame["height"]) + data)
    st = stats(data, frame["width"], frame["height"])
    out["ps_stats"] = st
    out["ps_stats_verdict"] = verdict(st)
    out["ps_site_spread_by_region"] = site_spread_by_region(data, frame["width"], frame["height"])
    out["ps_line_padding"] = leading_pad(data, frame["width"], frame["height"])
frame2 = out["cam_frame2"][-1] if out.get("cam_frame2") else {}
raw2 = os.path.join(run, "frame2.raw")
if frame2.get("ok") == 1 and os.path.exists(raw2):
    d2 = open(raw2, "rb").read()
    out["ps_readback2"] = {"bytes": len(d2), "sum": sum(d2), "matches_guest_sum": sum(d2) == frame2.get("sum")}
    with open(os.path.join(run, "frame2.pgm"), "wb") as f:
        f.write(b"P5\n%d %d\n255\n" % (frame2["width"], frame2["height"]) + d2)
    out["ps_stats2"] = stats(d2, frame2["width"], frame2["height"])
    if "ps_readback" in out and len(d2) == len(data):
        n = len(d2)
        mad = sum(abs(a - b) for a, b in zip(data, d2)) / n
        mad_rot = sum(abs(data[i] - d2[n - 1 - i]) for i in range(n)) / n
        # Mean absolute difference is not enough on its own: a gain or exposure change between
        # the two frames moves it without any geometry changing.  Pearson correlation is
        # invariant to both, so it answers the geometric question alone -- IS frame2 frame
        # ROTATED?  A correlation against the rotated copy that is far above the one against
        # the straight copy can only come from the sensor's own readout order reversing.
        def corr(a, b):
            n = len(a)
            sa = sum(a); sb = sum(b)
            saa = sum(v * v for v in a); sbb = sum(v * v for v in b)
            sab = sum(x * y for x, y in zip(a, b))
            num = n * sab - sa * sb
            den = ((n * saa - sa * sa) * (n * sbb - sb * sb)) ** 0.5
            return num / den if den else 0.0
        rot = d2[::-1]
        out["frame_vs_frame2"] = {"mean_abs_diff": round(mad, 3),
                                  "mean_abs_diff_vs_rot180": round(mad_rot, 3),
                                  "corr_straight": round(corr(data, d2), 5),
                                  "corr_vs_rot180": round(corr(data, rot), 5),
                                  "identical": data == d2}
verdict = ("PASS" if res.get("ok") == 1 and (frame.get("ok") != 1 or out.get("ps_readback", {}).get("matches_guest_sum"))
           else "FAIL")
out["verdict"] = verdict
out["shield"] = res.get("shield")
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)
print("   board: %s (%s)   variant: %s   magic: %s" % (out["board"] or "UNREGISTERED",
      out["pynq_host"], out["variant"], out["soc_magic"]))
print("   shield present: %s   result ok: %s   verdict: %s" % (res.get("shield"), res.get("ok"), verdict))
print("   build %s: LUT %s, BRAM %s, WNS %s (worst over all clocks -- for this bitstream that is the"
      % (out["bitstream_md5"][:8], out["post_route"].get("lut"), out["post_route"].get("bram"),
         out["post_route"].get("wns")))
print("   camera input budget at 36 MHz, not the SoC clock: clk_fpga_0 is +1.126, CAMERA_Z1.md 7.5), WHS %s"
      % out["post_route"].get("whs"))
if res.get("shield") == 0:
    print("   no shield: the armed DMA transfer is left BUSY in COLLECT (this RTL has no abort).")
    print("   The next user needs to do NOTHING: every program load resets the SoC through")
    print("   soc_ctrl, and loading any bitstream clears it outright.")
for k in ("cam_regs_check", "cam_diag", "cam_i2c_probe", "cam_noshield", "cam_dma_timeout",
          "cam_sensor", "cam_mclk", "cam_stream", "cam_frame"):
    for d in out[k]:
        print("   %-16s %s" % (k, " ".join("%s=%s" % i for i in d.items())))
for k in ("cam_probe", "cam_geom", "cam_stats", "cam_move", "cam_frame2"):
    for d in out.get(k, []):
        print("   %-16s %s" % (k, " ".join("%s=%s" % i for i in d.items())))
if "ps_readback" in out:
    print("   ps readback: %s  -> frame.pgm" % out["ps_readback"])
if "ps_stats" in out:
    print("   PS-side statistics (independent of the guest): %s" % out["ps_stats"])
    print("   IS IT AN IMAGE? %s" % out["ps_stats_verdict"])
if "ps_line_padding" in out:
    lp = out["ps_line_padding"]
    print("   line padding: %d leading columns of %d are padding -> pixel width %d (body mean %s)"
          % (lp["pad_columns"], out["ps_stats"]["width"], lp["pixel_width"], lp["body_mean"]))
    print("     %s" % lp["leading_columns"])
if "ps_site_spread_by_region" in out:
    print("   Bayer-site spread by region (multiplicative => a colour filter array; constant => an offset):")
    for r in out["ps_site_spread_by_region"]:
        print("     band %s  mean %7.3f  site spread %6.3f  sites %s"
              % (r["band"], r["mean"], r["site_spread"], r["sites"]))
if "ps_readback2" in out:
    print("   ps readback 2: %s  -> frame2.pgm" % out["ps_readback2"])
if "frame_vs_frame2" in out:
    print("   frame vs frame2: %s" % out["frame_vs_frame2"])
print("   wrote %s" % os.path.join(run, "run.json"))
sys.exit(0 if verdict == "PASS" else 1)
PY
info "next: archive/tools/archive_run.py $NAME, then scripts/35_rocket_rgb_leds.sh (health check) in this session"
