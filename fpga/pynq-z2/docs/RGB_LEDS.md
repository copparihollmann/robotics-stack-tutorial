# The PYNQ-Z1's two RGB LEDs, from Zephyr

**Status: working, with one thing deliberately left to a human. The colour mapping comes
from two independent vendor sources that agree, the six ports are asserted onto their
package balls in the routed design, a stock Chipyard GPIO controller carries them, a stock
Zephyr driver drives them, and a lab walks them through a sequence and cross-checks it
from two different bus masters. A person watched the walk on the bench board on 2026-09-16
and confirmed the colour mapping (`e611ad1`).**

Short version:

| | |
|---|---|
| The parts | Two tri-colour LEDs, **LD4** and **LD5**, six PL pins, cathodes driven through an inverting transistor |
| The mapping | `L15 G17 N15` = LD4 {B, G, R}; `G14 L14 M15` = LD5 {B, G, R}. **Two independent vendor sources, agreeing exactly.** §1 |
| Polarity | **Active high.** PYNQ-Z1 Reference Manual §12.1 |
| Brightness | The manual says a steady `1` is "uncomfortably bright" and asks for ≤50% duty. The PL chops all six at a fixed **12.5%**, uncircumventable from software. §2 |
| SoC cost | **Zero new Chipyard code.** `chipyard.config.WithGPIO` + `chipyard.iobinders.WithGPIOPunchthrough`, both stock. §3 |
| Software cost | **Zero new Zephyr code.** `drivers/gpio/gpio_sifive.c` + `dts/bindings/gpio/sifive,gpio0.yaml`, both stock since 2017. §5 |
| Bitstream | **+634 LUT, +228 FF, +0 DSP, +0 BRAM in context; WNS +1.101 → +1.169 ns, WHS +0.011 → +0.024** (re-measured after the TACIT predictor removal; +657 / +228 before it). §7 |
| Pin check | Asserted against the **routed** design, three independently-written copies of the table. §4 |
| On the board | 24/24 readbacks, all 8 patterns confirmed by a second bus master, 23/23 golden checks. §9 |
| **CONFIRMED 2026-09-16** | **that red is red.** Observed by a person on the bench board: the full walk ran as specified — RGB on LD4, then RGB on LD5, then both white. §6 explains why software could not settle this and why that specific sequence is the one that proves it. |

---

## 1. The colour mapping, and where it comes from

### 1.1 The board files give you six balls and no colours

`fpga/pynq-z2/boards/pynq-z2/A.0/part0_pins.xml` and
`boards/arty-z7-20/A.0/part0_pins.xml` (which our builds actually use — see
`MICROPHONE.md` §1.1) agree exactly, and say this much:

```xml
<pin index="29" name="rgb_led_tri_o_0" iostandard="LVCMOS33" loc="L15"/>
<pin index="30" name="rgb_led_tri_o_1" iostandard="LVCMOS33" loc="G17"/>
<pin index="31" name="rgb_led_tri_o_2" iostandard="LVCMOS33" loc="N15"/>
<pin index="32" name="rgb_led_tri_o_3" iostandard="LVCMOS33" loc="G14"/>
<pin index="33" name="rgb_led_tri_o_4" iostandard="LVCMOS33" loc="L14"/>
<pin index="34" name="rgb_led_tri_o_5" iostandard="LVCMOS33" loc="M15"/>
```

Six balls, one flat vector, and **nothing about which is red, which is green, which is
blue, or which of the two LEDs any of them belongs to.** That is the whole difficulty.
Getting it wrong is a *silent* failure: every one of the six bits lights something, the
design routes, the software works, and the board shows the wrong colours to somebody who
was not told what to expect. Compare the microphone, where a wrong pin gives a dead
signal and the analysis says so.

So the mapping had to come from somewhere authoritative, and — because none of us can see
the board — from **more than one** somewhere.

### 1.2 Source one: Digilent's master XDC, which carries the schematic net names

`Digilent/digilent-xdc`, `Arty-Z7-20-Master.xdc`. The trailing comment on each line is the
**schematic net name**, which is as close to reading the schematic as a text file gets:

```tcl
## RGB LEDs
#set_property -dict { PACKAGE_PIN L15 IOSTANDARD LVCMOS33 } [get_ports { led4_b }]; #IO_L22N_T3_AD7P_35      Sch=LED4_B
#set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports { led4_g }]; #IO_L16P_T2_35           Sch=LED4_G
#set_property -dict { PACKAGE_PIN N15 IOSTANDARD LVCMOS33 } [get_ports { led4_r }]; #IO_L21P_T3_DQS_AD14P_35 Sch=LED4_R
#set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports { led5_b }]; #IO_0_35                 Sch=LED5_B
#set_property -dict { PACKAGE_PIN L14 IOSTANDARD LVCMOS33 } [get_ports { led5_g }]; #IO_L22P_T3_AD7P_35      Sch=LED5_G
#set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports { led5_r }]; #IO_L23N_T3_35           Sch=LED5_R
```

Two caveats, both already familiar from the microphone work:

- **Digilent publishes no PYNQ-Z1 master XDC.** The `digilent-xdc` repository has
  `Arty-Z7-10-Master.xdc` and `Arty-Z7-20-Master.xdc` and no `Pynq-Z1`. That is exactly
  why our builds use the Arty Z7-20 *board file* in the first place (`tcl/board.tcl`).
- **The Arty Z7-20 and the PYNQ-Z1 are the same Zynq part on two closely related PCBs**,
  and Digilent's own feature comparison says the one difference is the microphone —
  quoted verbatim in `MICROPHONE.md` §1.1. The same file also gets the four plain LEDs
  (R14/P14/N16/M14), the four buttons and the two switches right for this board, which we
  already rely on.

That second caveat is why one source is not enough here.

### 1.3 Source two: Xilinx's own PYNQ library for *this* board

`Xilinx/PYNQ`, `pynq/lib/rgbled.py` — the class the PYNQ image's `base.rgbleds[4]` is:

```python
RGB_CLEAR = 0
RGB_BLUE  = 1
RGB_GREEN = 2
RGB_CYAN  = 3
RGB_RED   = 4
RGB_MAGENTA = 5
RGB_YELLOW  = 6
RGB_WHITE   = 7
...
rgb_mask = 0x7 << ((self.index - RGBLED._rgbleds_start_index) * 3)
```

Three bits per LED; within a group, **bit 0 = blue, bit 1 = green, bit 2 = red**. And
`boards/Pynq-Z1/base/notebooks/board/board_btns_leds.ipynb` fixes which group is which:

```python
rgbled_position = [4, 5]      # LD4 gets the low group, LD5 the high one
```

Read that against the bit order in PYNQ's own constraint file for this board,
`boards/Pynq-Z1/base/vivado/constraints/base.xdc`:

```tcl
## RGBLEDs
set_property -dict { PACKAGE_PIN L15 ... } [get_ports { rgbleds_6bits_tri_o[0] }];
set_property -dict { PACKAGE_PIN G17 ... } [get_ports { rgbleds_6bits_tri_o[1] }];
set_property -dict { PACKAGE_PIN N15 ... } [get_ports { rgbleds_6bits_tri_o[2] }];
set_property -dict { PACKAGE_PIN G14 ... } [get_ports { rgbleds_6bits_tri_o[3] }];
set_property -dict { PACKAGE_PIN L14 ... } [get_ports { rgbleds_6bits_tri_o[4] }];
set_property -dict { PACKAGE_PIN M15 ... } [get_ports { rgbleds_6bits_tri_o[5] }];
```

