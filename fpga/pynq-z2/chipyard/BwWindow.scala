// SPDX-License-Identifier: Apache-2.0
//
// BwWindow and DmaAperture -- the SYSTEM-BUS side of the memory architecture.
// MEMORY_BANDWIDTH.md section 9.
//
// THE QUESTION.  Section 6 took the L2 path to one 64-bit beat per core cycle (275.8 MB/s,
// 0x5A5A001A) and section 8 took an MBUS requester to 800 MB/s per HP port and 2,008 MB/s on
// four (0x5A5A0017), where a time-rate cap on the PS side binds.  An MBUS lane is clocked by
// the memory bus.  A requester that lives with the cores -- an accelerator whose logic runs at
// the P-extension's 34.4828 MHz -- is bounded instead by three multipliers: bytes per beat,
// parallel D channels, and ITS clock.  This file builds the two pieces that let such a
// requester reach the interface without the L2:
//
//   BwWindow     N LANES at the CORE clock.  Each lane is an mbxd_dma engine (unmodified, as in
//                BwProbe and BwBypass) with its own TileLink client of `laneBits`-wide beats,
//                its own TLBuffer, its own TLAsyncCrossingSource/Sink pair into the memory
//                bus's clock, and a TLWidthWidget on the FAR (memory-clock) side of that
//                crossing.  The widget has to be there: a 128-bit beat that is split back to
//                64 bits before the crossing crosses at 8 B per core cycle, which is the
//                ceiling the lane exists to lift.  Lane c then reads only blocks whose
//                WithNMemoryChannels channel is c, so it owns one D channel, one crossing and
//                one HP port.  Arithmetic bound per lane: laneBits/8 B x 34.4828 MHz
//                (551.7 MB/s at 128 bits), provided the port supplies 2 beats per 128-bit beat
//                faster than the core clock consumes them (8 B x FCLK1 >= 16 B x FCLK0, i.e.
//                FCLK1 >= 69 MHz).
//
//   DmaAperture  an UNCACHED ALIAS of DDR on the system bus.  DDR at `target` (the ExtMem
//                window the L2 caches) also appears at `base`, reached through a
//                TLSourceShrinker, a TLMap and one TLAsyncCrossing straight into the memory
//                bus -- not through the InclusiveCache.  Any sbus client can use it: both
//                harts (their PMA says the region does not support Acquire, so the DCache
//                takes its uncached path: one TileLink request per load or store, serialised
//                by `io.dmem.ordered`), TraceSinkDMA, BwProbe.  It is the 32-bit analogue of
//                rocket-chip's ExtMem.incohBase, which needs incohBase >= 2^32 here and would
//                widen both harts' physical address.
//
// COHERENCE.  Neither piece is coherent with the L2 by itself; the contract is software's and is
// stated in MEMORY_BANDWIDTH.md section 9.4.  In short: a byte written through the coherent
// alias (0x8000_0000) may sit dirty in a hart's L1 or in the L2 until those caches write it
// back, so a DMA read of it (lane or aperture) must be preceded by an L2 flush of its 64-byte
// block (L2 control +0x200 probes the L1s too), and a DMA write must not be followed by a
// coherent-alias read of a block the caches still hold.  WithDmaPartition below turns the
// discipline into address decode: the L2 cannot name the pool at all, and the aperture names
// only the pool.
//
// THE CLOCKS.  BwWindow's engines, counters and register node are in the SYSTEM bus's scope
// (FCLK0, the tiles' clock); only the memory-bus half of each crossing is on the memory clock.
// MB/s for a WIN_ row is B/cycle x the READ-BACK FCLK0.

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

case class BwWindowParams(
  address:   BigInt = 0x100c0000L,
  lanes:     Int    = 4,
  depth:     Int    = 8,     // source IDs per lane == transactions in flight per lane
  laneBits:  Int    = 128,   // beat width of each lane's client, at the core clock
  xingDepth: Int    = 8      // AsyncQueue entries per channel of each lane's crossing
)

case object BwWindowKey extends Field[Option[BwWindowParams]](None)

