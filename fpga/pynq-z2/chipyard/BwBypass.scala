// SPDX-License-Identifier: Apache-2.0
//
// BwBypass -- the bandwidth instrument on the MEMORY bus, in front of the AXI ports and
// behind nothing.  MEMORY_BANDWIDTH.md section 8.
//
// WHY IT EXISTS.  Every DRAM figure in sections 2-6 was measured by BwProbe on the SYSTEM
// bus, so every byte came back through the InclusiveCache's single outer D channel
// (section 6.1: nine messages per 64-byte block, a 7.11 B/cycle structural ceiling).
// Levers 2 and 3 read null behind it, and those nulls describe that configuration and no
// other (TODO.md item 13).  With the requester on the mbus the L2 is gone from the path, and
// what binds is whatever sits between the mbus and DDR: TLToAXI4, the AXI4-to-AXI3 shim, the
// HP ports, the AFI and the DDR controller.  That is the path the ceiling agent measures
// with a raw AXI master (section 7), so the two numbers can be compared.
//
// WHY LANES.  One TileLink client has one D channel, and a 64-bit D channel carries at most
// 8 B per cycle of the clock it is on, whatever sits behind it.  A second HP port can only
// add bandwidth if a second D channel exists to carry it.  So the instrument is N LANES:
// each an independent TLClientNode with its own mbxd_dma engine, its own source IDs and its
// own descriptor, started by one shared GO so they run over one cycle window.
// WithNMemoryChannels(n) gives channel c the 64-byte blocks whose address bits
// [log2(n)+5 : 6] equal c (Ports.scala: AddressSet(c * blockBytes, ~((n-1) * blockBytes))),
// so a lane whose descriptor visits only such blocks talks to one channel, one AXI port and
// one DDR controller port -- chosen at RUN time by software, not by a rebuild.  HP0+HP1
// (one controller port) against HP0+HP2 (two) is then the same bitstream read two ways.
//
// SAME ENGINE.  mbxd_dma.v unmodified, instantiated at DEPTH = depth (<= 16: its source ID is
// 4 bits; rtl_study/rocc/tb_mbxd.sv passes at 16 against an out-of-order responder) and
// LGBEATS = log2(getBytes / 8).  The engine's scratchpad port is unused, as in BwProbe.
//
// ITS CLOCK IS THE MEMORY BUS'S.  The module is instantiated inside mbus's scope, so its
// cycles are mbus cycles: FCLK1 when WithMemoryBusOnItsOwnClock is in the config, FCLK0
// otherwise.  MB/s is B/cycle x the READ-BACK memory clock.  The MMIO register node sits in
// the same domain and is reached from pbus through a TLAsyncCrossing, which is correct in
// both cases and costs nothing that is measured.
//
// COHERENCE.  A lane reads DDR directly.  A block the cores wrote through the L2 is not in
// DDR until the L2 writes it back, so the guest flushes its region through the L2's control
// node before the first bypass read (samples/bwprobe_bench).  The checksum would expose a
// stale block.  The same limit applies to an accelerator on this path: coherent for data
// the PS wrote before reset (model weights), incoherent for anything written through the L2
// and not flushed.

package chipyard.bwprobe

import chisel3._
import chisel3.util._
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.tilelink._
import freechips.rocketchip.regmapper.{RegField, RegFieldDesc}
import freechips.rocketchip.subsystem._
import freechips.rocketchip.util.AsyncQueueParams
import testchipip.soc.{SubsystemInjector, SubsystemInjectorKey}

case class BwBypassParams(
  address:  BigInt = 0x100b0000L,
  lanes:    Int    = 4,
  depth:    Int    = 16,    // source IDs per lane == transactions in flight per lane
  getBytes: Int    = 64     // bytes per Get: 64 -> 8-beat AXI bursts, 128 -> 16-beat
)

case object BwBypassKey extends Field[Option[BwBypassParams]](None)

/** A lane's signals as the shared counters see them.  Plain Scala, not a Bundle. */
case class BwBypassLane(busy: Bool, aFire: Bool, we: Bool, data: UInt, inflight: UInt, bad: Bool)

class BwBypass(params: BwBypassParams, regBeatBytes: Int)(implicit p: Parameters)
    extends LazyModule {
  require(params.lanes >= 1 && params.lanes <= 8, s"BwBypass: 1..8 lanes, not ${params.lanes}")
  require(params.depth >= 1 && params.depth <= 16, s"BwBypass: mbxd_dma source IDs are 4 bits; depth ${params.depth}")
  require(Seq(64, 128).contains(params.getBytes), s"BwBypass: 64- or 128-byte Gets, not ${params.getBytes}")

  val device = new SimpleDevice("bwbypass", Seq("ucbbar,bwbypass"))

  val mmio = TLRegisterNode(
    address   = Seq(AddressSet(params.address, 0xfff)),
    device    = device,
    beatBytes = regBeatBytes)

  val clients = Seq.tabulate(params.lanes) { i =>
    TLClientNode(Seq(TLMasterPortParameters.v1(Seq(TLClientParameters(
      name = s"bwbypass_lane$i", sourceId = IdRange(0, params.depth))))))
  }

  lazy val module = new BwBypassImpl(this, params)
}