and you get L15 = LD4 blue, G17 = LD4 green, N15 = LD4 red, G14 = LD5 blue, L14 = LD5
green, M15 = LD5 red.

**That is Digilent's table, arrived at from a different vendor, a different repository and
a different kind of artifact** — a Python driver and a board-specific overlay constraint
rather than a schematic-derived master XDC. The two have no common ancestor that would
make them agree by copying.

**This is the same `base.xdc` that `MICROPHONE.md` §1.3 took F17/G18 from**, and that
claim was then *measured*: we loaded PYNQ's base overlay on this very board and recorded
live audio through those pins (`MICROPHONE.md` §2). So this source has already been
checked against this physical board once, empirically.

### 1.4 Polarity, drive, and the warning that changed the design

*PYNQ-Z1 Reference Manual*, §12.1 "Tri-Color LEDs", verbatim (read through an Internet
Archive snapshot — digilent.com serves a Cloudflare challenge to anything but a browser,
the same sourcing caveat as `MICROPHONE.md` §1.2):

> "The PYNQ-Z1 board contains two tri-color LEDs. Each tri-color LED has three input
> signals that drive the cathodes of three smaller internal LEDs: one red, one blue, and
> one green. **Driving the signal corresponding to one of these colors high will illuminate
> the internal LED.** The input signals are driven by the Zynq PL through a transistor,
> which inverts the signals. Therefore, to light up the tri-color LED, the corresponding
> signals need to be driven high. The tri-color LED will emit a color dependent on the
> combination of internal LEDs that are currently being illuminated. For example, if the
> red and blue signals are driven high and green is driven low, the tri-color LED will emit
> a purple color."
>
> "**Digilent strongly recommends the use of pulse-width modulation (PWM) when driving the
> tri-color LEDs. Driving any of the inputs to a steady logic '1' will result in the LED
> being illuminated at an uncomfortably bright level. You can avoid this by ensuring that
> none of the tri-color signals are driven with more than a 50% duty cycle.** Using PWM
> also greatly expands the potential color palette of the tri-color led."

Three things fall out of that paragraph.

**Active high**, unambiguously, and the transistor is *why* — the FPGA drives the cathodes
through an inverter, so the double negative comes out positive.

**No series resistor to size.** The manual's §12 says the *four plain* LEDs "are anode-connected to the
Zynq PL via 330-ohm resistors"; the tri-colour ones are not, because the FPGA pin drives a
transistor base and not the diode. There is nothing to set `DRIVE` or `SLEW` for, and
`src/pynqz2_rgb.xdc` sets neither, exactly as `pynqz2_rocket.xdc` does for `leds[3:0]`.

**PWM is not an optional nicety.** This is the one place the vendor documentation changed
the design rather than confirming it: the obvious "simple on/off per channel" deliverable
would have driven a steady `1`, which the manual calls out by name. §2 is what happened
instead.

### 1.5 The table

| bit | ball | LED | colour | Digilent net | PYNQ bit |
|---|---|---|---|---|---|
| 0 | **L15** | LD4 | blue  | `Sch=LED4_B` | `rgbleds_6bits_tri_o[0]` |
| 1 | **G17** | LD4 | green | `Sch=LED4_G` | `rgbleds_6bits_tri_o[1]` |
| 2 | **N15** | LD4 | red   | `Sch=LED4_R` | `rgbleds_6bits_tri_o[2]` |
| 3 | **G14** | LD5 | blue  | `Sch=LED5_B` | `rgbleds_6bits_tri_o[3]` |
| 4 | **L14** | LD5 | green | `Sch=LED5_G` | `rgbleds_6bits_tri_o[4]` |
| 5 | **M15** | LD5 | red   | `Sch=LED5_R` | `rgbleds_6bits_tri_o[5]` |

That order — B, G, R per LED, LD4 then LD5 — is kept everywhere downstream: it is the GPIO
controller's pin numbering, the `rgb_led[5:0]` vector in the FPGA top, the board's
`gpio-leds` node, and the bit order in `STATUS[9:4]`. **It is the vendor's order and not
ours**, deliberately, so that there is exactly one convention and no place to invert it.

All PL I/O on this board is LVCMOS33: there is no VADJ jumper, as `src/pynqz2_rocket.xdc`
already records.

---

## 2. The brightness chopper, and why it is in hardware

`src/pynqz2_rocket_top.v`:

```verilog
reg [7:0] rgb_phase = 8'd0;
always @(posedge fclk) rgb_phase <= rgb_phase + 8'd1;
wire rgb_lit = (rgb_phase < ((RGB_DUTY > 8'd128) ? 8'd128 : RGB_DUTY));
assign rgb_led = rgb_drive & {6{rgb_lit}};
```

`RGB_DUTY` defaults to 32, so the duty is **32/256 = 12.5%**, at 34.4828 MHz / 256 =
**134.7 kHz** — four orders of magnitude above anything an eye or a phone camera
integrates over.

Four decisions in six lines, and each is deliberate.

**It is in the PL, not in software.** A guest that writes `output_value = 0x3F` and then
crashes, or a sample somebody writes later that never heard of the manual's §12.1, leaves the LED at
whatever the hardware allows. Putting the limit in the structural top means no guest can
exceed it and none has to know about it. It also keeps the software interface exactly what
the task wanted — plain on/off per channel, eight states per LED.

**The 50% ceiling is clamped, not documented.** `RGB_DUTY` is a module parameter only so
it can be swept with `synth_design -generic` without editing the file; the
`(RGB_DUTY > 128) ? 128 : RGB_DUTY` is a comparison between compile-time constants,
synthesises to nothing, and makes the vendor's ceiling hold even against an override.

**12.5%, not 50%.** Half of the permitted maximum would be the letter of the
recommendation; a quarter of it is comfortable to sit next to for an hour, and an
"uncomfortably bright" LED at one eighth duty is still plainly a lit LED. Changing it is
one number.

**It is a brightness limit and not colour mixing.** All six channels share one duty, so
software still gets precisely the eight on/off states per LED and nothing more. §8 prices
what real per-channel PWM would cost.

**One consequence worth stating** because it will otherwise surprise somebody with an
oscilloscope: a pin written to `1` measures as a 12.5%-duty 134.7 kHz square wave, not as a
DC high. That is also why the readback in §4 is taken *before* the chopper — reading the
post-chopper signal would return `1` twelve percent of the time, which is worse than
useless.

**And one about colour**: red, green and blue dice in one package do not have equal
efficiency, so all three at equal duty gives a *tinted* white, usually towards blue-green.
The lab prints "BOTH on (all six dice)" rather than "white" for that reason. Anything pale
is right; neutral white is not the claim.

---

## 3. The SoC side: stock Chipyard, and no patch at all

This is the part that went differently from the microphone, and the difference is the
whole reason this cost a fraction as much.

`fpga/pynq-z2/chipyard/PynqZ2Configs.scala`:

```scala
class PynqZ2RocketBigLittlePextTacitMicRgbConfig extends Config(
  new chipyard.iobinders.WithGPIOPunchthrough ++
  new chipyard.config.WithGPIO(address = 0x10010000L, width = 6) ++
  new PynqZ2RocketBigLittlePextTacitMicConfig)
```

