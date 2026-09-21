#!/usr/bin/env bash
# Read the card back and compare it against the source image.
#
#   ./verify_card.sh /dev/sdX pynq_z1_v3.1.1.zip
#
# Compares only the first N bytes -- the length of the decompressed image -- because the
# card is larger than the image and everything past the end is whatever was there before.
set -euo pipefail
DEV=${1:?usage: verify_card.sh /dev/sdX <image.zip>}
IMG=${2:?usage: verify_card.sh /dev/sdX <image.zip>}

echo "measuring the decompressed image..."
N=$(unzip -p "$IMG" | wc -c)
echo "  $N bytes"
echo "hashing the source image..."
A=$(unzip -p "$IMG" | sha256sum | cut -d' ' -f1)
echo "  source: $A"
echo "hashing the first $N bytes of $DEV..."
B=$(sudo dd if="$DEV" bs=4M iflag=fullblock 2>/dev/null | head -c "$N" | sha256sum | cut -d' ' -f1)
echo "  card:   $B"
[ "$A" = "$B" ] && echo "VERIFY: MATCH" || { echo "VERIFY: MISMATCH"; exit 1; }
