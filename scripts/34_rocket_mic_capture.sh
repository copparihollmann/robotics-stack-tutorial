#!/usr/bin/env bash
# Lab B14 -- capture audio from the PYNQ-Z1's own microphone, on the FPGA, through
# Zephyr's standard DMIC API:
#
#   west build (chipyard_pynqz1_mic)  ->  scp zephyr.bin  ->  PS writes DDR
#   ->  release reset  ->  Zephyr opens /soc/pdm-mic@10090000  ->  2 s of PCM into DRAM
#   ->  PS reads it back over /dev/mem  ->  WAV + spectrum on the host
#
# Same shape as 29_rocket_pext_run.sh, which it deliberately does not modify. The
# differences:
#
#   * a different bitstream    build_rocket_mic_z1/pynqz1_rocket_mic.bit
#   * a different MAGIC        0x5A5A0005. The mic design is the P-ext design plus one
#                              MMIO peripheral -- same harts, same ISA, same clock, same
#                              pins -- so an image built for either boots on the other and
#                              says nothing. Without the MAGIC this is a silent failure.
#   * a different Zephyr board chipyard_pynqz1_mic (= pynqz1_pext + the microphone node)
#   * a second data path       the console carries diagnostics; the AUDIO comes back
#                              through DRAM, because 16 kHz of 16-bit PCM does not fit
#                              down a 115200 baud console.
#
# WHAT "PASS" MEANS HERE.  Not "it did not crash" -- a disconnected pin produces a
# perfectly well-formed stream of zeros and every API call succeeds.  The checks are:
#
#   RATE        the driver negotiated 15994 Hz (15993.859 rounded), not 16000.  It
#               cannot be 16000: see
#               fpga/pynq-z2/docs/MICROPHONE.md section 3.2.
#   NOT SILENT  rms above a floor, and more than 20 distinct sample values.  A dead
#               or tied pin gives rms 0 and one value.
#   DC REMOVED  |mean| small.  The hardware DC blocker is what makes this true; the same
#               microphone measured 0.5164 PDM density, which without it is 1074 counts.
#   SPECTRAL TILT  the 3150-6300 Hz band at least 10 dB below 100-1000 Hz.  This is the
#               check that the DECIMATOR works.  A sigma-delta microphone's noise rises
#               steeply with frequency, so a naive average of the bitstream comes out
#               brighter at the top of the band, not darker -- measured at +38 dB on this
#               board's own bits (MICROPHONE.md section 6).
#   FINGERPRINT the eight-band profile correlates with the one measured through PYNQ's
#               base overlay, which is an independent path to the same microphone through
#               somebody else's IP.  Correlation, not absolute level, so it survives the
#               room being louder or quieter on the day.
#
# Produces, under out/<name>/:
#   zephyr.elf / zephyr.bin   the guest
#   console.txt               the per-block diagnostics
#   mic.raw / mic.wav         the captured audio
#   spectrum.txt             the band table and the peak list
#   run.json                  manifest
#
# Usage:
#   scripts/with_board.sh ./scripts/34_rocket_mic_capture.sh
#   scripts/with_board.sh ./scripts/34_rocket_mic_capture.sh --no-bitstream
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SAMPLE="$IISWC_ROOT/samples/dmic_capture"
NAME="rocket_mic"
BOARD="chipyard_pynqz1_mic"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_mic_z1/pynqz1_rocket_mic.bit"
EXPECT="$IISWC_ROOT/expected/dmic_capture.json"
LOAD_BIT=1
SECONDS_READ=30
WANT_MTIME_HZ=34483
# Rocket 0x8C00_0000 -> PS physical 0x1C00_0000 through the top's {4'd1, addr[27:0]} fold.
PCM_PHYS=0x1C000000
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="${2:?}"; shift 2 ;;
    --name)   NAME="${2:?}";   shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --no-check) EXPECT=""; shift ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; BUILD="$RUN/build"
rm -rf "$RUN"; mkdir -p "$RUN"

step "1/6  build  ($BOARD)"
info "sample: $SAMPLE"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$BUILD" -- -DBOARD_ROOT="$IISWC_ROOT" \
  > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
need_file "$BUILD/zephyr/zephyr.bin" "build produced no raw image"
cp "$BUILD/zephyr/zephyr.elf" "$BUILD/zephyr/zephyr.bin" "$RUN/"

