#!/usr/bin/env python3
"""Generate `notebooks/iiswc_tutorial.ipynb` from the published attendee page.

The page -- the tutorial website's `src/data/instructions.ts`, which lives in a
separate repository -- is the source of truth for what the units are, what they run,
and what the screen should say. This script is the transcription of it, so a page
change is a data edit here and not a hand-edit of notebook JSON. **Edit this file,
re-run it, commit both.**

    python3 notebooks/tools/build_notebook.py

Fidelity rules kept here on purpose:
  * every command, every expected-output block and every fix is the page's text;
  * nothing is invented where the page says a unit has no attendee sequence;
  * a step's `where` decides which helper runs it -- `lab.sh` on the instance,
    `lab.board` on the card, and nothing at all where the page says the step
    happens at the glass or on a laptop.

=================================================================================================
THIS IS NO LONGER A PURE TRANSCRIPTION, AND THE DIVERGENCE IS DELIBERATE
=================================================================================================
The page describes the flow where the attendee joins `iiswc-robotics-tutorial`, holds the
shared SSH key, opens a shell on their card, and has the CARD relay to AWS.  The interface
moved (TUTORIAL_INTERFACE_NOTES.md 4e, TUTORIAL_AUTH_TLS.md): the attendee now opens
JupyterLab on their own instance over their own internet with one shared passphrase, holds
no key, never types `ssh`, and the BOARD dials in to them.

So these steps are re-expressed here and are NOT the page's text:

    0.2   was `ssh -i <key> xilinx@10.42.0.N` from a laptop on the room network.
          Now: the board finds you, and `lab.board_status()` is how you ask.
    0.4   was the board looking up `aws-N.iiswc` to find its instance.
          Now: superseded -- you are already on the instance.  Kept as orientation.
    0.5   was the `/opt/iiswc/host/aws_*.sh` relay scripts and two fixes about the
          shared key's path and mode.  Now: the agent's ten verbs.  The key fixes are
          gone because the attendee is not given a key.
    1.4   was `aws_run.sh`, one command doing pull+load+console on the board.
          Now: `board_put` then `run` then `get`, over the tunnel.

***THE PAGE NEEDS THE SAME CORRECTION AND HAS NOT HAD IT.***  It is in a different
repository -- the tutorial website -- and was not edited by this lab.  More than step 0.2
is affected: the page is served from the router at 10.42.0.1 and is written to survive the
uplink dying, which assumes an attendee ON the room network -- under 4e nobody is, so the
page's delivery mechanism is superseded along with its step 0.2.  That is a decision for
whoever owns the page, not something to paper over here.
"""
import json
from pathlib import Path

NB = Path(__file__).resolve().parents[1] / "iiswc_tutorial.ipynb"

cells: list[dict] = []


def _lines(text: str) -> list[str]:
    """nbformat wants every line but the last to KEEP its newline.

    Splitting on "\\n" and dropping it collapses the whole cell onto one line, which
    looks right in the JSON and is a SyntaxError in the kernel. Caught by executing the
    notebook; it is not visible by reading it.
    """
    parts = text.rstrip("\n").split("\n")
    return [p + "\n" for p in parts[:-1]] + parts[-1:]


def _cell_id() -> str:
    return f"c{len(cells):03d}"


def md(text: str) -> None:
    cells.append({"cell_type": "markdown", "id": _cell_id(), "metadata": {},
                  "source": _lines(text)})


def code(text: str) -> None:
    cells.append({"cell_type": "code", "id": _cell_id(), "execution_count": None,
                  "metadata": {}, "outputs": [], "source": _lines(text)})


def fence(text: str, lang: str = "") -> str:
    return f"```{lang}\n{text}\n```"


def fixes_table(fixes) -> str:
    rows = "\n".join(f"| {s} | {a} |" for s, a in fixes)
    return "**If instead you see**\n\n| | do |\n|---|---|\n" + rows