**That is the entire hardware change.** Every piece already exists upstream:

| piece | where it already lives |
|---|---|
| the controller | `generators/rocket-chip-blocks/src/main/scala/devices/gpio/` — sifive's GPIO, a `TLRegisterNode` with `compatible = "sifive,gpio0"` |
| the mixin | `DigitalTop.scala` already has `with sifive.blocks.devices.gpio.HasPeripheryGPIO` |
| the fragment | `chipyard.config.WithGPIO(address, width)` |
| the IO binder | `chipyard.iobinders.WithGPIOPunchthrough` |
| the harness tie-off | `chipyard.harness.WithGPIOPinsTiedOff`, **already in `AbstractConfig`** |

So there is **no `patches/0013`**. Contrast `patches/0012-chipyard-pdm-mic.patch`, which had
to add a whole `pdmmic` package, mix it into `DigitalTop`, add a `Ports.scala` case class,
add an IO binder, *and* needed a `WithPdmMicTiedOff` fragment in this repo because
`AbstractConfig` knew nothing about it. A PDM decimator is not a device Chipyard ships. A
GPIO controller is.

Two details that are easy to get wrong:

**`WithGPIOPunchthrough` has to be named explicitly, and it has to win.** `AbstractConfig`
contains `chipyard.iobinders.WithGPIOCells`, which would wrap each pin in an `IOCell` and
present six `Analog(1.W)` inouts at ChipTop — an IOBUF apiece and a tri-state question the
FPGA top would have to answer. `WithGPIOPunchthrough` is an `OverrideIOBinder`, so putting
it in this config replaces that and brings sifive's `GPIOPortIO` bundle straight out. Same
shape as `WithPdmMicPunchthrough`.

**The address.** `0x1001_0000` is Chipyard's own default for `WithGPIO` and is clear of
everything in this SoC — checked against the generated DTS, not against memory: bootrom
`0x1_0000`, CLINT `0x200_0000`, L2 control `0x201_0000`, TACIT `0x300_0000`/`0x301_0000`,
PLIC `0xC00_0000`, UART `0x1002_0000`, the microphone `0x1009_0000`, `0x1008_0000` which
`CAMERA_PCB_SPEC.md` reserves for the camera, DRAM `0x8000_0000`.

### 3.1 What it does add, and did not break: the PLIC

sifive's GPIO declares `nInterrupts = c.width`, and `GPIOAttachParams.attachTo` binds the
interrupt node unconditionally. There is no fragment to turn that off, so the PLIC grows.
Measured, from the generated DTS:

```dts
gpio@10010000 { interrupts = <2 3 4 5 6 7>; ... }
serial@10020000 { interrupts = <1>; ... }
interrupt-controller@c000000 { riscv,ndev = <7>; ... }
```

**The UART kept source 1.** The six GPIO sources were appended above it, not below, so
`boards/chipyard/pynqz1_micrgb`'s `interrupts = <1 1>` is `pynqz1_mic`'s line verbatim.
That was checked rather than assumed, because the failure mode if it *had* moved is a dead
console on a board that otherwise looks healthy — and `MICROPHONE.md` §8.2 records that
this SoC's `riscv,ndev = <1>` was the reason the microphone deliberately has *no*
interrupt at all.

Nothing in this design uses the six GPIO interrupts. They exist because the controller has
them; the LEDs are outputs. They still have to be transcribed correctly, because
`sifive,gpio0.yaml` makes `interrupts` a required property and `gpio_sifive.c`
`IRQ_CONNECT`s one per entry.

### 3.2 Evidence that the other configs are undisturbed

The strongest form available, and it is stronger than the microphone's: **there is no
Chipyard patch.** `PynqZ2Configs.scala` gains one class at the end of the file, and a Scala
class that nothing references cannot change another config's elaboration. The microphone
had to *measure* its containment (`MICROPHONE.md` §9.2, 506 files byte-identical) because
it edited `DigitalTop.scala`, `Ports.scala` and `IOBinders.scala`, which every config
elaborates through.

It was measured anyway, and the result is cleaner than the microphone's. Snapshotting the
mic config's elaboration, adding the RGB class, and re-elaborating gives **517 of 517
generated files byte-identical — before stripping FIRRTL's `@[...]` source-location
comments, not after.** The microphone needed that stripping because it inserted fifteen
lines into `IOBinders.scala` and shifted every line number below them; this needed none,
because it edited no file any other config elaborates through.

---

## 4. Out to the pins, and the check that the routed design agrees

### 4.1 The structural top

`src/pynqz2_rocket_top.v` gains one port and one block, both inside
`` `ifdef PYNQZ2_HAS_RGB ``, for the reason `MICROPHONE.md` §8.3 gives: for the four builds
without RGB LEDs (`tacit`, `smp`, `pext`, `mic`) the lines vanish entirely, so their RTL is textually unchanged and `u_soc`
keeps its hierarchy path and therefore its placement. **`RGB_DUTY` is inside the `ifdef`
too**, so even the module header is byte-identical for them.

That is checked rather than asserted. Preprocessing the file before and after the change,
with no defines and with `PYNQZ2_HAS_MIC` only:

```
=== no defines  (tacit / smp / pext builds) ===   IDENTICAL (180 non-blank lines)
=== PYNQZ2_HAS_MIC  (mic build) ===               IDENTICAL (184 non-blank lines)
```

`WithGPIOPunchthrough` presents ten signals per pin (`EnhancedPin`: `oval`, `oe`, `ie`,
`pue`, `ds`, `ps`, `ds1`, `poe` out; `ival`, `po` in), so sixty ChipTop ports. They are
written out one pin at a time with the colour named on the line that makes the connection,
rather than generated by a `` `define `` with token pasting: the thing most likely to be
wrong is the bit order, and the only defence against that is being able to read it.

### 4.2 The constraints are their own file

`src/pynqz2_rgb.xdc`, added to `constrs_1` by `tcl/build_rocket.tcl` **only** for the
`micrgb` variant. Not a guarded block inside the shared `pynqz2_rocket.xdc`. This is the
bug `MICROPHONE.md` §8.3 paid a build to learn: Vivado 2023.1 parses everything in
`constrs_1` as XDC, a restricted subset with no `if` and no `foreach`, and answers a
conditional with

```
CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported in the xdc constraint file
```

and then **runs neither branch**. The design places anyway, because unconstrained I/O is
auto-placed — so the thing heading for the board would be a bitstream with six LED signals
on six arbitrary balls, and nobody here can see the board to notice. Conditional *file
inclusion*, from real Tcl, is what works.

### 4.3 The post-route assertion

The microphone's pin check runs after synthesis and reads `get_property PACKAGE_PIN`. That
answers "did the XDC parse", which is a genuinely useful question and not the same one as
"is the signal on that ball". Since nobody can look at this board, the second question gets
asked too, of the **routed** design:

```tcl
report_io -file $build/reports/post_route_io.rpt
foreach {port want} $rgb_pins {
  set pkg [get_package_pins -quiet -of_objects [get_ports $port]]
  set pkgname [get_property NAME $pkg]
  if {$pkgname ne $want} {
    error "ROUTED DESIGN PUTS $port ON BALL $pkgname, NOT $want. ..."
  }
  ...
}
```