class BwBypassImpl(outer: BwBypass, params: BwBypassParams) extends LazyModuleImp(outer) {
  val lgBeats = log2Ceil(params.getBytes / 8)
  val lgSize  = log2Ceil(params.getBytes)
  val n       = params.lanes

  // ---- shared control --------------------------------------------------------------
  val maxOut  = RegInit(params.depth.U(8.W))
  val laneEn  = RegInit(1.U(n.W))
  val go      = WireDefault(false.B)
  val goPulse = RegNext(go, false.B)

  // ---- one lane per client ---------------------------------------------------------
  val laneRegs = Seq.tabulate(n) { i =>
    val (tl, edge) = outer.clients(i).out(0)
    require(edge.bundle.dataBits == 64, s"BwBypass lane $i: the memory bus is ${edge.bundle.dataBits}-bit, expected 64")
    // Every memory manager this lane can reach must accept a Get of getBytes in one
    // transaction, or TLToAXI4 would be asked for a burst the port was never promised.
    val mem = edge.manager.managers.filter(_.address.exists(_.contains(BigInt(0x80000000L))))
    require(mem.nonEmpty, s"BwBypass lane $i: no manager at 0x8000_0000 on this bus")
    mem.foreach { m =>
      require(m.supportsGet.contains(params.getBytes),
        s"BwBypass lane $i: ${m.name} supports Get ${m.supportsGet}, not ${params.getBytes} bytes")
    }

    val src       = RegInit(0.U(40.W))
    val rowBlocks = RegInit(1.U(16.W))
    val nrows     = RegInit(1.U(16.W))
    val rowStride = RegInit(0.U(32.W))

    val start = goPulse && laneEn(i)
    val dma = Module(new mbxd_dma(params.depth, lgBeats))
    dma.io.clk        := clock
    dma.io.rst        := reset.asBool
    dma.io.start      := start
    dma.io.src_base   := src
    dma.io.row_blocks := rowBlocks
    dma.io.nrows      := nrows
    dma.io.row_stride := rowStride
    dma.io.dst_word   := 0.U

    val inflight = RegInit(0.U(8.W))
    val aFire    = tl.a.fire
    val dLast    = tl.d.fire && edge.last(tl.d)
    when (aFire && !dLast) {
      inflight := inflight + 1.U
    } .elsewhen (!aFire && dLast) {
      inflight := inflight - 1.U
    }
    val allow = inflight < maxOut

    tl.a.valid := dma.io.req_valid && allow
    tl.a.bits  := edge.Get(
      fromSource = dma.io.req_source,
      toAddress  = dma.io.req_addr(edge.bundle.addressBits - 1, 0),
      lgSize     = lgSize.U)._2
    dma.io.req_ready := tl.a.ready && allow

    tl.d.ready        := true.B
    dma.io.rsp_valid  := tl.d.valid && tl.d.bits.opcode === TLMessages.AccessAckData
    dma.io.rsp_source := tl.d.bits.source
    dma.io.rsp_data   := tl.d.bits.data

    val busy   = dma.io.busy || start
    val cycles = RegInit(0.U(64.W))
    val beats  = RegInit(0.U(64.W))
    val reqs   = RegInit(0.U(64.W))
    val peak   = RegInit(0.U(8.W))
    when (goPulse) {
      cycles := 0.U; beats := 0.U; reqs := 0.U; peak := 0.U
    } .elsewhen (busy) {
      cycles := cycles + 1.U
    }
    when (busy && inflight > peak) { peak := inflight }
    when (aFire) { reqs := reqs + 1.U }
    when (dma.io.sp_we) { beats := beats + 1.U }

    val o = BwBypassLane(busy, aFire, dma.io.sp_we, dma.io.sp_data, inflight,
                         tl.d.fire && (tl.d.bits.denied || tl.d.bits.corrupt))

    val base = 0x100 + i * 0x40
    val regs = Seq(
      (base + 0x00) -> Seq(RegField(40, src, RegFieldDesc(s"lane${i}_src", "first block, getBytes-aligned"))),
      (base + 0x08) -> Seq(RegField(16, rowBlocks, RegFieldDesc(s"lane${i}_row_blocks", "Gets per row"))),
      (base + 0x10) -> Seq(RegField(16, nrows, RegFieldDesc(s"lane${i}_nrows", "rows"))),
      (base + 0x18) -> Seq(RegField(32, rowStride, RegFieldDesc(s"lane${i}_row_stride", "bytes between row bases"))),
      (base + 0x20) -> Seq(RegField.r(64, cycles, RegFieldDesc(s"lane${i}_cycles", "this lane's busy window", volatile = true))),
      (base + 0x28) -> Seq(RegField.r(64, beats, RegFieldDesc(s"lane${i}_beats", "64-bit words delivered", volatile = true))),
      (base + 0x30) -> Seq(RegField.r(64, reqs, RegFieldDesc(s"lane${i}_reqs", "Gets issued", volatile = true))),
      (base + 0x38) -> Seq(RegField.r(8, peak, RegFieldDesc(s"lane${i}_peak", "peak in flight", volatile = true)))
    )
    (o, regs)
  }
  val lanes = laneRegs.map(_._1)