# ======================================================================================
# Front matter -- instructions.ts `instructions`
# ======================================================================================
md("""# IISWC 2026 · Attendee bench card

## Four units, one board, one terminal

Work down the page. Each step is a command, the output you should get, and what to do
when you don't.

*The page's commands and quoted outputs were executed on 2026-09-23 on bench card
`pynq-2`. The board outputs in this notebook were re-run on 2026-09-24 through the
tunnel, on card `pynq-13`, and are quoted from those runs.*

---

### How you got here, and what you will never be asked to do

You opened this notebook on **your own instance**, over your own internet, with **one
shared passphrase**. That is the whole access story:

* you never join the room's WiFi;
* you never hold an SSH key, and you never type `ssh`;
* your board reaches *you*, by holding a tunnel open to this instance — so a card that
  drops its WiFi reconnects on its own instead of killing your session.

The published bench card still describes the older flow, where you sat on the room
network and the board relayed for you. Where a step exists only because of that, this
notebook says so instead of deleting it.

### Where each cell runs

Two helpers, and the difference between them is the point of several units:

| helper | runs on | when the thing it needs is missing |
|---|---|---|
| `lab.sh("...")` | this instance | fails like any command, with a timeout |
| `lab.board("verb")` | your card, over its reverse tunnel | says `board offline` or `STUB` — it never invents output |

Your card does not accept arbitrary commands. Its key carries a **forced command** with a
fixed verb set — `ping status help ls put get bitstream run camera mic` — so that an
instance someone else has broken into cannot get a shell on the board (B176). Where the
page prints a board command, the notebook prints the verb that does the same thing.

`lab.board_status()` answers in seconds. Re-run it whenever the card stops replying. It
waits for the board's own SSH banner rather than trusting that the tunnel port is bound:
that port belongs to *this instance's* sshd, which keeps accepting connections for a board
that is already gone.""")

md("""### Your seat

Take it from the OLED: the last octet of `10.42.0.N`. The glass is the authority, not a
printed list.

| | |
|---|---|
| Your board | `10.42.0.{N}` |
| Its hostname | `pynq-{N}` |
| Your instance | `aws-{N}.iiswc` |""")

code('''import sys, pathlib
sys.path.insert(0, str(pathlib.Path.cwd()))
import iiswc_lab as lab

SEAT = "N"          # <-- put your seat number here, from the OLED

lab.where_am_i()''')

code("lab.board_status()")

# ======================================================================================
# Unit 0
# ======================================================================================
md("""---

## Unit 0 · Start here — Get a shell, and find your instance

**Runs on your board today.** Five short steps. Every unit after this assumes them.""")

md("""### 0.1 Read the OLED

*At the board · nothing to type.* `up M:SS` must be ticking: a frozen counter is a dead
SoC, not a slow one.

Expected, on the glass:

""" + fence("10.42.0.{N}\niiswc-robotics-tutorial\nup 4:17") + "\n\n" + fixes_table([
    ("`up M:SS` is frozen", "Power-cycle. The glass holds a stale frame; it must restart at `up 0:00`."),
    ("`NO ADDRESS`, or `wlan0 DOWN`", "Power-cycle. Nothing below works until the board has an address."),
    ("Blank, and under two minutes", "Wait. Raising the network alone takes about 37 s."),
]))

md("""### 0.2 Your board finds you

*Nothing to type, nothing to install.* You have no key, no SSH client and no way to reach
a card directly — and you need none. Your board holds a tunnel open to **this** instance,
so it arrives here by itself, and a card that drops its WiFi reconnects on its own instead
of killing your session.

> **The published bench card has a different step 0.2** — `ssh -i <key> xilinx@10.42.0.N`
> from a laptop joined to the room's WiFi. That flow is gone: attendees no longer join the
> room network and are no longer given a key. The page has not caught up yet; this notebook
> is the flow that exists.

The cell that answers *is my board there* is the one you already ran at the top, and it is
the one to re-run whenever the card stops replying:""")
code("lab.board_status()")
md("""It answers in about three seconds and never hangs. There are three answers:

""" + fence(
    "board connected -- pynq-13, 10.42.0.13, PL operating, MAGIC -\n"
    "board offline (nothing is listening) -- ConnectionRefusedError ...\n"
    "board offline (tunnel is stale) -- the port is bound but nothing answered within 3s") + """

> It waits for your card's own SSH banner rather than trusting that the tunnel port is
> bound. That port belongs to *this instance's* sshd, which keeps accepting connections for
> a board that is already gone — so "the port is open" and "the board is there" are
> different questions, and only the second one is worth asking.

""" + fixes_table([
    ("`board offline (nothing is listening)`", "Your card has not dialled in. Read the OLED (0.1); power-cycle if `up M:SS` is frozen."),
    ("`board offline (tunnel is stale)`", "A dead session still holds the port. The card retries by itself — wait, and re-run this cell."),
    ("`board path NOT BUILT (stub)`", "This instance has no `board_link.py`. An instructor's problem, not yours; say so."),
    ("It stays offline after a power-cycle", "Say so out loud. **Every instance-side unit below runs without a board.**"),
]))

