# SD card preparation

The image itself is ~1.9 GB and is not in this repo. Download it from AMD:

```
https://www.pynq.io/boards.html   ->  PYNQ-Z1 v3.1.1   (pynq_z1_v3.1.1.zip)
```

Get the **Z1** image, not the Z2 one. They are different boards despite the identical
XC7Z020 part — different DDR timing (`T_RCD` 7 vs 13.125 ns), different peripherals, and
different board files.

```bash
lsblk -o NAME,SIZE,RM,TRAN,MODEL,MOUNTPOINT     # find the card FIRST
./write_card.sh  /dev/sdX pynq_z1_v3.1.1.zip
./verify_card.sh /dev/sdX pynq_z1_v3.1.1.zip    # -> VERIFY: MATCH
```

`write_card.sh` refuses any target that is not removable, USB-attached, 8-200 GB and
unmounted. That guard exists because on a shared build host the internal drives appear in
the same device list as the card reader, and `dd` gives no second chance.

> **The stock image ships a GitHub personal access token in cleartext in `/boot/REVISION`.**
> Blank that file before handing identical cards to attendees.

## After first boot

Apply the boot-time changes with `../boot-patches/patch_boot_dtb.sh` — see that directory's
README. They are what give you `/dev/ttyPS1`, the reserved memory region, and a watchdog
that can recover the board from a PL-induced lock.

## Before more than one card goes on the same network

Six things are byte-identical on every card written from this image, and all six stop being
harmless the moment two boards share a segment: the hostname (`pynq`), the absence of any
MAC address in hardware (the kernel invents a **random** one every boot), the static
`192.168.2.99` alias, `/etc/machine-id`, the SSH host keys — which ship **inside the
image**, so every PYNQ v3.1.1 card in the world has the same ones — and a root Jupyter on
`:9090` with the stock password.

```bash
sudo ./per_board_setup.sh 13 --dry-run     # ON THE BOARD; shows what it would change
sudo ./per_board_setup.sh 13               # then reboot
```

**How much of this you need depends on the topology.** If each laptop connects straight to
its own board (the recommendation — `../docs/TUTORIAL_NETWORKING.md` §2.3), no two boards
share a broadcast domain: the random MAC, the duplicate `192.168.2.99` and the shared host
keys all stop mattering, and the per-card work drops to **nothing** — the token scrub, the
Jupyter password and a fresh `machine-id` are single edits to the *master image*. Run this
script per card only if the boards are going onto a shared network.

It refuses to run anywhere but a PYNQ board, it is idempotent, and it prints the new host
key fingerprints for the `known_hosts` file you ship to attendees.
`../docs/TUTORIAL_NETWORKING.md` §5 is the reasoning; §5.6 and §8.5 cover the two things
the script deliberately does **not** do (the Jupyter password and the SSH authorized_keys),
because they belong in the master image rather than per card.