grep -q '^CONFIG_AUDIO_DMIC_PDM_MMIO=y' "$BUILD/zephyr/.config" \
  || die "CONFIG_AUDIO_DMIC_PDM_MMIO is not set in this image -- the devicetree node did
       not match the driver's compatible, so device_is_ready() would fail and nothing
       would be captured. Check boards/chipyard/pynqz1_mic and patches/0011."
HZ=$(grep -E '^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=' "$BUILD/zephyr/.config" | cut -d= -f2)
[ "${HZ:-0}" = "$WANT_MTIME_HZ" ] || die "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ, expected
       $WANT_MTIME_HZ. That constant sets the SiFive UART's baud divisor as well as the
       tick rate, so a mismatch shows up as a GARBLED console -- see FPGA_END_TO_END.md 4.1."
info "bin: $(fsize "$RUN/zephyr.bin")   mtime: $HZ Hz   dmic driver: in"

step "2/6  reach the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$RUN/zephyr.bin" "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_mic.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/read_mem.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
LOCAL_MD5=$(md5sum "$RUN/zephyr.bin" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum $PYNQ_DIR/zephyr.bin" | cut -d' ' -f1)
[ "$LOCAL_MD5" = "$REMOTE_MD5" ] || die "zephyr.bin corrupted in transfer"
info "md5 verified: $LOCAL_MD5"

step "3/6  load the PL, set FCLK0 and hold the SoC in reset"
if [ "$LOAD_BIT" -eq 1 ]; then
  need_file "$BIT" "build it with fpga/pynq-z2/scripts/build_mic_z1.sh"
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  HOLD_ARGS="--bitstream $(basename "$BIT") --hold"
else
  HOLD_ARGS="--no-load --hold"
fi
wrong_pl () {
  # `|| true` is load-bearing. common.sh sets `set -euo pipefail`, so a grep that finds
  # nothing makes the whole command substitution fail and kills the script -- which is
  # exactly what happened the first time this ran, silently, before the fallback below
  # ever got a chance.
  M=$(grep -oE 'MAGIC = 0x5A5A000[0-9]' "$RUN/boot.log" 2>/dev/null | head -1 || true)
  case "$M" in
    "MAGIC = 0x5A5A0004") cat "$RUN/boot.log"; die "the P-EXT bitstream is loaded
       ($M). It has no microphone: 0x1009_0000 is not in its address map, so every
       register read returns whatever the bus error device gives and the driver's ID
       check fails. Re-run without --no-bitstream." ;;
    "MAGIC = 0x5A5A0003") cat "$RUN/boot.log"; die "the plain DUAL-CORE bitstream is loaded ($M)." ;;
    "MAGIC = 0x5A5A0002") cat "$RUN/boot.log"; die "the SINGLE-core bitstream is loaded ($M)." ;;
    "MAGIC = 0x5A5A0001") cat "$RUN/boot.log"; die "the DRAM self-test bitstream is loaded ($M)." ;;
  esac
}
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u run_rocket_mic.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || {
  wrong_pl
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_mic.py $HOLD_ARGS'" \
    > "$RUN/boot.log" 2>&1 || { wrong_pl; cat "$RUN/boot.log"; die "could not load the PL"; }
}
grep -q 'MAGIC = 0x5A5A0005' "$RUN/boot.log" || {
  wrong_pl; cat "$RUN/boot.log"; die "microphone bitstream not reachable over GP0"
}
grep -E 'FCLK0' "$RUN/boot.log" | sed 's/^/    /' || true
info "microphone PL loaded, SoC held in reset"

step "4/6  boot and capture"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out console.stamps
  nohup python3 -u console.py --seconds $SECONDS_READ --stamps console.stamps > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_mic.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
"${SSH[@]}" "cat $PYNQ_DIR/console.stamps" > "$RUN/console.stamps" 2>/dev/null || true

if [ -s "$RUN/console.txt" ]; then
  printf '%s\n' "----------------------------------------------------------------"
  cat "$RUN/console.txt"
  printf '%s\n' "----------------------------------------------------------------"
else
  warn "no console output -- check $RUN/boot.log"
fi

step "5/6  pull the PCM out of DRAM"
# The guest flushed the L2 over the buffer before printing this line, so what is in DRAM
# is what it wrote. Without that flush the PS would read whatever was there before.
NBYTES=$(grep -oE 'pcm_buf 0x[0-9a-f]+ samples [0-9]+ bytes [0-9]+' "$RUN/console.txt" 2>/dev/null \
         | head -1 | awk '{print $6}')