md("""### 0.3 Ask the board who it is

*On the board.* The same fields as the OLED, read from Linux. If they disagree, believe
this.""")
code('lab.board("status")')
md("""Expected — the same fields the page prints, as the agent's JSON. Measured on card
13 on 2026-09-24; yours says your own seat:

""" + fence("""{
  "ok": true,
  "agent": "b176.1",
  "board": {
    "hostname": "pynq-13",
    "iface": "wlan0",
    "ipv4": "10.42.0.13",
    "ssid": "iiswc-robotics-tutorial",
    "signal_dbm": -33,
    "link_up": 1,
    "pl_state": "operating",
    "soc_magic": "-"
  },
  "incoming": 0,
  "results": 0,
  "tunnel_unit": "active",
  "uptime_s": 51910
}""", "json") + """

`tunnel_unit: active` is the line with no equivalent on the page: it is your card saying
it is holding the tunnel open to this instance. **`soc_magic: "-"` is not an error** — the
number needs a privileged read and a card that has not done one reports `-`.

""" + fixes_table([
        ("`ipv4  NO ADDRESS`", "Back to 0.1."),
        ("`PL` is anything but `operating`", "Power-cycle and let the boot service load the bitstream."),
        ("`MAGIC  -`", "Harmless. Re-run under `sudo` for the number."),
        ("`MAGIC 0x5A5A0039`", "The trace bitstream. Units 1 and 2 want `0x5A5A0038` — a PL reload, not a re-image."),
    ]))

md("""### 0.4 Find your AWS instance

*On the board · needs the uplink.* The board derives its seat from its own address. You
never type an IP.""")
md("""> **This step is superseded by the interface, and deliberately kept here.** It exists
> because the board had to find *you*. In this notebook the direction is reversed: you are
> already on the instance, and the board dials in to it. The board's own view of its seat
> is in the `status` reply above, under `ipv4` and `derives`.""")
md("Expected:\n\n" + fence(
    "this board is 10.42.0.{N}, so it is seat {N}\nseat {N}  aws-{N}.iiswc -> 54.x.x.x")
   + "\n\n" + fence("tcp/22 open  SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.14") + """

> `--check` logs nobody in. It proves egress works and sshd is listening.

""" + fixes_table([
    ("`aws-{N}.iiswc did not resolve`", "Room-wide, not yours: only the router at 10.42.0.1 serves `.iiswc` names. Say so out loud."),
    ("Resolves, but `--check` times out", "The instance is down or the phonebook is stale. An instructor republishes it."),
]))

md("""### 0.5 The commands every unit uses

*On the board · reference.* All of them live in `/opt/iiswc/host/`. The board dials out;
AWS cannot reach in.

| command | does |
|---|---|
| `aws_whoami.sh` | Which instance is mine. |
| `aws_ssh.sh` | A shell there. `aws_ssh.sh -- uptime` runs one command; the `--` is required. |
| `aws_push.sh` | Board to instance, md5-checked at both ends. |
| `aws_pull.sh` | Instance to board. A name or an IP. |
| `aws_run.sh` | Pull the image, load it, watch the console. |""")
md("""In this notebook the verbs are the board's, not the board's view of AWS:

| verb | does |
|---|---|
| `ping`, `status` | is it there, and who is it |
| `help`, `ls` | what it accepts, what results it holds |
| `put`, `get` | a file in, a result out |
| `bitstream` | load a PL variant |
| `run` | one named lab step |
| `camera`, `mic` | one capture |

`aws_ssh.sh`, `aws_push.sh` and `aws_pull.sh` have no counterpart on purpose: they were the
board reaching AWS, and the notebook is already there.""")
code('lab.board("help")')
md("""Expected:

""" + fence("""{
  "ok": true,
  "agent": "b176.1",
  "verbs": ["help", "ping", "status", "ls", "put", "get",
            "bitstream", "run", "camera", "mic"],
  "max_put": 67108864,
  "max_get": 67108864
}""", "json") + """

**Anything that is not one of those ten is refused**, and that is the point rather than a
limitation — the key your instance holds carries a forced command, so an instance somebody
else has broken into still cannot get a shell on your card:

""" + fence("lab.board(\"id\")\n"
             "  the card refused or failed: BoardError: unknown verb.\n"
             "  Known: help ping status ls put get bitstream run camera mic") + """

**`camera` and `mic` need hardware your card may not have.** On card 13, `camera` answers
`this card carries no cam_snap guest` and `mic` answers `no capture`. Both are the correct
answer for that card, not a fault, and no unit below depends on either.

The page's own fixes for this step were both about the shared SSH key — where it lives and
what mode it is. **Neither can happen to you: you are not given a key**, and the credential
this instance uses for the tunnel is installed before you sit down. If a board verb fails
on a credential, it is an instructor's problem and not yours.""")

