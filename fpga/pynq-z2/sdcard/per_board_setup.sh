#!/usr/bin/env bash
# Prepare a PYNQ-Z1 card so that a room of them cloned from one master image can be used
# at a tutorial.  See fpga/pynq-z2/docs/BRINGUP.md 5 and 6.5.
#
#   RUNS ON THE BOARD, AS ROOT.  It refuses to run anywhere else.
#
# TWO MODES, because how much work there is depends entirely on the topology.
#
#   --direct     Topology E -- one laptop, one cable, one board (the RECOMMENDED one).
#                No two boards share a broadcast domain, so every card is IDENTICAL:
#                static 192.168.2.99 (the stock PYNQ image alias) and a DHCP server
#                on eth0 handing the laptop an address with NO default route, so the
#                laptop keeps its WiFi and its internet.  Run this ONCE on the master
#                image, before cloning.  There is no per-card step.
#
#   <board-number>   Topologies A/B -- every board on one shared network.  Then the cards
#                must differ, and this gives card N its own hostname, MAC, address, host
#                keys and machine-id.  Run it per card, after cloning.
#
#     sudo ./per_board_setup.sh --direct --dry-run
#     sudo ./per_board_setup.sh --direct
#     sudo ./per_board_setup.sh 13                    # shared-network mode
#
#   scp per_board_setup.sh xilinx@<board>:/tmp/ && ssh -t xilinx@<board> \
#       'sudo bash /tmp/per_board_setup.sh --direct'
#   (do NOT pipe it into `sudo bash -s` over ssh: sudo's prompt eats it off the same stdin)
#
# What it fixes, all identical on every card written from the stock pynq_z1_v3.1.1 image:
#
#   1. hostname          every card is "pynq"                    (shared-network mode only)
#   2. MAC address       the PS GEM has none; the kernel invents a RANDOM one every boot,
#                        so nothing -- DHCP reservations included -- can key on it
#                                                                 (shared-network mode only)
#   3. addressing        every card brings up a static alias on 192.168.2.99
#   4. machine-id        baked into the image, identical everywhere
#   5. SSH host keys     shipped IN the image; every card is impersonable by every other
#   6. /boot/REVISION    ships a GitHub personal access token in cleartext
#
# It is idempotent, it prints what it changed, and it does NOT reboot.
set -euo pipefail

SUBNET="10.42.0"          # shared-network mode: boards get $SUBNET.$NN
GW=""                     # default: $SUBNET.1
PREFIX="pynq"             # hostname becomes $PREFIX-$NN
MACBASE="02:11:5C:00:00"  # locally-administered; last octet is $NN in hex
DIRECT_IP="192.168.2.99"  # --direct: the alias every stock PYNQ card brings up
DIRECT_POOL_LO="192.168.2.100"
DIRECT_POOL_HI="192.168.2.120"
DIRECT=0
DRYRUN=0

die() { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()  { printf '    ok    %s\n' "$*"; }
chg() { printf '    \033[33mset\033[0m   %s\n' "$*"; }
skip(){ printf '    --    %s\n' "$*"; }
run() { if [ "$DRYRUN" = 1 ]; then printf '    would: %s\n' "$*"; else eval "$@"; fi; }
wr()  { # wr <path> <<<content on stdin
  if [ "$DRYRUN" = 1 ]; then cat >/dev/null; printf '    would: write %s\n' "$1"
  else cat > "$1"; fi; }

ARGV="$*"
NN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --direct|--point-to-point) DIRECT=1; shift;;
    --subnet) SUBNET="$2"; shift 2;;
    --gateway|--gw) GW="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --mac-base) MACBASE="$2"; shift 2;;
    --direct-ip) DIRECT_IP="$2"; shift 2;;
    -n|--dry-run) DRYRUN=1; shift;;
    -h|--help) sed -n '2,32p' "$0"; exit 0;;
    -*) die "unknown option: $1";;
    *) [ -z "$NN" ] || die "give exactly one board number"; NN="$1"; shift;;
  esac
done

if [ "$DIRECT" = 1 ]; then
  [ -z "$NN" ] || die "--direct configures every card identically; do not give a board number"