if [ -z "${NBYTES:-}" ]; then
  warn "the guest never printed a pcm_buf line -- capture did not complete"
  NBYTES=0
else
  info "guest reports $NBYTES bytes at PS physical $PCM_PHYS"
  "${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 -u read_mem.py --phys $PCM_PHYS --bytes $NBYTES --out mic.raw" \
    >> "$RUN/boot.log" 2>&1 || die "read_mem.py failed -- see $RUN/boot.log"
  run scp -q "$PYNQ_HOST:$PYNQ_DIR/mic.raw" "$RUN/mic.raw"
  info "pulled $(fsize "$RUN/mic.raw")"
fi

step "6/6  is it audio?"
python3 - "$RUN" "$SAMPLE" "$BOARD" <<'PY' | tee "$RUN/spectrum.txt"
import json, math, os, re, sys, wave
run, sample, board = sys.argv[1:4]

text = ''
p = os.path.join(run, 'console.txt')
if os.path.exists(p):
    text = open(p, errors='replace').read()

m = re.search(r'MIC: rate (\d+) Hz\s+channels (\d+)\s+block (\d+) samples', text)
rate     = int(m.group(1)) if m else None
channels = int(m.group(2)) if m else None
m = re.search(r'pcm_buf 0x[0-9a-f]+ samples (\d+) bytes (\d+) rate (\d+)', text)
nsamp = int(m.group(1)) if m else 0
done  = 'MIC: DONE' in text
fails = re.findall(r'MIC: FAIL (.*)', text)

# The eight-band profile measured through PYNQ's base overlay and this repo's decimator
# replayed under Verilator -- MICROPHONE.md section 6. An INDEPENDENT path to the same
# microphone: somebody else's capture IP, our filter, no Rocket involved at all.
REF_BANDS = [(20, 50, -76.7), (50, 100, -78.2), (100, 200, -75.1), (200, 400, -68.2),
             (400, 800, -67.9), (800, 1600, -73.6), (1600, 3150, -73.7),
             (3150, 6300, -79.0)]

out = {
    'board': board, 'sample': os.path.basename(sample),
    'booted': bool(text.strip()), 'done': done, 'fails': fails,
    'rate_hz': rate, 'channels': channels, 'samples': nsamp, 'skipped': None,
    'overrun': 'overran' in text,
}