# ======================================================================================
# Unit 1
# ======================================================================================
md("""---

## Unit 1 · Zephyr and Chipyard: build on the cloud, run on your SoC

**Runs on your board today · needs the uplink.** Your card is a runtime with no
toolchain. Build on the instance, run on the silicon.""")

md("""### 1.1 Open a shell on your instance

*On the board.* No argument: it asks `aws_whoami.sh`. The missing host-key warning is
deliberate.

""" + fence("/opt/iiswc/host/aws_ssh.sh", "bash") + """

Expected:

""" + fence("Welcome to Ubuntu 24.04 LTS ...\nubuntu@ip-192-168-0-205:~$") + """

> **This notebook already is that shell.** Step 1.2 onward runs here.

""" + fixes_table([
    ("Anything about the seat or the name", "That is step 0.4, not this one."),
    ("It drops after a few idle minutes", "Reconnect. The build is on the instance, not in your session."),
]))

md("""### 1.2 Build a Zephyr image for the Rocket SoC

*On the instance.* About thirteen seconds. `samples/boot_info` is the guest your board is
running now.""")
code('''lab.sh("""cd /home/ubuntu/tut && source /home/ubuntu/tut/env.sh && \\
west build -p always -b chipyard_pynqz1_all_f40 \\
    -d ~/out/boot_info samples/boot_info \\
    -- -DBOARD_ROOT=/home/ubuntu/tut""", timeout=900)''')
md("Expected, at the end:\n\n" + fence(
    "-- west build: building application\n...\n"
    "Memory region         Used Size  Region Size  %age Used\n"
    "             RAM:       69720 B       256 MB      0.03%"))
code('lab.sh("ls -l ~/out/boot_info/zephyr/zephyr.bin")')
md("Expected:\n\n" + fence("-rw-rw-r-- 1 ubuntu ubuntu 55536 ... zephyr.bin") + """

> The board name is load-bearing: `chipyard_pynqz1_all_f40`, never plain
> `chipyard_pynqz1`. The wrong one boots dead.

""" + fixes_table([
    ("`west: command not found`", "`source /home/ubuntu/tut/env.sh`"),
    ("CMake names a missing toolchain file", "It names the wrong thing: `ZEPHYR_SDK_INSTALL_DIR` points at another SDK."),
    ("CMake cannot find a source under `samples/`", "The instance image is behind. Say so."),
]))

md("""### 1.3 Put it where the board will look

*On the instance.* `~/pub/` has no producer in the repository. This copy is the missing
link.""")
code('''lab.sh("mkdir -p ~/pub && cp ~/out/boot_info/zephyr/zephyr.bin ~/pub/zephyr.bin && ls -l ~/pub/zephyr.bin")''')
md("Expected:\n\n" + fence("-rw-rw-r-- 1 ubuntu ubuntu 55536 ... /home/ubuntu/pub/zephyr.bin") + """

> Or skip the directory: set `AWS_IMAGE=out/boot_info/zephyr/zephyr.bin` on the next
> command.""")

md("""**What this costs the room.** Every byte the board pulls crosses one shared 2.4 GHz
channel, and ten radios deliver what one radio delivers — 4.021 MiB/s for the whole room,
not per seat (B170 / L412).""")
code('lab.budget("Unit 1 image, whole", 55_536)')
md("""`boot_info` is small enough that it is not worth a delta. Unit 2's image is not — see
below.

*Nothing here is pre-seeded: the build above is 23 s cold on this instance, measured, so
you are not waiting on anything.*""")

