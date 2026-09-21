// SPDX-License-Identifier: Apache-2.0
//
// BwProbe -- a TileLink bandwidth instrument, not an accelerator.
//
// WHAT IT IS FOR.  ROCC_DECOUPLED.md section 4.4 simulates rtl_study/rocc/mbxd_dma.v
// against a memory model and gets 1.34 -> 5.10 B/cycle at four transactions in flight
// and 7.89 at eight, against the 1.34 a hart measures.  The model's credibility rests
// on reproducing the board's OWN single-outstanding numbers -- 1.28 against a measured
// 1.34 for DRAM and 2.56 against 2.82 for the L2 -- from nothing but a latency measured
// by a different experiment.  This is the thing that turns those into measurements.
//
// IT IS THE SAME RTL.  mbxd_dma.v is instantiated as a BlackBox, byte-identical to the
// file that was synthesised out of context and simulated in tb_mbxd_bw.sv, so a gap
// between silicon and simulation is a fact about the memory system and not about two
// different designs.
//
// IT IS DELIBERATELY NOT A RoCC.  Three reasons:
//   * `usingRoCC` is `!p(BuildRoCC).isEmpty` and BuildRoCC is a GLOBAL Field, so a RoCC
//     on hart 1 also switches it on for hart 0, where patches/0008's
//     `require(!(usePExt && usingRoCC))` then fires.  Chipyard's WithMultiRoCC fixes
//     that, but an instrument should not need a workaround to exist.
//   * A SubsystemInjector needs NO change to DigitalTop, no IOBinder, no punched-out
//     pin and no XDC edit -- so the only difference between this bitstream and the
//     full-feature one is the thing being measured.
//   * A bandwidth instrument with MMIO control is a simpler object to reason about than
//     an accelerator with a DMA inside it: the guest writes a descriptor, writes GO,
//     polls BUSY, and reads back cycles, beats, requests, peak concurrency and a
//     checksum of every byte that arrived.
//
// WHY THE SYSTEM BUS.  A RoCC accelerator's `tlNode` reaches memory through the sbus,
// which is also where the tiles attach and where TraceSinkDMA attaches, so an sbus
// client sees the same L2 and the same AXI shim the real workloads see.  Attaching to
// the mbus instead would bypass the L2 and measure a different machine.
//
// THE CHECKSUM IS NOT DECORATION.  An engine that returns garbage quickly is not a
// bandwidth measurement.  CKSUM is the XOR of every 64-bit word the D channel delivered;
// the guest computes the same XOR with ordinary loads and compares.  A mismatch means
// the beats are not the bytes that were asked for, whatever the beat rate says.
//
// THE OUTSTANDING CAP IS IN CHISEL, NOT IN THE ENGINE.  mbxd_dma's DEPTH is fixed at
// elaboration; the sweep needs 1..8 at run time.  So the A channel is gated on a
// Chisel-side in-flight counter exactly as tb_mbxd_bw.sv gates it, and mbxd_dma.v stays
// the file that was measured.

package chipyard.bwprobe

import chisel3._
import chisel3.util._
import chisel3.experimental.IntParam
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.tilelink._
import freechips.rocketchip.regmapper.{RegField, RegFieldDesc}
import freechips.rocketchip.subsystem._
import testchipip.soc.{SubsystemInjector, SubsystemInjectorKey}

case class BwProbeParams(
  address: BigInt = 0x100a0000L,
  depth:   Int    = 8            // TileLink source IDs == transactions in flight
)

case object BwProbeKey extends Field[Option[BwProbeParams]](None)

/** fpga/pynq-z2/rtl_study/rocc/mbxd_dma.v, unmodified.
  *
  * A plain BlackBox and deliberately NOT HasBlackBoxResource, for the same reason
  * pdmmic's pdm_mic_core is: the Verilog stays in exactly ONE place -- the rtl_study
  * directory that the out-of-context sweep and both Verilator testbenches read -- and
  * tcl/build_rocket.tcl adds that same file to the Vivado project.  A copy inside the
  * Chipyard tree's resources would be a second thing to keep in step, and the whole
  * claim of this experiment is that the routed engine is the file that was measured. */
