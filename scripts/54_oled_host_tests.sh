#!/usr/bin/env bash
# OLED status screen, host side: no hardware, no RTL, no Chipyard tree.
#
#   scripts/54_oled_host_tests.sh              run and compare against expected/oled_status.json
#   scripts/54_oled_host_tests.sh --update     rewrite the golden hashes and init wire log from this run
#
# What runs (fpga/pynq-z2/docs/OLED_SSD1306.md section 7.1):
#   1. samples/oled_status/tests/host on native_sim/native/64 -- the STOCK ssd1306 driver and
#      CFB plus src/oled_status.c, over Zephyr's I2C emulator, into model/ssd1306_model.c:
#        - the probe + init byte stream, exactly and against the datasheet ordering
#          (charge pump 8D 14 before display on AF, AF last, COM pins 0x12, mux 63)
#        - the golden status screen and the test pattern, dumped as PGM and hashed here
#        - the bar-graph helper's geometry, and that posting never blocks
#        - a negative control: the same screen through a wire model of the stock
#          i2c_sifive reading must NOT hash to the golden
#   2. the same test built with CONFIG_OLED_TEST_ABSENT: nothing ACKs, the thread reports
#      "not fitted" once and never touches the bus again
#   3. the sample itself for chipyard_pynqz1_micrgb + oled.overlay, and Zephyr's hello_world
#      for the same board, to price the display stack from the linker map
#   4. samples/boot_info's URL layout (B181): the boot screen splits the attendee's instance
#      address across two rows so the digits get the tallest font, and the claim it rests on --
#      that splitting after the second dot fits EVERY IPv4 in the eight columns a 15 px font
#      gives on a 128 px panel -- is arithmetic over the whole address space, which no single
#      board can check.  samples/boot_info/src/aws_url.h is pure C for exactly this reason, so
#      the test compiles the code the glass runs.  Plain cc, no Zephyr, under a second.
#
# Outputs under out/oled_host/: console logs, status.pgm, pattern.pgm, stock_status.pgm,
# wire_*.txt, footprint.json. Images are NOT committed; their sha256 is (expected/).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

UPDATE=0
case "${1-}" in
  --update) UPDATE=1 ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"

S="$IISWC_ROOT/samples/oled_status"
OUT="$IISWC_OUT/oled_host"
EXP="$IISWC_ROOT/expected/oled_status.json"
rm -rf "$OUT"; mkdir -p "$OUT"

step "1/4  host test, display present  (native_sim/native/64)"
run west build -p always -b native_sim/native/64 "$S/tests/host" -d "$OUT/build_present" \
  > "$OUT/build_present.log" 2>&1 || { tail -30 "$OUT/build_present.log"; die "build failed"; }
"$OUT/build_present/zephyr/zephyr.exe" > "$OUT/present.log" 2>&1 || true
grep -q "SUITE PASS - 100.00% \[oled_present\]" "$OUT/present.log" \
  || { grep -E "FAIL|Assertion" "$OUT/present.log" | head -20; die "host test failed -- see $OUT/present.log"; }
info "$(grep -m1 'SUITE PASS' "$OUT/present.log")"
if [ "$UPDATE" = 1 ]; then
  python3 "$S/tools/oled_log2pgm.py" "$OUT/present.log" "$OUT" --expected "$EXP" --update
else
  python3 "$S/tools/oled_log2pgm.py" "$OUT/present.log" "$OUT" --expected "$EXP" \
    || die "rendered images or init wire log differ from $EXP"
  info "golden hashes and init wire sequence match $EXP"
fi

step "2/4  host test, display absent"
run west build -p always -b native_sim/native/64 "$S/tests/host" -d "$OUT/build_absent" \
  -- -DCONFIG_OLED_TEST_ABSENT=y > "$OUT/build_absent.log" 2>&1 \
  || { tail -30 "$OUT/build_absent.log"; die "build failed"; }
"$OUT/build_absent/zephyr/zephyr.exe" > "$OUT/absent.log" 2>&1 || true
grep -q "SUITE PASS - 100.00% \[oled_absent\]" "$OUT/absent.log" \
  || die "absent test failed -- see $OUT/absent.log"
info "$(grep -m1 'SUITE PASS' "$OUT/absent.log")"
info "$(grep -m1 '^oled:' "$OUT/absent.log")"

step "3/4  footprint on chipyard_pynqz1_micrgb"
run west build -p always -b chipyard_pynqz1_micrgb "$S" -d "$OUT/build_micrgb" -- \
  -DBOARD_ROOT="$IISWC_ROOT" -DEXTRA_DTC_OVERLAY_FILE="$S/oled.overlay" \
  > "$OUT/build_micrgb.log" 2>&1 || { tail -30 "$OUT/build_micrgb.log"; die "sample build failed"; }
run west build -p always -b chipyard_pynqz1_micrgb "$ZEPHYR_BASE/samples/hello_world" -d "$OUT/build_hello" -- \
  -DBOARD_ROOT="$IISWC_ROOT" > "$OUT/build_hello.log" 2>&1 || die "hello_world build failed"
grep -q '^CONFIG_I2C_SIFIVE=y' "$OUT/build_micrgb/zephyr/.config" || die "CONFIG_I2C_SIFIVE not set: &i2c0 did not match sifive,i2c0"
grep -q '^CONFIG_SSD1306=y' "$OUT/build_micrgb/zephyr/.config" || die "CONFIG_SSD1306 not set"
python3 "$S/tools/footprint.py" "$OUT/build_micrgb" --baseline "$OUT/build_hello" --json "$OUT/footprint.json" \
  | sed 's/^/    /'
info "zephyr.bin: sample $(stat -c %s "$OUT/build_micrgb/zephyr/zephyr.bin") bytes, hello_world $(stat -c %s "$OUT/build_hello/zephyr/zephyr.bin") bytes"

step "4/4  boot_info URL layout over the whole IPv4 space (B181)"
BI="$IISWC_ROOT/samples/boot_info"
run cc -Wall -Wextra -Werror -o "$OUT/aws_url_test" "$BI/tests/aws_url_test.c" -I "$BI/src"
"$OUT/aws_url_test" > "$OUT/aws_url_test.log" 2>&1 \
  || { sed -n '/FAIL/p' "$OUT/aws_url_test.log" | head -20; die "URL layout test failed -- see $OUT/aws_url_test.log"; }
grep -q "AUT DONE fails=0" "$OUT/aws_url_test.log" \
  || die "URL layout test did not reach its own verdict -- see $OUT/aws_url_test.log"
sed -n 's/^AUT OK   /    /p' "$OUT/aws_url_test.log"

info "PASS"