md("""### 1.4 Pull it, load it, watch it run

*On the board.* One command: pull, load the PL, start the guest, read the console.""")
code('lab.board_put("/home/ubuntu/pub/zephyr.bin")')
md("""Expected — and the md5 is the one step 1.2 built, checked on the card rather than
here, so a truncated push is an error there instead of a dead guest:

""" + fence("""{
  "ok": true,
  "stored": "zephyr.bin",
  "bytes": 55536,
  "md5": "50469e9c18e9ec24f1e9ec7d0fe45ef1"
}""", "json") + """

Measured 1.94 s for 55,536 B. Now load the PL, start the guest, and read the console:""")
code('lab.board("run", "zephyr", timeout=300)')
md("""Expected, in about 40 s:

""" + fence("""{
  "ok": true,
  "ran": "zephyr",
  "console_bytes": 373,
  "results": ["console.out", "run.log"]
}""", "json") + """

The console is a result on the card. Fetch it:""")
code('''c = lab.board("get", "console.out", binary=True, verbose=False)
print(c.stdout.decode("utf-8", "replace") if c.ok else c)''')
md("""Expected — **373 bytes, measured on card 13 on 2026-09-24**, the whole chain in one
place: built on this instance, carried over the card's own tunnel, loaded into the PL, and
read back off the guest's console.

""" + fence(
    "*** Booting Zephyr OS build 4329bf61c4fe ***\n"
    "BI_BOOT addr=0x8f000000\n"
    "BI_RAW magic=0x42533031\n"
    "BI_OLED probe addr=0x3c addr_ack_rc=0 nop_rc=0 init_rc=0 setup_rc=0\n"
    "BI_OLED state=READY addr=0x3c\n"
    "BI_STATUS state=PRESENT nonce=0xa1873611 soc_magic=0x5A5A0038\n"
    "BI_NET host=pynq-13 iface=wlan0 ipv4=10.42.0.13 ssid=iiswc-robotics-tutorial "
    "link_up=1 signal_dbm=-31\n"
    "BI_DONE") + """

`soc_magic=0x5A5A0038` is the bitstream Units 1 and 2 want. `nonce` is yours and will
differ; the OLED restarts at `up 0:00`.

For comparison, what the bench card prints when a person drives `aws_run.sh` by hand — the
same four stages, with the relay the notebook no longer needs:

""" + fence(
    "==> 1/4  pull pub/zephyr.bin from aws-{N}.iiswc\n"
    "    pulled pub/zephyr.bin  (55536 bytes, 1.612 s)\n"
    "==> 2/4  check nobody else is reading the console\n"
    "==> 3/4  load the PL and start the guest\n"
    "==> 4/4  console\n"
    "    2156 bytes of console in /home/xilinx/tutorial/console.out") + """

""" + fixes_table([
    ("`[fail] 0 console bytes`", "Stop and say so. Do not retry and do not reboot."),
    ("The console is garbage characters", "Wrong clock: the guest was built for the wrong board. Rebuild for `chipyard_pynqz1_all_f40`."),
    ("`another console reader is already on /dev/ttyPS1`", "Kill the PID it prints, never a pattern."),
    ("Banner only, no `BI_` lines", "The reader started late. The full text is in `/home/xilinx/tutorial/console.out`."),
]) + """

> **Gap the page declares:** proven twice on the bench board, never yet on a card from
> the imaging flow — so zero console bytes may be that, not you.""")

# ======================================================================================
# Unit 2
# ======================================================================================
md("""---

## Unit 2 · ModelBlaster: a network compiled to kernels you can beat

**No attendee steps yet.** Compile a PyTorch model to int8 kernels for this SoC, replace
one, and prove it is identical rather than merely faster.

> **Gap the page declares:** no attendee sequence yet — every ModelBlaster lab is
> developer-facing (bench-board lock, 18 GB toolchain, repository checkout) and your card
> carries none of it.

Everything below is the one optional step the page does publish. There is no board step
in this unit, and this notebook does not invent one.""")