case class DmaApertureParams(
  base:     BigInt = 0x40000000L,   // where DDR appears, uncached, on the system bus
  target:   BigInt = 0x80000000L,   // the ExtMem window it aliases
  size:     BigInt = 0x10000000L,
  inFlight: Int    = 4              // TLSourceShrinker: transactions in flight through it
)

case object DmaApertureKey extends Field[Option[DmaApertureParams]](None)

/** A lane's signals as the shared counters see them.  Plain Scala, not a Bundle. */
case class BwWindowLane(busy: Bool, aFire: Bool, we: Bool, fold: UInt, words: Int,
                        inflight: UInt, bad: Bool)

class BwWindow(params: BwWindowParams, regBeatBytes: Int)(implicit p: Parameters)
    extends LazyModule {
  require(params.lanes >= 1 && params.lanes <= 8, s"BwWindow: 1..8 lanes, not ${params.lanes}")
  require(params.depth >= 1 && params.depth <= 16, s"BwWindow: mbxd_dma source IDs are 4 bits; depth ${params.depth}")
  require(Seq(64, 128, 256).contains(params.laneBits), s"BwWindow: 64-, 128- or 256-bit lanes, not ${params.laneBits}")

  val device = new SimpleDevice("bwwindow", Seq("ucbbar,bwwindow"))

  val mmio = TLRegisterNode(
    address   = Seq(AddressSet(params.address, 0xfff)),
    device    = device,
    beatBytes = regBeatBytes)

  val clients = Seq.tabulate(params.lanes) { i =>
    TLClientNode(Seq(TLMasterPortParameters.v1(Seq(TLClientParameters(
      name = s"bwwin_lane$i", sourceId = IdRange(0, params.depth))))))
  }

  lazy val module = new BwWindowImpl(this, params)
}

class BwWindowImpl(outer: BwWindow, params: BwWindowParams) extends LazyModuleImp(outer) {
  val n = params.lanes
  require(p(CacheBlockBytes) == 64, s"BwWindow issues 64-byte Gets; CacheBlockBytes is ${p(CacheBlockBytes)}")

  // ---- shared control --------------------------------------------------------------
  val maxOut  = RegInit(params.depth.U(8.W))
  val laneEn  = RegInit(1.U(n.W))
  val go      = WireDefault(false.B)
  val goPulse = RegNext(go, false.B)

