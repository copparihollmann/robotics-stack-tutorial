#!/usr/bin/env bash
# Write a PYNQ image to an SD card, with a guard that refuses anything that is not a
# removable USB device of plausible size.
#
#   ./write_card.sh /dev/sdX pynq_z1_v3.1.1.zip
#
# THE GUARD IS THE POINT. `dd` to the wrong node destroys a disk with no confirmation, and
# on a shared build host the internal drives sit right next to the card reader in the
# device list. This refuses to write unless the target is removable (RM=1), attached over
# USB (TRAN=usb), between 8 GB and 200 GB, and not mounted. Do not remove these checks;
# pass the right device instead.
set -euo pipefail

DEV=${1:?usage: write_card.sh /dev/sdX <image.zip|image.img>}
IMG=${2:?usage: write_card.sh /dev/sdX <image.zip|image.img>}
[ -b "$DEV" ] || { echo "ABORT: $DEV is not a block device"; exit 1; }
[ -f "$IMG" ] || { echo "ABORT: no such image: $IMG"; exit 1; }

RM=$(lsblk -ndo RM   "$DEV" | tr -d ' ')
TRAN=$(lsblk -ndo TRAN "$DEV" | tr -d ' ')
SZ=$(lsblk -ndbo SIZE "$DEV" | tr -d ' ')
MODEL=$(lsblk -ndo MODEL "$DEV" | sed 's/ *$//')
echo "target: $DEV  ($MODEL, $((SZ/1000000000)) GB, removable=$RM transport=$TRAN)"

[ "$RM" = "1" ] && [ "$TRAN" = "usb" ] && [ "$SZ" -gt 8000000000 ] && [ "$SZ" -lt 200000000000 ] \
  || { echo "ABORT: guard failed (RM=$RM TRAN=$TRAN SIZE=$SZ) -- is $DEV really the card?"; exit 1; }
if mount | grep -q "^$DEV"; then
  echo "ABORT: $DEV has mounted partitions; unmount them first"; exit 1
fi

echo "writing $IMG -> $DEV"
case "$IMG" in
  *.zip) unzip -p "$IMG" | sudo dd of="$DEV" bs=4M status=progress conv=fsync ;;
  *)     sudo dd if="$IMG" of="$DEV" bs=4M status=progress conv=fsync ;;
esac
sync
sudo blockdev --rereadpt "$DEV" 2>/dev/null || sudo partprobe "$DEV" 2>/dev/null || true
echo "WRITE_COMPLETE -- verify with ./verify_card.sh $DEV $IMG"