class mbxd_dma(depth: Int, lgBeats: Int = 3) extends BlackBox(Map("DEPTH" -> IntParam(depth),
                                                "LGBEATS" -> IntParam(lgBeats))) {
  val io = IO(new Bundle {
    val clk        = Input(Clock())
    val rst        = Input(Bool())
    val start      = Input(Bool())
    val src_base   = Input(UInt(40.W))
    val row_blocks = Input(UInt(16.W))
    val nrows      = Input(UInt(16.W))
    val row_stride = Input(UInt(32.W))
    val dst_word   = Input(UInt(16.W))
    val req_valid  = Output(Bool())
    val req_ready  = Input(Bool())
    val req_addr   = Output(UInt(40.W))
    val req_source = Output(UInt(4.W))
    val rsp_valid  = Input(Bool())
    val rsp_ready  = Output(Bool())
    val rsp_source = Input(UInt(4.W))
    val rsp_data   = Input(UInt(64.W))
    val sp_we      = Output(Bool())
    val sp_word    = Output(UInt(16.W))
    val sp_data    = Output(UInt(64.W))
    val busy       = Output(Bool())
    val inflight   = Output(UInt(8.W))
  })
}

class BwProbe(params: BwProbeParams, beatBytes: Int)(implicit p: Parameters)
    extends LazyModule {

  val device = new SimpleDevice("bwprobe", Seq("ucbbar,bwprobe"))

  val mmio = TLRegisterNode(
    address   = Seq(AddressSet(params.address, 0xfff)),
    device    = device,
    beatBytes = beatBytes)

  val client = TLClientNode(Seq(TLMasterPortParameters.v1(Seq(TLClientParameters(
    name = "bwprobe", sourceId = IdRange(0, params.depth))))))

  lazy val module = new BwProbeImpl(this, params)
}