md("""### 2.1 Optional: the kernel gate

*On any clone of the repository, with gcc.* No board, no lock, no cross-compiler. Takes
no arguments; exits with the number of failures.

Takes about three minutes on this instance — it is optional for that reason.""")
code('''lab.sh("cd /home/ubuntu/tut && fpga/pynq-z2/modelblaster/kernels/pext_nl/test/b76_gate.sh",
       timeout=600)''')
md("""**Expect to see `FAIL` scroll past, a lot of it, and expect the gate to pass anyway.**
The gate proves each route is live by running a *poisoned* copy of it and checking that the
gate rejects the poison, so every `FAIL` line is a poisoned arm being caught. A passing
run prints **26 `FAIL` lines and 260 `MISMATCH` lines**. What you compare against is the
four gates passing and the verdict:

""" + fence(
    "b76 permute gate:   ... max_abs_err=0 fails=0  PASS\n"
    "b76 mul gate:       ... max_abs_err=0 fails=0  PASS\n"
    "b66 layernorm gate: ... max_abs_err=0 fails=0  PASS\n"
    "b66 softmax gate:   ... max_abs_err=0 fails=0  PASS\n\n"
    "B76 GATE PASSED: all four treatments byte-identical to the shipping kernels over\n"
    "every shape and scale the decoder dispatches, and all ten new routes proved live by\n"
    "a poisoned arm that the same gate rejects.") + """

and `rc=0`. The full text is shipped beside this notebook, so you can compare it without
spending the three minutes:""")
code('print(open("assets/b76_gate.expected.txt").read())')

md("""### Why this unit moves nothing yet, and what it will cost when it does

The artifact a ModelBlaster lab has to move is the 66,982,840-byte image. At the room's
measured aggregate that is eight minutes of a jammed channel for thirty seats, which is why
the board half is not simply switched on (B170 / L412, B173 / L413):""")
code("""lab.budget("whole image, raw", 66_982_840)
lab.budget("whole image, gzip -6", 56_070_472)
lab.budget("kernel re-tune delta", 257_008)""")
md("""260x, and exact rather than statistical: across a real kernel re-tune 65,465,456 B of
object content is byte-identical and merely relocated — no weight tensor changes a byte.
The saving depends entirely on the differ re-anchoring after `text` grows; a shift-blind
4 KiB block diff calls 99.8 % of blocks changed.

> Open item, not solved: `zstd`, `xdelta3` and `bsdiff` are all absent from the board
> rootfs. `libzstd` is present and python is 3.10.4, so `ctypes` against the library is the
> first thing to try. `gzip` is not a fallback here — 1.19x on this data.""")

# ======================================================================================
# Unit 3
# ======================================================================================
md("""---

## Unit 3 · TACIT: every instruction the SoC retired, on one timeline

**Part runs today.** A trace encoder in the Rocket core writes retired instructions to
memory; a decoder turns them into a timeline.

> **Gap the page declares:** capture has no attendee sequence — your card carries
> `0x5A5A0038`, TACIT needs `0x5A5A0039`, and the on-board decoder is not shipped. Shown
> from the front.""")

md("""### 3.1 Cache the trace viewer

*On your laptop · do this first · needs the uplink.* Open it once, now, and let it finish
loading.

<https://ui.perfetto.dev>

Expected: the Perfetto UI, with an **Open trace file** button in the left sidebar.

> It runs in your browser afterwards, but the first load needs the internet. There is no
> offline copy in the room.

""" + fixes_table([
    ("The uplink is already down", "Borrow a neighbour's cached tab, or watch from the front."),
]))