`get_package_pins -of_objects` is answered by the placer, not by the XDC parser. Alongside
it, `IS_LOC_FIXED` is required to be non-zero: a port that landed on the right ball by
accident, unconstrained, is not the same as a port that is constrained there, and only the
second survives a re-place. (That check is wrapped in a `catch` so a property a future
Vivado renames reports itself rather than destroying an hour of place-and-route at the last
line; the ball comparison is the one that is fatal.)

**The table is written three times, independently**, and all three are checked against the
implemented design:

1. `src/pynqz2_rgb.xdc` — what is constrained
2. `tcl/build_rocket.tcl`'s `rgb_pins` — asserted post-synthesis *and* post-route
3. `fpga/pynq-z2/scripts/build_micrgb_z1.sh`'s `RGB_TABLE` — re-checks the `RGB_PIN:`
   lines the TCL printed, **and** greps `reports/post_route_io.rpt`, which is generated
   from the placement and readable without Vivado

Any two of them disagreeing is a loud error rather than a wrong bitstream. What that buys
is narrow and worth being precise about: it makes "the design drives L15" a *measurement*.
It says nothing about what L15 is attached to. §1 is the only evidence for that, and §6 is
the honest summary.

---

## 5. The Zephyr side: also stock, also no patch

Zephyr has shipped `drivers/gpio/gpio_sifive.c` and
`dts/bindings/gpio/sifive,gpio0.yaml` since 2017. The generated register map matches the
driver's `struct gpio_sifive_t` field for field:

| offset | driver field | generated regmap |
|---|---|---|
| 0x00 | `in_val`  | `input_value`   R, 6 bits |
| 0x04 | `in_en`   | `input_en`     RW |
| 0x08 | `out_en`  | `output_en`    RW |
| 0x0C | `out_val` | `output_value` RW |
| 0x10 | `pue`     | `pue`          RW |
| 0x14 | `ds`      | `ds0`          RW |
| 0x18–0x34 | `rise_ie` … `low_ip` | same order, same names |
| 0x38 | `iof_en`  | **`reserved`, R** |
| 0x3C | `iof_sel` | **`reserved`, R** |
| 0x40 | `invert`  | `out_xor`      RW — the same register under another name |

Two rows there are worth a second look, because they are the sort of thing that usually
bites.

`WithGPIO` leaves `includeIOF = false`, so the two IOF registers the driver knows about
are generated as read-only `reserved` fields. `gpio_sifive_init()` writes zero to
`iof_en`, `iof_sel` **and** `invert` before doing anything else. Writing zero to a
read-only `RegField` in rocket-chip's `RegMapper` is dropped, not faulted — no error
response, no trap — and zero is what those fields already read. So the driver's init is
correct here by accident rather than by design, and §9 is the evidence that it actually
is: the controller probes and every subsequent access works.