  // ---- one lane per client ---------------------------------------------------------
  val laneRegs = Seq.tabulate(n) { i =>
    val (tl, edge) = outer.clients(i).out(0)
    val beatBytes  = edge.bundle.dataBits / 8
    require(beatBytes * 8 == params.laneBits,
      s"BwWindow lane $i: the client edge is ${edge.bundle.dataBits}-bit, expected ${params.laneBits}")
    // As BwProbe on a wide system bus: the engine walks 64-byte blocks of 2^LGBEATS beats and
    // does its address arithmetic in 8-byte units, so on a wide lane it runs at
    // LGBEATS = log2(64 / beatBytes) with its addresses in units of beatBytes/8 bytes.
    val unit    = beatBytes / 8
    val lgUnit  = log2Ceil(unit)
    val lgBeats = log2Ceil(64 / beatBytes)
    val mem = edge.manager.managers.filter(_.address.exists(_.contains(BigInt(0x80000000L))))
    require(mem.nonEmpty, s"BwWindow lane $i: no manager at 0x8000_0000 behind this lane")
    mem.foreach { m =>
      require(m.supportsGet.contains(64),
        s"BwWindow lane $i: ${m.name} supports Get ${m.supportsGet}, not 64 bytes")
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
    dma.io.src_base   := src >> lgUnit
    dma.io.row_blocks := rowBlocks
    dma.io.nrows      := nrows
    dma.io.row_stride := rowStride >> lgUnit
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

    val reqAddr = dma.io.req_addr << lgUnit
    tl.a.valid := dma.io.req_valid && allow
    tl.a.bits  := edge.Get(
      fromSource = dma.io.req_source,
      toAddress  = reqAddr(edge.bundle.addressBits - 1, 0),
      lgSize     = log2Ceil(64).U)._2
    dma.io.req_ready := tl.a.ready && allow

    tl.d.ready        := true.B
    dma.io.rsp_valid  := tl.d.valid && tl.d.bits.opcode === TLMessages.AccessAckData
    dma.io.rsp_source := tl.d.bits.source
    dma.io.rsp_data   := tl.d.bits.data(63, 0)
    // The engine never stores payload, so the checksum folds the WHOLE beat here: every 64-bit
    // word of every beat, exactly the XOR a guest computes with ordinary loads.
    val fold = tl.d.bits.data.asTypeOf(Vec(unit, UInt(64.W))).reduce(_ ^ _)

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
    when (dma.io.sp_we) { beats := beats + unit.U }

    val o = BwWindowLane(busy, aFire, dma.io.sp_we, fold, unit, inflight,
                         tl.d.fire && (tl.d.bits.denied || tl.d.bits.corrupt))

    val base = 0x100 + i * 0x40
    val regs = Seq(
      (base + 0x00) -> Seq(RegField(40, src, RegFieldDesc(s"lane${i}_src", "first block, 64-byte aligned"))),
      (base + 0x08) -> Seq(RegField(16, rowBlocks, RegFieldDesc(s"lane${i}_row_blocks", "Gets per row"))),
      (base + 0x10) -> Seq(RegField(16, nrows, RegFieldDesc(s"lane${i}_nrows", "rows"))),
      (base + 0x18) -> Seq(RegField(32, rowStride, RegFieldDesc(s"lane${i}_row_stride", "bytes between row bases"))),
      (base + 0x20) -> Seq(RegField.r(64, cycles, RegFieldDesc(s"lane${i}_cycles", "this lane's busy window, core cycles", volatile = true))),
      (base + 0x28) -> Seq(RegField.r(64, beats, RegFieldDesc(s"lane${i}_beats", "64-bit words delivered", volatile = true))),
      (base + 0x30) -> Seq(RegField.r(64, reqs, RegFieldDesc(s"lane${i}_reqs", "Gets issued", volatile = true))),
      (base + 0x38) -> Seq(RegField.r(8, peak, RegFieldDesc(s"lane${i}_peak", "peak in flight", volatile = true)))
    )
    (o, regs)
  }
  val lanes = laneRegs.map(_._1)

  // ---- the shared window -------------------------------------------------------------
  // CYCLES is the union of the lanes' busy windows, in CORE cycles.  BEATS counts 64-bit WORDS
  // (bytes = 8 x BEATS, as on every other instrument); DBEATS counts TileLink D beats, so
  // 64 x REQS == DBEATS x laneBits/8 with the checksum matching is the width, proven.
  val busy    = lanes.map(_.busy).reduce(_ || _)
  val cycles  = RegInit(0.U(64.W))
  val beats   = RegInit(0.U(64.W))
  val dbeats  = RegInit(0.U(64.W))
  val reqs    = RegInit(0.U(64.W))
  val cksum   = RegInit(0.U(64.W))
  val denied  = RegInit(0.U(32.W))
  val peak    = RegInit(0.U(8.W))
  val inflightAll = lanes.map(_.inflight).reduce(_ +& _)

  when (goPulse) {
    cycles := 0.U; beats := 0.U; dbeats := 0.U; reqs := 0.U; cksum := 0.U; denied := 0.U; peak := 0.U
  } .otherwise {
    when (busy) { cycles := cycles + 1.U }
    beats  := beats + lanes.map(l => Mux(l.we, l.words.U(8.W), 0.U(8.W))).reduce(_ +& _)
    dbeats := dbeats + PopCount(lanes.map(_.we))
    reqs   := reqs + PopCount(lanes.map(_.aFire))
    cksum  := cksum ^ lanes.map(l => Mux(l.we, l.fold, 0.U)).reduce(_ ^ _)
    denied := denied + PopCount(lanes.map(_.bad))
    when (busy && inflightAll > peak) { peak := inflightAll }
  }

  val laneBusy = VecInit(lanes.map(_.busy)).asUInt
  val status   = Cat(laneBusy, busy)
  // GEOMETRY: {laneBytes, 0xB2, getBytes, lanes, depth}.  0xB2 tells a guest this is the
  // core-clock window, not BwBypass (0xB1) at 0x100B_0000.
  val geometry = Cat((params.laneBits / 8).U(8.W), 0xB2.U(8.W), 64.U(16.W), n.U(8.W), params.depth.U(8.W))

  val shared = Seq(
    0x000 -> Seq(RegField.w(1, go, RegFieldDesc("go", "write 1: start every enabled lane", volatile = true))),
    0x008 -> Seq(RegField(n, laneEn, RegFieldDesc("lane_en", "bit i enables lane i"))),
    0x010 -> Seq(RegField(8, maxOut, RegFieldDesc("max_outstanding", "per-lane cap on transactions in flight, 0..depth; 0 stops issuing"))),
    0x018 -> Seq(RegField.r(n + 1, status, RegFieldDesc("status", "{lane busy bits, any busy}", volatile = true))),
    0x020 -> Seq(RegField.r(64, cycles, RegFieldDesc("cycles", "union busy window, core cycles", volatile = true))),
    0x028 -> Seq(RegField.r(64, beats, RegFieldDesc("beats", "64-bit words delivered, all lanes", volatile = true))),
    0x030 -> Seq(RegField.r(64, reqs, RegFieldDesc("reqs", "Gets issued, all lanes", volatile = true))),
    0x038 -> Seq(RegField.r(64, cksum, RegFieldDesc("cksum", "XOR of every delivered word, all lanes", volatile = true))),
    0x040 -> Seq(RegField.r(32, denied, RegFieldDesc("denied", "D beats with denied or corrupt set", volatile = true))),
    0x048 -> Seq(RegField.r(8, peak, RegFieldDesc("peak", "peak transactions in flight, all lanes", volatile = true))),
    0x050 -> Seq(RegField.r(48, geometry, RegFieldDesc("geometry", "{laneBytes, 0xB2, getBytes, lanes, depth}"))),
    0x058 -> Seq(RegField.r(64, dbeats, RegFieldDesc("dbeats", "TileLink D beats delivered, all lanes", volatile = true)))
  )
  outer.mmio.regmap((shared ++ laneRegs.flatMap(_._2)): _*)
}

case object BwWindowInjector extends SubsystemInjector((p, baseSubsystem) => {
  p(BwWindowKey).map { params =>
    implicit val q: Parameters = p
    val sbus = baseSubsystem.locateTLBusWrapper(SBUS)
    val mbus = baseSubsystem.locateTLBusWrapper(MBUS)
    val pbus = baseSubsystem.locateTLBusWrapper(PBUS)
    // In the SYSTEM bus's scope: the engines are clocked with the cores.  The register node is on
    // the pbus, which shares that clock -- no crossing on the control path.
    val win = sbus { LazyModule(new BwWindow(params, pbus.beatBytes)(p)) }
    win.clients.zipWithIndex.foreach { case (c, i) =>
      val xsrc  = sbus { LazyModule(new TLAsyncCrossingSource()) }
      val xsink = mbus { LazyModule(new TLAsyncCrossingSink(AsyncQueueParams(depth = params.xingDepth, sync = 3))) }
      xsrc.suggestName(s"bwwin_lane${i}_xsrc")
      xsink.suggestName(s"bwwin_lane${i}_xsink")
      // Core clock: engine -> TLBuffer -> crossing source.  Memory clock: crossing sink ->
      // width widget (laneBits -> mbus beat, so two 64-bit R beats make one wide D beat HERE, on
      // the fast side) -> TLBuffer (patch 0061's reasoning: cut the crossbar's ready loop) -> mbus.
      mbus.coupleFrom(s"bwwin_lane$i") { _ := TLBuffer() := TLWidthWidget(params.laneBits / 8) := xsink.node }
      // The core-clock TLBuffer has to be CREATED in the system bus's scope, or it has no clock.
      sbus { xsrc.node := TLBuffer() := c }
      xsink.node := xsrc.node
    }
    pbus.coupleTo("bwwindow") {
      win.mmio := TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
    }
  }
})

case object DmaApertureInjector extends SubsystemInjector((p, baseSubsystem) => {
  p(DmaApertureKey).map { a =>
    implicit val q: Parameters = p
    val sbus = baseSubsystem.locateTLBusWrapper(SBUS)
    val mbus = baseSubsystem.locateTLBusWrapper(MBUS)
    require(a.size > 0 && isPow2(a.size), s"DmaAperture: size ${a.size} is not a power of two")
    require(a.base + a.size <= a.target || a.target + a.size <= a.base,
      "DmaAperture: the alias overlaps the window it aliases")
    val window = AddressSet(a.target, a.size - 1)
    val shift  = a.base - a.target
    val xsrc   = sbus { LazyModule(new TLAsyncCrossingSource()) }
    val xsink  = mbus { LazyModule(new TLAsyncCrossingSink(AsyncQueueParams(depth = 8, sync = 3))) }
    xsrc.suggestName("dma_aperture_xsrc")
    xsink.suggestName("dma_aperture_xsink")
    // Managers flow left to right: the memory bus's DDR channels, narrowed to the window, moved to
    // the alias, stripped of their DTS resources (DDR must not appear twice in the device tree),
    // then a source shrinker, so every channel's TLToAXI4 sees `inFlight` sources from here
    // rather than every system-bus client's.
    sbus.coupleTo("dma_aperture") {
      (xsrc.node
        := TLFilter(TLFilter.mSelectIntersect(window))
        := TLMap(as => as.base + shift)
        := TLFilter(TLFilter.mResourceRemover)
        := TLSourceShrinker(a.inFlight)
        := _)
    }
    mbus.coupleFrom("dma_aperture") { _ := TLBuffer() := xsink.node }
    xsink.node := xsrc.node
  }
})

class WithBwWindow(address: BigInt = 0x100c0000L, lanes: Int = 4, depth: Int = 8,
                   laneBits: Int = 128, xingDepth: Int = 8)
    extends Config((site, here, up) => {
  case BwWindowKey => Some(BwWindowParams(address, lanes, depth, laneBits, xingDepth))
  case SubsystemInjectorKey => up(SubsystemInjectorKey) + BwWindowInjector
})

class WithDmaAperture(base: BigInt = 0x40000000L, target: BigInt = 0x80000000L,
                      size: BigInt = 0x10000000L, inFlight: Int = 4)
    extends Config((site, here, up) => {
  case DmaApertureKey => Some(DmaApertureParams(base, target, size, inFlight))
  case SubsystemInjectorKey => up(SubsystemInjectorKey) + DmaApertureInjector
})

/** The partition contract as address decode.  A pool of `size` bytes at `poolBase` is removed from
  * what the L2 can name (a TLFilter between the TLCacheCork and the memory bus, so the L2's inner
  * port -- and therefore every hart's coherent view -- no longer contains it), and the aperture is
  * narrowed to that pool.  A hart can then reach the pool only uncached, the L2 can never hold a
  * copy of it, and no flush is ever needed.  Stack it on the LEFT of WithDmaAperture. */
class WithDmaPartition(poolBase: BigInt, poolSize: BigInt, aliasBase: BigInt)
    extends Config((site, here, up) => {
  case SubsystemBankedCoherenceKey => {
    val u = up(SubsystemBankedCoherenceKey, site)
    u.copy(coherenceManager = { context =>
      implicit val q: Parameters = context.p
      val (in, out, halt) = u.coherenceManager(context)
      val pool = LazyModule(new TLFilter(TLFilter.mSubtract(AddressSet(poolBase, poolSize - 1))))
      pool.suggestName("dma_pool_partition")
      pool.node :*= out
      (in, pool.node, halt)
    })
  }
  case DmaApertureKey => up(DmaApertureKey, site).map(_.copy(base = aliasBase, target = poolBase, size = poolSize))
})