  // ---- the shared window -------------------------------------------------------------
  // CYCLES is the union of the lanes' busy windows, so total bytes / CYCLES is the
  // bandwidth of the lanes TOGETHER.  Each lane also keeps its own window.
  val busy    = lanes.map(_.busy).reduce(_ || _)
  val cycles  = RegInit(0.U(64.W))
  val beats   = RegInit(0.U(64.W))
  val reqs    = RegInit(0.U(64.W))
  val cksum   = RegInit(0.U(64.W))
  val denied  = RegInit(0.U(32.W))
  val peak    = RegInit(0.U(8.W))
  val inflightAll = lanes.map(_.inflight).reduce(_ +& _)

  when (goPulse) {
    cycles := 0.U; beats := 0.U; reqs := 0.U; cksum := 0.U; denied := 0.U; peak := 0.U
  } .otherwise {
    when (busy) { cycles := cycles + 1.U }
    beats  := beats + PopCount(lanes.map(_.we))
    reqs   := reqs + PopCount(lanes.map(_.aFire))
    cksum  := cksum ^ lanes.map(l => Mux(l.we, l.data, 0.U)).reduce(_ ^ _)
    denied := denied + PopCount(lanes.map(_.bad))
    when (busy && inflightAll > peak) { peak := inflightAll }
  }

  val laneBusy = VecInit(lanes.map(_.busy)).asUInt
  val status   = Cat(laneBusy, busy)
  // GEOMETRY: a nonzero identity a guest can check before trusting anything else here.
  val geometry = Cat(0xB1.U(8.W), params.getBytes.U(16.W), n.U(8.W), params.depth.U(8.W))

  val shared = Seq(
    0x000 -> Seq(RegField.w(1, go, RegFieldDesc("go", "write 1: start every enabled lane", volatile = true))),
    0x008 -> Seq(RegField(n, laneEn, RegFieldDesc("lane_en", "bit i enables lane i"))),
    0x010 -> Seq(RegField(8, maxOut, RegFieldDesc("max_outstanding", "per-lane cap on transactions in flight, 1..depth"))),
    0x018 -> Seq(RegField.r(n + 1, status, RegFieldDesc("status", "{lane busy bits, any busy}", volatile = true))),
    0x020 -> Seq(RegField.r(64, cycles, RegFieldDesc("cycles", "union busy window, mbus cycles", volatile = true))),
    0x028 -> Seq(RegField.r(64, beats, RegFieldDesc("beats", "64-bit words delivered, all lanes", volatile = true))),
    0x030 -> Seq(RegField.r(64, reqs, RegFieldDesc("reqs", "Gets issued, all lanes", volatile = true))),
    0x038 -> Seq(RegField.r(64, cksum, RegFieldDesc("cksum", "XOR of every delivered word, all lanes", volatile = true))),
    0x040 -> Seq(RegField.r(32, denied, RegFieldDesc("denied", "D beats with denied or corrupt set", volatile = true))),
    0x048 -> Seq(RegField.r(8, peak, RegFieldDesc("peak", "peak transactions in flight, all lanes", volatile = true))),
    0x050 -> Seq(RegField.r(40, geometry, RegFieldDesc("geometry", "{0xB1, getBytes, lanes, depth}")))
  )
  outer.mmio.regmap((shared ++ laneRegs.flatMap(_._2)): _*)
}

case object BwBypassInjector extends SubsystemInjector((p, baseSubsystem) => {
  p(BwBypassKey).map { params =>
    implicit val q: Parameters = p
    val mbus = baseSubsystem.locateTLBusWrapper(MBUS)
    val pbus = baseSubsystem.locateTLBusWrapper(PBUS)
    // In the MEMORY bus's scope, so the engines, counters and register node are clocked by
    // the memory bus's clock -- no crossing on the data path.
    val probe = mbus { LazyModule(new BwBypass(params, pbus.beatBytes)(p)) }
    probe.clients.zipWithIndex.foreach { case (c, i) =>
      mbus.coupleFrom(s"bwbypass_lane$i") { _ := TLBuffer() := c }
    }
    // Control only: pbus (the uncore clock) -> the memory bus's clock.
    val xsrc  = pbus { LazyModule(new TLAsyncCrossingSource()) }
    val xsink = mbus { LazyModule(new TLAsyncCrossingSink(AsyncQueueParams.singleton())) }
    pbus.coupleTo("bwbypass") {
      xsrc.node := TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
    }
    probe.mmio := xsink.node := xsrc.node
  }
})

class WithBwBypass(address: BigInt = 0x100b0000L, lanes: Int = 4, depth: Int = 16,
                   getBytes: Int = 64)
    extends Config((site, here, up) => {
  case BwBypassKey => Some(BwBypassParams(address, lanes, depth, getBytes))
  case SubsystemInjectorKey => up(SubsystemInjectorKey) + BwBypassInjector
})