`invert` / `out_xor` is the same register and it matters that the driver zeroes it: it is
a per-pin XOR on the way out (`port.pins(pin).o.oval := pre_xor.oval ^ xorReg(pin)` in
sifive's GPIO). Left non-zero it would invert the polarity of individual dice, silently,
and the active-high mapping in the devicetree would be a lie for those pins.

A **four**-byte stride, unlike the microphone's eight. `MICROPHONE.md` §8.2 had to space
that peripheral's registers a bus word apart because `pdm_mic_core` is a BlackBox with one
shared `reg_addr` port and the periphery bus is 64 bits wide. sifive's GPIO is a proper
`RegMapper` device, so the question does not arise.

`boards/chipyard/pynqz1_micrgb/` is `pynqz1_mic` plus the `gpio@10010000` node, a
`gpio-leds` node and one Kconfig line:

```
CONFIG_GPIO=y      # CONFIG_GPIO_SIFIVE is default-y once the node is enabled
```

No existing board definition was touched. `ngpios = <6>` is set so that
`GPIO_PORT_PIN_MASK_FROM_DT_INST` gives the driver a six-bit port mask and a stray write to
pin 6 returns `-EINVAL` instead of reaching a register bit the hardware does not have.

The `gpio-leds` node gives an application a `gpio_dt_spec` per die with the polarity
attached, so `samples/rgb_led_walk` never mentions a pin number or an active level:

```dts
ld4_red: ld4_red { gpios = <&gpio0 2 GPIO_ACTIVE_HIGH>; label = "LD4 red"; };
```

---

## 6. What is proven, and what is waiting for a person

This is the section to read if you read only one.

> **Settled, 2026-09-16.** A person watched the walk on the bench board and reported the
> sequence as specified: red, green, blue on LD4; then red, green, blue on LD5; then both
> lit white. That is the observation this section was written to make possible, and it
> confirms the §1 mapping end to end — including the one failure the walk exists to catch,
> a reversed vector, which parks looking correct and is only distinguishable while the
> sequence is running. The paragraphs below record why it had to be done this way.

**There is no readback path for an output pin.** Nothing running on this board, and nothing
running on the workstation, can establish that the LED silkscreened LD4 turned red. That is
not a gap that more engineering closes; it is what an output is. So the claims are split,
and the weak one is named.

### Established by construction

- **The mapping.** Two independent vendor sources, from two vendors, in two kinds of
  artifact, agreeing on all six assignments (§1.2, §1.3). One of them has already been
  checked against this physical board for a different signal (§1.3).
- **The polarity**, from the reference manual's own words (§1.4).

### Established by measurement, at build time

- **Each of the six ports is on the ball the mapping names, in the routed design** —
  `get_package_pins -of_objects` on the implemented netlist, `IS_LOC_FIXED` non-zero, the
  same facts re-checked out of `report_io`'s text by a script holding its own copy of the
  table (§4.3).
- **The four builds without RGB LEDs see textually identical RTL** (§4.1), and all four
  still build (§10).

### Established by measurement, on the board

- **Every step's six-bit pattern reads back correctly** through the controller's
  `input_value` register — so the path Zephyr → `output_value`/`output_en` → six ChipTop
  ports → the FPGA top → `input_value` carries the bit vector unpermuted and untruncated
  (§9). With all six off the readback is `000000` and not `111111`, so that comparison is
  not passing through an inverted pad model.
- **A second bus master agrees.** The ARM samples `STATUS[9:4]` over `M_AXI_GP0` — the six
  signals on their way to the OBUFs, pre-chopper — while the guest runs, with no
  cooperation from the guest at all, and sees the same eight distinct patterns (§9). Rocket
  writes over TileLink; the ARM reads over AXI. That is the closest thing to an independent
  witness these pins have.

  It is *not* fully independent, and the limit is worth naming: both observers watch the
  same `rgb_drive` vector inside the FPGA top. They prove the vector reaches that point
  intact from two directions. They cannot see a permutation applied at the ChipTop
  connections, because both of them would see it identically. §6's last subsection says
  what does catch that.

### NOT established by anything automatic

- ~~**That N15 is LD4's red cathode.** Only a person can settle that.~~ **Settled 2026-09-16** by a
  person watching the walk (`e611ad1`; status updated 2026-09-17).
- **That the LED brightness is comfortable**, or that 12.5% duty is visible enough in a
  lit room. §2 argues it; nobody has looked.
- **What "both on" actually looks like.** It should be a pale, probably blue-green-tinted
  white, for the reason in §2.

### What one glance settles

`scripts/35_rocket_rgb_leds.sh` leaves the board **parked at LD4 red + LD5 blue**, and that
state is held indefinitely — the guest returns from `main()` and the GPIO registers keep
their value.

That pattern is asymmetric on purpose. "Both white" looks the same under *any* permutation
of the six bits; "one red and one blue, and specifically *that* one red" does not. Being
precise about how much it settles, since the whole section is about not overclaiming:

**The parked state is the quick check.** It separates the correct mapping from the two
plausible ways of getting it wrong:

| what you see, parked | what it means |
|---|---|
| **LD4 red, LD5 blue** | consistent with §1 |
| **LD4 blue, LD5 red** | either the two three-bit groups are swapped (bits 0–2 went to LD5), or red and blue are swapped inside each group. The walk tells you which — see below |
| both dark | the chopper, the OBUFs or the balls. **Not** the register path: the readbacks in §9 already cleared that |
| any green | the middle bit of a group is reaching a die it should not |

**The walk is the complete check**, and it is why the run is 22 seconds long rather than
one frame. Three failure modes survive the parked state and none survives the sequence:

- *groups swapped* — the console says `LD4 red` and **LD5** lights;
- *red/blue swapped within a group* — the console says `LD4 red`, LD4 lights, and it is
  **blue**; the group then runs blue → green → red instead of red → green → blue;
- *the whole six-bit vector reversed* — this one parks as `LD4 red, LD5 blue` and looks
  **completely correct**, because bit 2 and bit 3 exchange places and so do their
  meanings. Only the sequence catches it: `LD4 red` would light LD5's blue.

Each console line is printed **before** its 1-second hold, so the console and the board are
in step, and the eight patterns are distinct enough that one pass is enough.

**None of these would be caught by anything in §9**, which is the point of saying it out
loud: the readback loops back through the same six-bit vector inside the FPGA top, so a
permutation of that vector reads back exactly as permuted and compares equal. The routed
pin gate (§4.3) catches a *port* landing on the wrong ball; it cannot catch the six ports
being connected to the wrong bits of `rgb_led` inside the top. That is what the eye is for,
and it is why `pynqz2_rocket_top.v` writes the sixty ChipTop connections out one pin at a
time with the colour named on each line instead of generating them.

---

## 7. Area and timing — measured

`build_rocket_micrgb_z1/reports/post_route_util.rpt` against
`build_rocket_mic_z1/reports/post_route_util.rpt` — the same design without the RGB LEDs,
same clock, same part, same vendored collateral path.

**Both builds were re-measured after `patches/0030` removed the TACIT branch predictor**
(`TACIT_AREA.md`), which took ~6,170 LUT out of each of them. The A/B is therefore given
twice: as first measured, and on the bitstreams that ship today. The **delta is the same
delta** — which is the useful result, because it says the GPIO's cost does not depend on
how full the part is around it.

| | P-ext + mic | **+ RGB LEDs** | delta |
|---|---|---|---|
| Slice LUTs | 34,724 (65.27%) | **35,358 (66.46%)** | **+634** |
| — as logic | 32,159 | 32,787 | +628 |
| — as memory | 2,565 | 2,571 | +6 |
| Slice Registers | 20,410 | 20,638 | **+228** |
| Occupied Slices | 10,272 (77.23%) | 10,540 (79.25%) | +268 |
| Block RAM Tile | 65.5 | 65.5 | **0** |
| DSP48E1 | 42 | 42 | **0** |
| Bonded IOB | 6 | 12 | **+6** |
| WNS | +1.101 ns | **+1.169 ns** | **+0.068** |
| WHS | +0.011 ns | **+0.024 ns** | **+0.013** |

As first measured, with the predictor still elaborated in both:

| | P-ext + mic | + RGB LEDs | delta |
|---|---|---|---|
| Slice LUTs | 40,561 (76.24%) | 41,218 (77.48%) | +657 |
| — as logic | 37,986 | 38,637 | +651 |
| — as memory | 2,575 | 2,581 | +6 |
| Slice Registers | 24,645 | 24,873 | +228 |
| Occupied Slices | 12,073 (90.77%) | 12,147 (91.33%) | +74 |
| Bonded IOB | 6 | 12 | +6 |
| WNS / WHS | +1.153 / +0.006 ns | +1.067 / +0.029 ns | −0.086 / +0.023 |

**657 against 634 is 23 LUT, and the flip-flop figure is identical to the register.**
228 FF both times, +6 LUT-as-memory both times, +6 IOB both times. The 23-LUT difference
is placement, not structure — the same order as the run-to-run spread §5 already records
for the queues inside the encoder. The timing delta changed sign (−0.086 then +0.068),
which is what a design with 11,982 free LUT and one with 17,842 free do differently with
the same added peripheral; both are comfortably positive at 29.000 ns.

Both builds come from the vendored collateral with `CHIPYARD_DIR` unset, from bundles that
record the same `chipyard_rev` and the same `rocketchip_rev` with the same two patches
applied — so this is an A/B on one generator and the delta is attributable to the GPIO
controller and not to a moved submodule.

**+634 LUT for a peripheral, a crossbar port, six IOBs and a chopper** (+657 as first
measured). Post-*synthesis* the first pair was +669, so opt and phys_opt trimmed 12:
essentially nothing was redundant. The split is
worth knowing, and it is the same split `MICROPHONE.md` §4.2 found: the block itself is
small and the **TileLink attachment is most of the cost** — the periphery-bus crossbar goes
from 3 outputs to 4 (`TLXbar_pbus_out_i1_o3_…` is replaced by `…_o4_…`), which brings a
fragmenter, a buffer and their monitors, and the PLIC grows six inputs with an
`IntXbar`, an `IntSyncCrossingSource_n1x6` and an `IntSyncSyncCrossingSink_n1x6` behind
them. The chopper is 8 flops and about a dozen LUTs of the 634.

**Six more registers than the controller has pins × 4.** 228 FF for a 6-pin controller is
the `AsyncResetRegVec_w6_i0` instances (`oe`, `pue`, `ie`, `poe`), the rise/fall/high/low
enable and pending registers, the 3-deep `SynchronizerShiftReg_w6_d3` on the input path,
the 8-bit chopper counter, and the interrupt-crossing pipeline. sifive's GPIO is a fuller
peripheral than "six output bits" suggests; most of what it costs is interrupt machinery
this design does not use (§8).

**Zero DSP and zero BRAM**, as expected — there is no arithmetic and no storage here.

**Timing did not become a problem, and it moved in both directions.** On the shipping
pair WNS *rose* 0.068 ns and WHS rose 0.013 ns; on the first pair WNS fell 0.086 and WHS
rose 0.023. The critical path is where it has always been, in the L2 MSHR scheduler, and
0.086 ns on a 28.999 ns period is 0.3% — placement noise, and the sign flip across two
measurements of the same structural change is the clearest possible statement that it is
noise and not a cost. For comparison, adding the microphone moved WNS the other way by
0.027 ns. Neither number is a trend; both are what a few hundred LUT does to a placer.
**0 endpoints fail** in either build, and the DRC report's rule table is byte-identical to
the microphone build's — 112 entries, all `Warning`, the same pre-existing DSP-pipelining
and RAMB18-async advisories every build here carries.

Against the headroom the shipping build starts with — 53,200 − 34,724 = **18,476 spare
LUT** — the RGB LEDs use **3.4%** of what is free, and the full-feature bitstream leaves
**17,842 LUT** for whatever comes next. Against the headroom this study started with
(12,639, before the TACIT predictor came out) it was 5.2%.

### 7.1 What the SoC change touched, measured

Same treatment as `MICROPHONE.md` §9.3, on the two vendored bundles with FIRRTL's
`@[...]` source-location comments stripped: **441 generated files against 453.**

New: `TLGPIO.sv`, `TLInterconnectCoupler_pbus_to_device_named_gpio_0.sv`,
`ClockSinkDomain_2.sv`, `FixedClockBroadcast_4.sv`, `AsyncResetRegVec_w6_i0.sv`,
`SynchronizerShiftReg_w6_d3.sv`, `IntSyncCrossingSource_n1x6.sv`,
`IntSyncSyncCrossingSink_n1x6.sv`, `IntXbar_i2_o1.sv`, two fragmenters, a buffer,
`TLXbar_pbus_out_i1_o4_…` and three monitors. Gone: `TLXbar_pbus_out_i1_o3_…` and the
fragmenter, buffer and monitor it displaced.

125 of the common files differ. Normalising `TLMonitor_<n>` to a single token collapses 44
of those to identical, and **62 of the remaining 81 are a `TLMonitor_N.sv` being compared
with a renumbered `TLMonitor_N.sv`** — two different monitors, because adding a bus port
renumbers every one of them. (`RocketTile.sv`'s entire diff is likewise two
`TLFragmenter_2` → `TLFragmenter_3` instance names.) That leaves **nineteen** substantive
files, and every one of them is the address map or the interrupt map:

| file | what changed |
|---|---|
| `ChipTop.sv` | **+60 ports** — ten signals × six `EnhancedPin`s |
| `DigitalTop.sv` | the controller, its crossbar port, its interrupt node |
| `PeripheryBus_pbus.sv` | the pbus crossbar grows from 3 outputs to 4 |
| `PMAChecker.sv`, `PMAChecker_3.sv`, `PTW.sv` | `legal_address` gains **exactly `17'h10010`** — one per hart, plus the page-table walker. The GPIO page is in the map, as MMIO and not as memory. This is the diff worth reading; it is the whole SoC change in one term |
| `TLPLIC.sv`, `PLICFanIn.sv`, `PLICClockSinkDomain.sv` | six new interrupt inputs (`auto_int_in_1` … `auto_int_in_5`) |
| `TLROM.sv` | the bootrom's embedded DTB gains the node — 444 lines, all of it the flattened device tree |
| `SBToTL.sv`, `TLXbar_sbus_…` | address-decode terms shift as the map changes |
| `ClockSinkDomain_1.sv`, `TLFragmenter.sv`, `TLInterconnectCoupler_pbus_to_pdmmic.sv`, `FixedClockBroadcast_3.sv`, `MemoryBus.sv`, `RocketTile*.sv` | **same filename, different module.** The GPIO takes `ClockSinkDomain_1` and `TLFragmenter`, pushing the microphone's to `_2` and `_1`; these diffs are the monitor artifact again, one level up |

---

## 8. The buttons and the switches: what they would cost

The same controller would reach the four push-buttons (D19, D20, L20, L19) and the two
slide switches (M20, M19). Both board files agree on those six balls, and unlike the RGB
LEDs there is no colour question: `btns_4bits_tri_i_0..3` and `sws_2bits_tri_i_0..1` are
self-describing, and §12 of the reference manual says the buttons "normally generate a low
output when they are at rest, and a high output only when they are pressed" — active high,
no debounce hardware.

**This was not implemented.** It was not asked for, and it is not free. The marginal cost,
as an estimate and labelled as one:

| | |
|---|---|
| Config change | `WithGPIO(width = 12)` instead of `6` — one character |
| PLIC | **grows again**, `riscv,ndev` 7 → 13. Whether the UART keeps source 1 is not something to assume — it did at width 6, and the only honest way to know at width 12 is to read the generated DTS again |
| Top-level RTL | six more ports, six more 10-signal port groups, and the `ival` path becomes a **real input** rather than the internal loopback this design uses (§6) |
| XDC | a second constraint file, or six more lines in `pynqz2_rgb.xdc` |
| Zephyr | one more devicetree node (`gpio-keys`), no new driver |
| LUT | **estimate, and a weak one**: most of the measured 657 is the bus attachment and the interrupt crossing, which are paid once and do not double. The per-pin part — four `AsyncResetRegVec` bits, the synchroniser stage, the interrupt gateway — looks like a few tens of LUT per pin, so **~100-250 LUT for six more pins**, against 11,982 still spare. Labelled an estimate because nobody has built it; the honest way to get the number is `WithGPIO(width = 12)` and one synthesis run |

The reason not to fold it in silently is the third row. Every output pin in this design is
driven by something inside the FPGA; a button is the first signal that arrives from
outside it, asynchronously, from a mechanical contact. sifive's GPIO does put a three-deep
`SynchronizerShiftReg` on `ival`, so metastability is handled — but contact bounce is not,
and a design that raises six PLIC sources from bouncing contacts has a failure mode
(interrupt storms) that this one cannot have. That is a real design question with a real
answer, and it deserves its own decision rather than being smuggled in under "the
controller was going to be there anyway".

**Per-channel PWM**, for actual colour mixing rather than the fixed brightness limit of §2,
is the other obvious extension and is also priced rather than built. Chipyard ships
sifive's PWM block and this tree already has `chipyard.iobinders.WithPWMPunchthrough` and a
`PWMPort` case class, so the plumbing exists. The catch is that a sifive PWM block's
comparator 0 sets the shared period and cannot be used as an output, so six channels need
**two** blocks (7 usable comparators between them) plus their register files —
substantially more than the chopper, which is 8 flops and a comparator — of the order of a
dozen LUT, though it is small enough that it does not separate out of the measured 657 and
that figure is an estimate. For something no lab here needs. Noted, not done.

---

## 9. On hardware

```
scripts/with_board.sh ./scripts/35_rocket_rgb_leds.sh
```

### 9.1 The bitstream

`fpga/pynq-z2/scripts/build_micrgb_z1.sh`, five gates then Vivado 2023.1:

```
=== [0/5]  GP0 register file (DRAM self-test)   34 checks passed
=== [0b/5] GP0 register file (Rocket/SoC)       44 checks passed
=== [0c/5] datapath integration                 16 checks passed
=== [0d/5] PDM microphone decimator             24 checks passed
=== [0e/5] MBP RTL selftest                     SKIPPED (CHIPYARD_DIR unset)
=== [2/2] the six RGB pins, in the routed design ===
  ok    rgb_led[0] -> L15   (routed design, and .../post_route_io.rpt agrees)
  ok    rgb_led[1] -> G17   (routed design, and .../post_route_io.rpt agrees)
  ok    rgb_led[2] -> N15   (routed design, and .../post_route_io.rpt agrees)
  ok    rgb_led[3] -> G14   (routed design, and .../post_route_io.rpt agrees)
  ok    rgb_led[4] -> L14   (routed design, and .../post_route_io.rpt agrees)
  ok    rgb_led[5] -> M15   (routed design, and .../post_route_io.rpt agrees)

MIC_PIN: mic_pdm_clk -> F17
MIC_PIN: mic_pdm_data -> G18
RGB_PIN: rgb_led[0] -> L15  site IOB_X1Y105  fixed 1
RGB_PIN: rgb_led[1] -> G17  site IOB_X1Y118  fixed 1
RGB_PIN: rgb_led[2] -> N15  site IOB_X1Y108  fixed 1
RGB_PIN: rgb_led[3] -> G14  site IOB_X1Y149  fixed 1
RGB_PIN: rgb_led[4] -> L14  site IOB_X1Y106  fixed 1
RGB_PIN: rgb_led[5] -> M15  site IOB_X1Y103  fixed 1
ACHIEVED_FCLK_HZ: 34482761
TIMING_WNS: 1.067
TIMING_WHS: 0.029
BITSTREAM_OK: build_rocket_micrgb_z1/pynqz1_rocket_micrgb.bit
```

Built from the **vendored** generated Verilog with `CHIPYARD_DIR` unset, so the bundle in
`chipyard/gensrc/` is demonstrably sufficient — no Chipyard install is needed to reproduce
this bitstream.

**A third confirmation of the mapping fell out of that report, unlooked for.**
`reports/post_route_io.rpt` names each ball's *pin function* from Vivado's own package
database for `xc7z020clg400-1`:

| ball | Vivado's pin function | Digilent's comment on that line |
|---|---|---|
| L15 | `IO_L22N_T3_AD7N_35` | `#IO_L22N_T3_AD7P_35 Sch=LED4_B` |
| G17 | `IO_L16P_T2_35` | `#IO_L16P_T2_35 Sch=LED4_G` |
| N15 | `IO_L21P_T3_DQS_AD14P_35` | `#IO_L21P_T3_DQS_AD14P_35 Sch=LED4_R` |
| G14 | `IO_0_35` | `#IO_0_35 Sch=LED5_B` |
| L14 | `IO_L22P_T3_AD7P_35` | `#IO_L22P_T3_AD7P_35 Sch=LED5_G` |
| M15 | `IO_L23N_T3_35` | `#IO_L23N_T3_35 Sch=LED5_R` |

Six for six. (The one character of disagreement is Digilent's: they write `AD7P` on the
L22**N** line, where the silicon's N-side is `AD7N`. Vivado is right and it does not move
the ball. In fact it strengthens the reading — L14 and L15 are the P and N halves of the
same differential pair `L22_T3`, which is why LD5's green and LD4's blue are adjacent
balls, and the pair structure is a property of the package that no transcription error can
invent.)

That is not a fourth independent source for the *colour* — Vivado knows nothing about the
PCB. It is an independent confirmation that the two vendor files are talking about the same
six physical balls of this package, which is the half of the claim that could have been a
transcription error.

### 9.2 What the board did

```
*** Booting Zephyr OS build 4329bf61c4fe ***
RGB_LED_WALK starting
RGB: controller gpio@10010000, 6 pins
RGB: quiescent readback 000000 (expect 000000) ok
RGB: WHAT YOU SHOULD SEE -- 2 cycles of 11 steps at 1000 ms, 22 s in total:
RGB: IT THEN STOPS AND HOLDS LD4 RED + LD5 BLUE. That is the state to check.
RGB: t=     0 ms  cycle 1 step  1/11  all dark                 drive=000000 read=000000 ok
RGB: t=  1009 ms  cycle 1 step  2/11  LD4 red                  drive=000100 read=000100 ok
RGB: t=  2017 ms  cycle 1 step  3/11  LD4 green                drive=000010 read=000010 ok
RGB: t=  3025 ms  cycle 1 step  4/11  LD4 blue                 drive=000001 read=000001 ok
RGB: t=  4033 ms  cycle 1 step  5/11  LD4 dark                 drive=000000 read=000000 ok
RGB: t=  5041 ms  cycle 1 step  6/11  LD5 red                  drive=100000 read=100000 ok
RGB: t=  6049 ms  cycle 1 step  7/11  LD5 green                drive=010000 read=010000 ok
RGB: t=  7057 ms  cycle 1 step  8/11  LD5 blue                 drive=001000 read=001000 ok
RGB: t=  8065 ms  cycle 1 step  9/11  LD5 dark                 drive=000000 read=000000 ok
RGB: t=  9073 ms  cycle 1 step 10/11  BOTH on (all six dice)   drive=111111 read=111111 ok
RGB: t= 10081 ms  cycle 1 step 11/11  all dark                 drive=000000 read=000000 ok
...
RGB: PARK  LD4 RED + LD5 BLUE  drive=001100 read=001100 ok
RGB: elapsed 22181 ms for 22 steps of 1000 ms (expect 22000)
RGB: readbacks 24 ok, 0 mismatched
RGB: DONE
```

The first line after the banner is the driver's probe: Zephyr's stock `gpio_sifive.c`
found a controller at `0x1001_0000` through a TileLink register node, with no code written
here at all.

**22,181 ms for 22 one-second steps** — 0.8% long, which is `k_msleep`'s rounding plus the
console write per step, and it means the printed schedule is the schedule a person watching
actually saw.

### 9.3 And what the ARM saw, at the same time

```
  host : 180 GP0 samples, 9 distinct patterns
  the guest drove these patterns, and the ARM saw each one over GP0:
      0b000000 -none-                        seen by host
      0b000001 LD4.blue                      seen by host
      0b000010 LD4.green                     seen by host
      0b000100 LD4.red                       seen by host
      0b001000 LD5.blue                      seen by host
      0b010000 LD5.green                     seen by host
      0b100000 LD5.red                       seen by host
      0b111111 LD4.blue,...,LD5.red          seen by host
  parked state, guest says : 0b001100 LD4.red,LD5.blue
  parked state, host says  : 0b001100 LD4.red,LD5.blue
```

and afterwards, with the guest idle and returned from `main()`:

```
MAGIC = 0x5A5A0006 OK
RGB_STATUS status=0x000000C7 rgb=0b001100 value=12 lit=LD4.red,LD5.blue
```

`0xC7` is `alive | resetn | saw_mem` in the low nibble — exactly what `STATUS` has always
meant — with `0b001100` in bits [9:4]. **Rocket wrote those bits over TileLink; the ARM
read them over `M_AXI_GP0`, in a different process, as a different master, with no
cooperation from the guest.** The ninth distinct pattern the watcher saw is the parked
`0b001100` itself, which the guest drives after its last step.

All **23** golden checks pass against `expected/rgb_led_walk.json`. Two runs back to back
produced identical numbers — 24/24 readbacks, 22,181 ms, 180 samples, the same eight
patterns.

### 9.4 Running this with nothing but the micro-USB cable

`scripts/35_rocket_rgb_leds.sh` reaches the board over ssh and scp, like every other Lab B
script here. **At the tutorial the boards are not networked** — one micro-USB cable, and
that is all — so it is worth being explicit about which parts of this lab survive that and
which do not.

The topology is already in `UART.md` §B and it is friendlier than it sounds. The single
micro-USB carries FT2232 channel A (JTAG) and channel B, and channel B lands on PS
MIO14/15, which is the **Linux console** on `/dev/ttyPS0`. Rocket's own console is
cross-connected in the PL to PS UART1 on EMIO and appears *on the board* as
`/dev/ttyPS1`. So one cable gets you a shell on the ARM, and from that shell
`screen /dev/ttyPS1 115200` is Rocket.

| step | over serial alone |
|---|---|
| load the PL | **fine.** `run_rocket_micrgb.py --bitstream … --hold`, typed at the serial shell, provided the `.bit` is already on the SD card |
| load the guest | **fine**, same way |
| watch the console | **fine** — `/dev/ttyPS1` is a device on the board, not a network resource |
| the ARM's GP0 cross-check | **fine** — `read_rgb_status.py` runs on the board and prints to the same shell |
| **getting the files there** | **this is the part that does not work.** `pynqz1_rocket_micrgb.bit` is 4.0 MB and `zephyr.bin` is 44 KB. At 115200 baud, with a protocol, that is about six minutes for the bitstream and five seconds for the guest. The bitstream has to be pre-staged on the SD card |
| **getting results back** | **not needed here, and that is unusual.** |

That last row is the interesting one and it is specific to this lab. Every other hardware
lab in this repo produces an artifact that has to reach the workstation to mean anything —
a trace to decode, a WAV to analyse, a tensor to diff. **The result of this one is
photons.** The console narration is a few hundred bytes and is already readable on the
serial terminal; the thing being demonstrated is on the board, in the room, visible from
across it. Nothing has to come back.

So of the whole repo, this is the lab that degrades best to a cable and a terminal: stage
the `.bit` on the card once, and everything after that is typing. The ssh/scp in the runner
is an artifact of this bench having a network, not a requirement of the lab.

(What genuinely could not be done over serial: rebuilding `zephyr.bin` with a different
`RGB_STEP_MS` requires the Zephyr toolchain, i.e. the workstation, and then the 44 KB
image has to get across — five seconds of `xmodem`, but it needs one. Building the
bitstream needs Vivado and is out of scope for the container, let alone the cable.)

### 9.5 What this does not show

- ~~**Nobody has looked at the board.**~~ **Settled 2026-09-16** (status updated 2026-09-17): a
  person watched the walk and confirmed the mapping (`e611ad1`). The rest of §9 is still a bit vector
  agreeing with itself through two independent paths; §6 says what that is worth.
- **The brightness is unverified.** 12.5% duty on an LED the vendor calls "uncomfortably
  bright" at 100% should be comfortable and clearly visible; that is an argument, not a
  measurement.
- **The six GPIO interrupts have never fired.** They exist because sifive's controller
  declares one per pin; nothing here uses them, and nothing here has tested them. An input
  application (§8) would be the first thing that did.

---

## 10. Regressions

Four things could have disturbed existing work. All four were checked rather than argued.

**The Chipyard generator: not touched.** There is no patch (§3), and the containment was
measured anyway — re-elaborating `PynqZ2RocketBigLittlePextTacitMicConfig` with the new
class present gives **517 of 517 generated files byte-identical, before any comment
stripping** (§3.2).

**The structural top and the shared build TCL**, which all five Rocket variants use. The
RGB port, the `RGB_DUTY` parameter and the whole drive block are behind
`` `ifdef PYNQZ2_HAS_RGB ``, and the preprocessed RTL for the other builds is **identical**
(§4.1). `tcl/build_rocket.tcl`'s new `micrgb` arm and its three `if {$has_rgb}` blocks are
inert when `has_rgb` is 0, which it is for every other variant.

That was measured, not argued, and the result is as good as it gets: **`build_pext_z1.sh
synth` through the modified script produces a `post_synth_util.rpt` that is byte-identical
to the tracked pre-change one except for the `| Date :` line.** Same 40,969 LUT, 24,133 FF,
64 BRAM, 41 DSP, **4 bonded IOB** — four, so the six RGB ports did not appear. The
`RGB_PIN_SYNTH:` and `MIC_PIN:` blocks echo in the log as un-executed script text and emit
nothing, which is `has_rgb`/`has_mic` being 0 seen from the outside. (The regenerated
report was reverted; only its date differed.)

**Zephyr: not touched.** `scripts/02_verify_patches.sh` still reports the kernel as
`base 4329bf61c4f` + exactly the two tracked patches, i.e. this work added no Zephyr edit
of any kind. `boards/chipyard/pynqz1_micrgb` is a new sibling; no existing board definition
was modified. `hello_world` builds on all five boards.

**The board.** Loading the RGB bitstream overwrites the PL, so the two labs that share this
part of the bench were re-run after it and both pass:

| lab | result |
|---|---|
| `29_rocket_pext_run.sh` | PASS — hart 0 computed all four MBP ops, hart 1 raised four illegal-instruction traps |
| `34_rocket_mic_capture.sh` | PASS — all 15 golden checks, real audio through the DMIC API |
| `35_rocket_rgb_leds.sh` | PASS — 23/23, and it is what the board is left holding |

**This lab leaves the board with the RGB bitstream loaded (MAGIC `0x5A5A0006`) and the LEDs
parked at LD4 red + LD5 blue**, deliberately, because §6 needs somebody to look at it.

But the bench has one board and more than one workstream, and every Lab B script loads its
own PL. So **the parked state survives only until the next lab runs**, and if what you find
is dark LEDs the first thing to check is which bitstream is actually in there:

```bash
scripts/with_board.sh ssh $PYNQ_HOST \
  "cd \$PYNQ_DIR && sudo python3 read_rgb_status.py"     # prints MAGIC and the six bits
```

`MAGIC = 0x5A5A0006` and dark LEDs would be a real finding. Any other MAGIC just means
somebody else had the board since. Ninety seconds puts it back:

```bash
scripts/with_board.sh ./scripts/35_rocket_rgb_leds.sh
```

and to hand the board back to the MBP labs instead:
`scripts/with_board.sh ./scripts/29_rocket_pext_run.sh`.

---

## 11. Sources

In decreasing order of directness:

| claim | source | kind |
|---|---|---|
| L15/G17/N15 = LD4 {B,G,R}, G14/L14/M15 = LD5 {B,G,R} | Digilent `digilent-xdc/Arty-Z7-20-Master.xdc`, schematic net names `Sch=LED4_B` … `Sch=LED5_R` | **vendor source (schematic-derived)** |
| the same, independently | Xilinx `Xilinx/PYNQ` `pynq/lib/rgbled.py` (`RGB_BLUE=1 RGB_GREEN=2 RGB_RED=4`, 3 bits/LED) + `boards/Pynq-Z1/base/vivado/constraints/base.xdc` + `base/notebooks/board/board_btns_leds.ipynb` (`rgbled_position = [4,5]`) | **vendor source (driver + overlay)** |
| that `base.xdc` is right about this board | `MICROPHONE.md` §1.3 / §2 took F17/G18 from it and then recorded live audio through them | **measured, this board** |
| active high, transistor-inverted cathode drive | Digilent *PYNQ-Z1 Reference Manual* §12.1 (via an Internet Archive snapshot; digilent.com serves a Cloudflare challenge) | **datasheet** |
| ≤50% duty cycle recommended, steady `1` is "uncomfortably bright" | same, §12.1 | **datasheet** |
| the four plain LEDs are anode-connected via 330 Ω (and the tri-colour ones are not) | same, §12 | **datasheet** |
| buttons active high, no debounce | same, §12 | **datasheet** |
| the Arty Z7-20 and the PYNQ-Z1 differ only in the microphone | Digilent *Arty Z7 Reference Manual*, feature comparison — quoted in `MICROPHONE.md` §1.1 | **datasheet** |
| the six ports are on those balls in this bitstream | `get_package_pins -of_objects` on the routed design, plus `reports/post_route_io.rpt` | **measured, this build** |
| GPIO at 0x1001_0000, PLIC sources 2–7, UART still 1, `riscv,ndev = 7` | the generated DTS next to the Verilog | **measured, this build** |
| **that red is red** | **CONFIRMED** — walk observed 2026-09-16: LD4 R→G→B, LD5 R→G→B, both white | **settled** |