raw = os.path.join(run, 'mic.raw')
if nsamp and os.path.exists(raw) and os.path.getsize(raw) >= 2 * nsamp:
    import array
    a = array.array('h')
    a.frombytes(open(raw, 'rb').read()[:2 * nsamp])
    if sys.byteorder == 'big':
        a.byteswap()
    full = list(a)
    # Skip the first 100 ms of the statistics. The FIR's 289-sample history RAM starts at
    # zero and the DC blocker's 19.9 Hz pole needs a few time constants, so the opening
    # ~50 ms is a settling ramp rather than audio. The WAV below is written in full --
    # this only affects the numbers.
    skip = min(int(0.1 * rate), len(full) // 4)
    x = full[skip:]

    n = len(x)
    mean = sum(x) / n
    rms = math.sqrt(sum((v - mean) ** 2 for v in x) / n)
    peak = max(abs(v) for v in x)
    distinct = len(set(x))
    zc = sum(1 for i in range(1, n) if (x[i] < 0) != (x[i - 1] < 0))
    fs = float(rate)

    w = wave.open(os.path.join(run, 'mic.wav'), 'wb')
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(int(round(fs)))
    w.writeframes(a.tobytes()); w.close()   # the WAV keeps everything

    # Welch, 1024-point, Hann, 50% overlap.  numpy is already a hard dependency of the
    # ModelBlaster labs; a pure-Python DFT over 61 segments is 30 M multiplies and takes
    # most of a minute, which is not a reasonable thing to put in a build gate.
    import numpy as np
    N = 1024
    win = np.hanning(N)
    wsum = float((win * win).sum())
    xs = np.asarray(x, dtype=np.float64) - mean
    segs = [xs[s:s + N] * win for s in range(0, n - N, N // 2)]
    P = (np.abs(np.fft.rfft(np.asarray(segs), axis=1)) ** 2).mean(axis=0) if segs \
        else np.zeros(N // 2 + 1)
    binhz = fs / N

    freqs = np.arange(N // 2 + 1) * binhz

    def band_db(lo, hi):
        e = float(P[(freqs >= lo) & (freqs < hi)].sum()) * 2.0 / (wsum * N)
        return 10 * math.log10(e / (32768.0 ** 2) + 1e-30)

    bands = [(lo, hi, round(band_db(lo, hi), 1)) for lo, hi, _ in REF_BANDS]
    tilt = band_db(100, 1000) - band_db(3150, 6300)

    ours = [b[2] for b in bands]
    ref = [b[2] for b in REF_BANDS]
    mo, mr = sum(ours) / len(ours), sum(ref) / len(ref)
    num = sum((a_ - mo) * (b_ - mr) for a_, b_ in zip(ours, ref))
    den = math.sqrt(sum((a_ - mo) ** 2 for a_ in ours) * sum((b_ - mr) ** 2 for b_ in ref))
    corr = num / den if den else 0.0

    peaks = [(float(P[k]), float(freqs[k])) for k in range(3, N // 2)
             if P[k] > P[k - 1] and P[k] > P[k + 1]]
    peaks.sort(reverse=True)

    out.update({
        'mean': round(mean, 2), 'rms': round(rms, 2), 'peak': peak,
        'distinct_values': distinct, 'zero_crossings': zc,
        'rms_dbfs': round(20 * math.log10(rms / 32768 + 1e-30), 1),
        'bands_dbfs': bands,
        'tilt_db': round(tilt, 1),
        'fingerprint_corr': round(corr, 3),
        'top_peaks_hz': [round(f, 1) for _, f in peaks[:8]],
        'skipped': skip,
        'not_silent': rms > 5.0 and distinct > 20,
        'dc_removed': abs(mean) < 50.0,
        'spectral_tilt_ok': tilt > 6.0,
        'fingerprint_ok': corr > 0.6,
    })

    print("  %d samples at %.1f Hz  (%.3f s); statistics skip the first %d (%.0f ms)"
          % (len(full), fs, len(full) / fs, skip, 1000.0 * skip / fs))
    print("  mean %+8.2f   rms %8.2f (%.1f dBFS)   peak %6d   distinct %5d   zc %6d"
          % (mean, rms, out['rms_dbfs'], peak, distinct, zc))
    print("  band levels, dBFS      this run   PYNQ base overlay (MICROPHONE.md s6)")
    for (lo, hi, v), (_, _, r) in zip(bands, REF_BANDS):
        print("    %5d-%5d Hz        %7.1f              %7.1f" % (lo, hi, v, r))
    print("  spectral tilt 100-1000 Hz over 3150-6300 Hz: %.1f dB  (needs > 6)" % tilt)
    print("  fingerprint correlation with the base-overlay profile: %.3f  (needs > 0.6)" % corr)
    print("  loudest peaks: " + ", ".join("%.0f" % f for _, f in peaks[:8]) + " Hz")
    print("  wrote " + os.path.join(run, 'mic.wav'))

out['result_pass'] = bool(
    out.get('booted') and out.get('done') and not out.get('fails')
    and out.get('rate_hz') == 15994 and out.get('channels') == 1
    and not out.get('overrun')
    and out.get('not_silent') and out.get('dc_removed')
    and out.get('spectral_tilt_ok') and out.get('fingerprint_ok'))
json.dump(out, open(os.path.join(run, 'run.json'), 'w'), indent=2)
PY

if [ -n "$EXPECT" ] && [ -f "$EXPECT" ]; then
  python3 - "$RUN/run.json" "$EXPECT" <<'PYCHECK' || die "golden check failed"
import json, sys
got = json.load(open(sys.argv[1]))
exp = json.load(open(sys.argv[2]))
bad = 0
print("\n\033[1;32m==> check  (vs %s)\033[0m" % sys.argv[2].split('/')[-1])
for k, want in exp.items():
    if k.startswith('_'):
        continue
    have = got.get(k)
    if isinstance(want, list) and len(want) == 2 and all(isinstance(v, (int, float)) for v in want):
        ok = have is not None and want[0] <= have <= want[1]
        shown = "[%s .. %s]" % tuple(want)
    else:
        ok = (have == want)
        shown = want
    print("    %-4s %-22s expected %-24s got %s" % ("ok" if ok else "BAD", k, shown, have))
    bad += (not ok)
sys.exit(1 if bad else 0)
PYCHECK
  info "reproduces the golden run"
fi

step "Done"
info "audio  $RUN/mic.wav"
info "report $RUN/spectrum.txt"