else
  [ -n "$NN" ] || die "usage: $0 --direct   |   $0 <board-number>   (see --help)"
  case "$NN" in ''|*[!0-9]*) die "board number must be decimal: got '$NN'";; esac
  NN=$((10#$NN))   # strip leading zeros: printf '%02X' 08 would otherwise be an octal error
  [ "$NN" -ge 2 ] && [ "$NN" -le 250 ] || die "board number must be 2..250 (it is the host octet)"
  [ -n "$GW" ] || GW="$SUBNET.1"
fi

# ---- refuse to run anywhere but a PYNQ board -------------------------------------------
# This rewrites /etc/network, /etc/dhcp, /etc/hostname, /etc/machine-id and /etc/ssh.
# Running it on a workstation by accident would be memorable.  Four independent checks.
[ "$(id -u)" = 0 ]                     || die "must run as root (sudo $0 $ARGV)"
uname -r | grep -q xilinx              || die "not a Xilinx kernel ($(uname -r)) -- this must run ON the board"
[ -x /usr/local/bin/pynq_hostname.sh ] || die "no /usr/local/bin/pynq_hostname.sh -- this does not look like a PYNQ image"
[ -f /boot/REVISION ]                  || die "no /boot/REVISION -- this does not look like a PYNQ image"

IFFILE=/etc/network/interfaces.d/eth0
KREL="$(uname -r)"
printf '\n'
if [ "$DIRECT" = 1 ]; then
  say "TOPOLOGY E (--direct): identical on every card   $DIRECT_IP + dhcpd on eth0   (kernel $KREL)"
else
  HOST="$PREFIX-$NN"; IP="$SUBNET.$NN"; MAC="$MACBASE:$(printf '%02X' "$NN")"
  say "SHARED NETWORK: board $NN -> $HOST   $IP   $MAC   (kernel $KREL)"
fi
[ "$DRYRUN" = 1 ] && printf '    (dry run -- nothing will be written)\n'
printf '\n'

# ---- 1. hostname -----------------------------------------------------------------------
say "1/7  hostname"
if [ "$DIRECT" = 1 ]; then
  skip "left as '$(cat /etc/hostname)' -- with one board per link, names do not have to be unique"
elif [ "$(cat /etc/hostname)" = "$HOST" ]; then
  ok "already $HOST"
else
  run "/usr/local/bin/pynq_hostname.sh '$HOST' >/dev/null"
  chg "/etc/hostname and /etc/hosts -> $HOST  (full effect after reboot)"
fi

# ---- 2. MAC address --------------------------------------------------------------------
# The device tree carries no local-mac-address, so macb logs "invalid hw address, using
# random" and picks a new one on EVERY boot.  udev applies no .link file on this image
# (measured: udevadm reports no ID_NET_* properties at all), so pin it BOTH ways.
say "2/7  MAC address"
CUR_MAC="$(cat /sys/class/net/eth0/address 2>/dev/null || echo '?')"
ASSIGN="$(cat /sys/class/net/eth0/addr_assign_type 2>/dev/null || echo '?')"
printf '    now:  %s  (addr_assign_type=%s; 1 = randomly generated)\n' "$CUR_MAC" "$ASSIGN"
if [ "$DIRECT" = 1 ]; then
  skip "not pinned -- nothing on a point-to-point link keys on the MAC"
else
  LINKFILE=/etc/systemd/network/10-eth0.link
  if [ -f "$LINKFILE" ] && grep -qi "MACAddress=$MAC" "$LINKFILE"; then
    ok "$LINKFILE already pins $MAC"
  else
    run "mkdir -p /etc/systemd/network"
    wr "$LINKFILE" <<EOF
# Written by fpga/pynq-z2/sdcard/per_board_setup.sh -- docs/TUTORIAL_NETWORKING.md 5.1
# The Zynq PS GEM has no MAC in hardware and the device tree supplies none, so without
# this the kernel generates a fresh random address on every boot.
[Match]
OriginalName=eth0

[Link]
MACAddress=$MAC
NamePolicy=keep kernel
EOF
    [ "$DRYRUN" = 1 ] || chg "$LINKFILE -> $MAC  (udev, at next boot)"
  fi
fi

# ---- 3. addressing ---------------------------------------------------------------------
# Stock file is: eth0 dhcp, PLUS a static alias eth0:1 at 192.168.2.99 that every board in
# the world answers ARP for.  Replace the whole file either way.
say "3/7  addressing"
if [ "$DIRECT" = 1 ]; then
  if [ -f "$IFFILE" ] && grep -q "address $DIRECT_IP\$" "$IFFILE" && ! grep -q 'eth0:1' "$IFFILE"; then
    ok "$IFFILE already static $DIRECT_IP with no alias"
  else
    [ "$DRYRUN" = 1 ] || { [ -f "$IFFILE.orig" ] || cp -a "$IFFILE" "$IFFILE.orig"; }
    wr "$IFFILE" <<EOF
# Written by fpga/pynq-z2/sdcard/per_board_setup.sh -- docs/TUTORIAL_NETWORKING.md 6.5
# Topology E: one laptop, one cable, one board.  Nothing is shared, so this address is
# unique on this link by construction -- and it is what env.sh's PYNQ_HOST already says.
auto eth0
iface eth0 inet static
    address $DIRECT_IP
    netmask 255.255.255.0
EOF
    [ "$DRYRUN" = 1 ] || chg "$IFFILE -> static $DIRECT_IP/24, no gateway, no alias"
  fi
  # staged fallback so a board can be moved onto the rescue island by a copy, not an edit
  if [ -f "$IFFILE.island" ]; then ok "$IFFILE.island already staged"; else
    wr "$IFFILE.island" <<'EOF'
# Copy over interfaces.d/eth0 to put this board on a shared router instead.
# FIRST: sudo systemctl stop isc-dhcp-server   -- see docs/TUTORIAL_NETWORKING.md 6.8
auto eth0
iface eth0 inet dhcp
EOF
    [ "$DRYRUN" = 1 ] || chg "$IFFILE.island staged (rescue-kit fallback)"
  fi
else
  if [ -f "$IFFILE" ] && grep -q "address $IP\$" "$IFFILE" \
     && grep -qi "hwaddress ether $MAC\$" "$IFFILE" && ! grep -q '192\.168\.2\.99' "$IFFILE"; then
    ok "$IFFILE already static $IP + hwaddress $MAC, no .99 alias"
  else
    grep -q '192\.168\.2\.99' "$IFFILE" 2>/dev/null && printf '    dropping the shared 192.168.2.99 alias\n'
    [ "$DRYRUN" = 1 ] || { [ -f "$IFFILE.orig" ] || cp -a "$IFFILE" "$IFFILE.orig"; }
    wr "$IFFILE" <<EOF
# Written by fpga/pynq-z2/sdcard/per_board_setup.sh -- docs/TUTORIAL_NETWORKING.md 5.2
# Static, not DHCP: the hardware has no stable MAC, so a reservation has nothing to key on,
# and a static board does not need the router to be alive to have the right address.
# hwaddress is the belt to 10-eth0.link's braces -- .link does not fire on this image.
auto eth0
iface eth0 inet static
    address $IP
    netmask 255.255.255.0
    gateway $GW
    dns-nameservers $GW
    hwaddress ether $MAC
EOF
    [ "$DRYRUN" = 1 ] || chg "$IFFILE -> static $IP/24 gw $GW, hwaddress $MAC (orig kept as $IFFILE.orig)"
  fi
fi
[ "$DRYRUN" = 1 ] || printf '    \033[33mnote\033[0m  live only after a reboot; a network session will drop then.\n'

# ---- 4. the DHCP server (--direct only) ------------------------------------------------
# isc-dhcp-server ships installed AND enabled on the stock image, and fails at every boot
# because INTERFACESv4="" and dhcpd.conf declares no subnet.  A config file, not a package.
say "4/7  DHCP server on eth0"
if [ "$DIRECT" = 1 ]; then
  [ -x /usr/sbin/dhcpd ] || die "/usr/sbin/dhcpd missing -- expected isc-dhcp-server on the stock image"
  if grep -q "range $DIRECT_POOL_LO" /etc/dhcp/dhcpd.conf 2>/dev/null \
     && grep -q '^INTERFACESv4="eth0"' /etc/default/isc-dhcp-server 2>/dev/null; then
    ok "already serving $DIRECT_POOL_LO-$DIRECT_POOL_HI on eth0"
  else
    [ "$DRYRUN" = 1 ] || { [ -f /etc/dhcp/dhcpd.conf.orig ] || cp -a /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.orig; }
    NET="$(printf '%s' "$DIRECT_IP" | cut -d. -f1-3)"
    wr /etc/dhcp/dhcpd.conf <<EOF
# Written by fpga/pynq-z2/sdcard/per_board_setup.sh -- docs/TUTORIAL_NETWORKING.md 6.5
default-lease-time 3600;
max-lease-time 7200;
ddns-update-style none;
authoritative;

subnet $NET.0 netmask 255.255.255.0 {
    range $DIRECT_POOL_LO $DIRECT_POOL_HI;
    # DELIBERATELY no "option routers" and no "option domain-name-servers".
    # With neither, the laptop installs NO default route and NO resolver for this
    # interface, so its WiFi keeps the internet.  That omission IS the design.
}
EOF
    run "sed -i 's/^INTERFACESv4=.*/INTERFACESv4=\"eth0\"/' /etc/default/isc-dhcp-server"
    [ "$DRYRUN" = 1 ] || chg "dhcpd.conf -> $DIRECT_POOL_LO-$DIRECT_POOL_HI, no routers option; bound to eth0"
  fi
  printf '    after reboot check:  systemctl is-active isc-dhcp-server   -> active (was: failed)\n'
else
  skip "not configured -- on a shared network the router does DHCP"
  if systemctl is-enabled isc-dhcp-server >/dev/null 2>&1; then
    printf '    \033[33mnote\033[0m  isc-dhcp-server is ENABLED on this image and fails at boot (no interface,\n'
    printf '          no subnet). Harmless, but do not let it start on a shared segment.\n'
  fi
fi

# ---- 5. machine-id ---------------------------------------------------------------------
say "5/7  machine-id"
STOCK_MID=c82cf5bcd3a14b95935d65bfb529d72d
CUR_MID="$(cat /etc/machine-id 2>/dev/null || echo '')"
if [ "$CUR_MID" = "$STOCK_MID" ] || [ -z "$CUR_MID" ]; then
  run "rm -f /etc/machine-id /var/lib/dbus/machine-id"
  run "systemd-machine-id-setup >/dev/null 2>&1"
  run "ln -sf /etc/machine-id /var/lib/dbus/machine-id"
  if [ "$DRYRUN" = 1 ]; then printf '    would: regenerate (was the stock baked id)\n'
  else
    NEW_MID="$(cat /etc/machine-id 2>/dev/null || echo '<not created -- check systemd-machine-id-setup>')"
    chg "machine-id $NEW_MID  (was the stock baked $STOCK_MID)"
  fi
else
  ok "already unique ($CUR_MID)"
fi

# ---- 6. SSH host keys ------------------------------------------------------------------
# The stock IMAGE ships host keys, so every card is impersonable by every other card.
say "6/7  SSH host keys"
STOCK_FP='TB0FfGjfMzgZUv/reJgTpeq/AM68sMCpGC5xm6Pit7o'
CUR_FP=''
if [ -f /etc/ssh/ssh_host_ed25519_key.pub ]; then
  CUR_FP="$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}' | sed 's|^SHA256:||')"
fi
if [ "$CUR_FP" = "$STOCK_FP" ] || [ -z "$CUR_FP" ]; then
  printf '    current ed25519 fingerprint is the stock image one -- regenerating\n'
  run "rm -f /etc/ssh/ssh_host_*"
  run "ssh-keygen -A >/dev/null"
  run "systemctl restart ssh"
  [ "$DRYRUN" = 1 ] || chg "fresh host keys, sshd restarted"
else
  ok "already re-keyed (ed25519 SHA256:$CUR_FP)"
fi

# ---- 7. the token in /boot/REVISION ----------------------------------------------------
say "7/7  /boot/REVISION"
if grep -q '@github.com' /boot/REVISION 2>/dev/null; then
  if [ "$DRYRUN" = 1 ]; then printf '    would: blank the credentialed URL in /boot/REVISION\n'
  else
    sed -i -E 's#https://:[^@]*@github\.com#https://github.com#g' /boot/REVISION
    chg "credentialed URL removed from /boot/REVISION"
  fi
else
  ok "no credentialed URL in /boot/REVISION"
fi
if [ "$DRYRUN" = 0 ]; then
  HITS="$(grep -rIl -e 'github_pat_' -e 'ghp_' -e '@github.com' /boot /home /root /etc 2>/dev/null || true)"
  if [ -n "$HITS" ]; then printf '    \033[31mstill present elsewhere:\033[0m\n%s\n' "$HITS" | sed 's/^/      /'
  else ok "no token-shaped string left under /boot /home /root /etc"; fi
fi

# ---- summary ---------------------------------------------------------------------------
printf '\n'
if [ "$DIRECT" = 1 ]; then
  say "summary -- topology E, and this card is now identical to every other"
  printf '    address      %s/24, static, no gateway\n' "$DIRECT_IP"
  printf '    dhcpd        %s .. %s on eth0, NO routers option\n' "$DIRECT_POOL_LO" "$DIRECT_POOL_HI"
  printf '    attendee     ssh xilinx@%s   or   http://%s/\n' "$DIRECT_IP" "$DIRECT_IP"
  printf '    PYNQ_HOST    already defaults to xilinx@%s -- nothing to export\n' "$DIRECT_IP"
  printf '\n    after reboot, from a laptop on the other end of one cable:\n'
  printf '      ip route          # default route must still be the laptop WiFi, NOT this link\n'
  printf '      ssh xilinx@%s\n' "$DIRECT_IP"
else
  say "summary for board $NN"
  printf '    hostname     %s\n' "$HOST"
  printf '    address      %s/24  gw %s\n' "$IP" "$GW"
  printf '    MAC          %s   (at next boot -- then CHECK IT:\n' "$MAC"
  printf '                 cat /sys/class/net/eth0/addr_assign_type  -> 3, not 1)\n'
fi
if [ "$DRYRUN" = 0 ]; then
  printf '    host keys:\n'
  for k in /etc/ssh/ssh_host_*_key.pub; do
    if [ -f "$k" ]; then printf '      %s\n' "$(ssh-keygen -lf "$k" 2>/dev/null)"; fi
  done
fi
printf '\n    \033[33mnow reboot:\033[0m  sudo shutdown -r now\n\n'