md("""### Extra — a capture to open in it

**Not on the attendee page.** The page is right that *capture* has no attendee sequence.
This is the other half: one capture already taken on silicon, shipped beside this notebook,
so the viewer you just cached has something to show.""")
code("t = lab.unpack_trace()")
md("""Expected: about 1.99 MB, 534,990 instructions, 2.021 bits per instruction, captured
2026-09-16 on a Rocket SoC — **not on your card**, which carries `0x5A5A0038`.

Now the question Perfetto answers visually, answered here in Python: where did the SoC
actually spend its cycles?""")
code("lab.trace_summary(t)")
md("""Expected, at the top:

""" + fence(
    "function                    self ticks   share    calls\n"
    "__muldf3                       210,583   31.3%    1,515\n"
    "__subdf3                        99,067   14.7%    1,146\n"
    "__mulsf3                        56,400    8.4%      600") + """

Six of the top eight are `__muldf3`, `__subdf3`, `__mulsf3`, `__addsf3`, `__subsf3`,
`__adddf3` — compiler soft-float. This core has no FPU, so a field-oriented-control loop
written in `float` and `double` spends most of its instructions emulating arithmetic. That
is what the timeline shows you and a profiler counter does not.

**To open it in Perfetto:** in the JupyterLab file browser on the left, right-click
`rocket_tacit_trace.perfetto.json` and choose Download, then drag the file into the
Perfetto tab you cached in 3.1. The trace never leaves your instance until you ask for it.""")
code("""lab.budget("trace, decoded JSON", 1_989_396)
lab.budget("trace, gzip -9", 96_680)""")
md("""20.6x, which is why a trace travels compressed and an image travels as a delta. Both
numbers are the same constraint: one shared channel, 4.021 MiB/s for the whole room.""")

# ======================================================================================
# Unit 4
# ======================================================================================
md("""---

## Unit 4 · Scheduling across the machine, and asking a model to write the kernel

**Part runs today · needs the uplink.** Three pieces at three stages of readiness. The
scheduler is real and you run it.""")

md("""### 4.1 Solve a real schedule on your instance

*On the board, on the page — because the page drives the instance through the board.*
XPU-RT places every operator onto the devices of a heterogeneous machine. Eight
dispatches, provably optimal in under a second.

The page's command is:

""" + fence("""/opt/iiswc/host/aws_ssh.sh -- 'source /etc/profile.d/xpurt.sh && \\
    cd $XPURT_ROOT && XPURT_CPSAT_WORKERS=1 $XPURT_PYTHON \\
    scripts/run_xpurt_schedule.py \\
      --networks-json data/toplevel/networks_b154_gate.json \\
      --solver cpsat --profiled --cpsat-time-limit 60'""", "bash") + """

The solve was always on the instance; only the `aws_ssh.sh --` relay is dropped here,
because this notebook is already on the instance. The command inside the quotes is
unchanged.""")
code('''lab.sh("""source /etc/profile.d/xpurt.sh && cd $XPURT_ROOT && \\
XPURT_CPSAT_WORKERS=1 $XPURT_PYTHON scripts/run_xpurt_schedule.py \\
  --networks-json data/toplevel/networks_b154_gate.json \\
  --solver cpsat --profiled --cpsat-time-limit 60""", timeout=300)''')
md("Expected, on the last line but one:\n\n" + fence(
    "makespan_us=237.87  op_deadline_miss=0 (dispatches, NOT instances)  cross_dev=0  solver_s=0.377")
   + """

> 237.87 is measured on this silicon, so four vCPUs and a 48-core workstation return the
> same figure. `makespan_us` is the invariant; `solver_s` is this machine's wall clock and
> will differ.""")
code("""import json, os
root = os.environ.get("XPURT_ROOT", "/opt/xpurt/XPU-RT")
m = json.load(open(os.path.join(
    root, "schedules/scheduled_networks_b154_gate_cpsat_profiled_metrics.json")))
lab.expect("makespan_us", round(m["makespan_us"], 2), 237.87)""")
md("""And the schedule it found — every operator placed on a device of the machine:""")
code("""from IPython.display import Image
Image(filename=os.path.join(root, "plots/networks_b154_gate_cpsat_profiled.png"))""")
md(fixes_table([
    ("`RuntimeError: no interpreter with ortools found`", "You dropped the `source`. It is not decoration."),
    ("Two runs, two different makespans", "`XPURT_CPSAT_WORKERS=1` is not set."),
    ("Nothing in the log for minutes", "Normal: Python buffers to the file. Check CPU time; `ps -C python3` matches nothing."),
]) + """

> **Gaps the page declares:** agentic code generation has no attendee flow, and the
> fusion-hint speed-up was withdrawn by its own authors. RiskyBird is a look, not a lab —
> one or two boards in the room, shown from the front.""")

nb = {
    "cells": cells,
    "metadata": {
        "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
        "language_info": {"name": "python"},
    },
    "nbformat": 4,
    "nbformat_minor": 5,
}
NB.write_text(json.dumps(nb, indent=1) + "\n")
print(f"wrote {NB}  ({len(cells)} cells)")