class BwProbeImpl(outer: BwProbe, params: BwProbeParams)
    extends LazyModuleImp(outer) {

  val (tl, edge) = outer.client.out(0)

  // ---- width.  THE ENGINE FILE DOES NOT CHANGE; ITS UNITS DO. ----------------------
  //
  // mbxd_dma walks 64-byte blocks of 2^LGBEATS beats and does its address arithmetic in
  // 8-byte beats: BLKB = BEATS * 8, requests aligned to LGBEATS+3 bits.  On an 8-byte
  // system bus that is the machine lever 1 measured, and the branch below emits exactly
  // what it always did.
  //
  // On a WIDER system bus (MEMORY_BANDWIDTH.md section 5, WithWideSystemBus) a 64-byte Get
  // is 64/beatBytes beats, so the engine is instantiated at LGBEATS = log2(64/beatBytes)
  // -- a parameter it has always had -- and its ADDRESSES are in units of beatBytes/8
  // bytes: the descriptor is shifted down on the way in and the request address shifted
  // back up on the way out.  Then the engine's "4 beats x 8 units" is 4 beats x 16 bytes
  // on a 128-bit bus, requests are still 64-byte aligned, and every source-ID and beat
  // counter inside it does exactly what tb_mbxd.sv checked.  rtl_study/rocc/tb_mbxd_wide.sv
  // checks this wrapper's arithmetic against an out-of-order wide responder.
  //
  // The engine never stores payload (sp_data is rsp_data, combinationally), so on a wide
  // bus the data does not go through it at all: the checksum folds the WHOLE beat here.
  //
  // WHAT PROVES THE WIDTH IS USED.  BEATS keeps its meaning -- 64-bit WORDS delivered, so
  // bytes = 8 * BEATS on every bitstream and no lab arithmetic changes -- and a wide build
  // adds DBEATS (0x68, TileLink D beats) and BEAT_BYTES (0x70).  REQS counts A-channel
  // Gets of 64 bytes each and DBEATS counts D-channel beats, independently; REQS * 64 ==
  // DBEATS * 16 with the checksum matching every byte is 16 bytes carried per beat.
  // Unmapped offsets read 0 (RegMapper undefZero), so a guest can read both on any
  // bitstream and a 64-bit build answers "not a wide build".
  val sbusBeatBytes = edge.bundle.dataBits / 8
  require(Seq(8, 16, 32).contains(sbusBeatBytes),
    s"BwProbe supports 64-, 128- and 256-bit system buses; this one is ${edge.bundle.dataBits}")
  require(p(CacheBlockBytes) == 64,
    s"BwProbe issues 64-byte Gets; CacheBlockBytes is ${p(CacheBlockBytes)}")
  val unit    = sbusBeatBytes / 8                 // bytes per engine address unit
  val lgUnit  = log2Ceil(unit)
  val lgBeats = log2Ceil(64 / sbusBeatBytes)      // beats per 64-byte Get: 8, 4 or 2
  val wide    = unit > 1

  // ---- control registers ----------------------------------------------------------
  val src        = RegInit(0.U(40.W))
  val rowBlocks  = RegInit(1.U(16.W))
  val nrows      = RegInit(1.U(16.W))
  val rowStride  = RegInit(0.U(32.W))
  val maxOut     = RegInit(params.depth.U(8.W))

  val go         = WireDefault(false.B)
  val goPulse    = RegNext(go, false.B)

  // ---- the engine ------------------------------------------------------------------
  val dma = if (wide) Module(new mbxd_dma(params.depth, lgBeats)) else Module(new mbxd_dma(params.depth))
  dma.io.clk        := clock
  dma.io.rst        := reset.asBool
  dma.io.start      := goPulse
  dma.io.src_base   := (if (wide) src >> lgUnit else src)
  dma.io.row_blocks := rowBlocks
  dma.io.nrows      := nrows
  dma.io.row_stride := (if (wide) rowStride >> lgUnit else rowStride)
  dma.io.dst_word   := 0.U

  // ---- outstanding cap, in Chisel, exactly as tb_mbxd_bw.sv does it ----------------
  val inflight = RegInit(0.U(8.W))
  val aFire    = tl.a.fire
  val dLast    = tl.d.fire && edge.last(tl.d)
  when (aFire && !dLast) {
    inflight := inflight + 1.U
  } .elsewhen (!aFire && dLast) {
    inflight := inflight - 1.U
  }

  val allow = inflight < maxOut

  // ---- A channel: one 64-byte Get per block ----------------------------------------
  tl.a.valid := dma.io.req_valid && allow
  val reqAddr = if (wide) (dma.io.req_addr << lgUnit) else dma.io.req_addr
  tl.a.bits  := edge.Get(
    fromSource = dma.io.req_source,
    toAddress  = reqAddr(edge.bundle.addressBits - 1, 0),
    lgSize     = log2Ceil(64).U)._2
  dma.io.req_ready := tl.a.ready && allow

  // ---- D channel: beats of one block arrive in order, blocks in any order ----------
  tl.d.ready       := true.B
  dma.io.rsp_valid  := tl.d.valid && tl.d.bits.opcode === TLMessages.AccessAckData
  dma.io.rsp_source := tl.d.bits.source
  dma.io.rsp_data   := (if (wide) tl.d.bits.data(63, 0) else tl.d.bits.data)

  // ---- counters ---------------------------------------------------------------------
  // The engine raises busy on the clock edge that takes `start`, so OR the pulse in and
  // there is no gap.  `cycles` is therefore the busy window to within one cycle, against
  // windows of tens of thousands.
  val busy     = dma.io.busy || goPulse
  val cycles   = RegInit(0.U(64.W))
  val beats    = RegInit(0.U(64.W))
  val reqs     = RegInit(0.U(64.W))
  val cksum    = RegInit(0.U(64.W))
  val peak     = RegInit(0.U(8.W))
  val denied   = RegInit(0.U(32.W))   // AccessAck with corrupt/denied set

  when (goPulse) {
    cycles := 0.U; beats := 0.U; reqs := 0.U; cksum := 0.U; peak := 0.U; denied := 0.U
  } .elsewhen (busy) {
    cycles := cycles + 1.U
  }
  when (busy) {
    when (inflight > peak) { peak := inflight }
  }
  when (aFire) { reqs := reqs + 1.U }
  if (wide) {
    when (dma.io.sp_we) {
      beats := beats + unit.U
      cksum := cksum ^ tl.d.bits.data.asTypeOf(Vec(unit, UInt(64.W))).reduce(_ ^ _)
    }
  } else {
    when (dma.io.sp_we) {
      beats := beats + 1.U
      cksum := cksum ^ dma.io.sp_data
    }
  }
  // D beats as TileLink counts them.  Only a wide build has the register.
  val dbeats = if (wide) Some(RegInit(0.U(64.W))) else None
  dbeats.foreach { d =>
    when (goPulse) { d := 0.U } .elsewhen (dma.io.sp_we) { d := d + 1.U }
  }
  when (tl.d.fire && (tl.d.bits.denied || tl.d.bits.corrupt)) {
    denied := denied + 1.U
  }

  val status = Cat(0.U(47.W), peak, inflight, busy)

  val baseMap = Seq(
    0x00 -> Seq(RegField(40, src,
      RegFieldDesc("src", "source base address, 64-byte aligned"))),
    0x08 -> Seq(RegField(16, rowBlocks,
      RegFieldDesc("row_blocks", "64-byte blocks per row"))),
    0x10 -> Seq(RegField(16, nrows,
      RegFieldDesc("nrows", "rows"))),
    0x18 -> Seq(RegField(32, rowStride,
      RegFieldDesc("row_stride", "bytes between row bases"))),
    0x20 -> Seq(RegField(8, maxOut,
      RegFieldDesc("max_outstanding", "cap on transactions in flight, 1..DEPTH"))),
    0x28 -> Seq(RegField.w(1, go,
      RegFieldDesc("go", "write 1 to start", volatile = true))),
    0x30 -> Seq(RegField.r(64, status,
      RegFieldDesc("status", "{peak_inflight, inflight, busy}", volatile = true))),
    0x38 -> Seq(RegField.r(64, cycles,
      RegFieldDesc("cycles", "cycles from go to idle", volatile = true))),
    0x40 -> Seq(RegField.r(64, beats,
      RegFieldDesc("beats", "64-bit beats delivered", volatile = true))),
    0x48 -> Seq(RegField.r(64, reqs,
      RegFieldDesc("reqs", "A-channel Gets issued", volatile = true))),
    0x50 -> Seq(RegField.r(64, cksum,
      RegFieldDesc("cksum", "XOR of every delivered word", volatile = true))),
    0x58 -> Seq(RegField.r(32, denied,
      RegFieldDesc("denied", "D beats with denied or corrupt set", volatile = true))),
    0x60 -> Seq(RegField.r(8, params.depth.U(8.W),
      RegFieldDesc("depth", "source IDs built into this bitstream")))
  )
  val wideMap = dbeats.toSeq.flatMap { d => Seq(
    0x68 -> Seq(RegField.r(64, d,
      RegFieldDesc("dbeats", "TileLink D beats delivered", volatile = true))),
    0x70 -> Seq(RegField.r(8, sbusBeatBytes.U(8.W),
      RegFieldDesc("beat_bytes", "system bus beat width in bytes; 0 (unmapped) on a 64-bit build")))
  ) }
  outer.mmio.regmap((baseMap ++ wideMap): _*)
}

case object BwProbeInjector extends SubsystemInjector((p, baseSubsystem) => {
  p(BwProbeKey).map { params =>
    implicit val q: Parameters = p
    val sbus = baseSubsystem.locateTLBusWrapper(SBUS)
    val pbus = baseSubsystem.locateTLBusWrapper(PBUS)
    // Instantiated in the sbus context: this SoC has exactly one uncore clock
    // (ChipTop's `clock_uncore`), so sbus and pbus are the same domain and neither
    // edge needs a crossing.  A TLBuffer on the A path decouples the engine's
    // combinational req_valid from the crossbar's ready and gives place-and-route
    // somewhere to put a register on a device that is already 66 % full.
    val probe = sbus { LazyModule(new BwProbe(params, pbus.beatBytes)(p)) }
    sbus.coupleFrom("bwprobe") { _ := TLBuffer() := probe.client }
    pbus.coupleTo("bwprobe") {
      probe.mmio := TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
    }
  }
})

class WithBwProbe(address: BigInt = 0x100a0000L, depth: Int = 8)
    extends Config((site, here, up) => {
  case BwProbeKey => Some(BwProbeParams(address, depth))
  case SubsystemInjectorKey => up(SubsystemInjectorKey) + BwProbeInjector
})
