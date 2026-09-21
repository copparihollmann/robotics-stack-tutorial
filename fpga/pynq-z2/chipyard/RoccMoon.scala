// SPDX-License-Identifier: Apache-2.0
//
// RoccMoon -- the decoupled accelerator (rtl_study/roccmoon/mbxr_engine.v) as a RoCC on hart 1,
// with its memory clients outside the tile so the weight path can move to MBUS.
//
// WHY THE ENGINE IS NOT INSIDE THE LazyRoCC.  A LazyRoCC's `tlNode` is wired by the tile to
// `tlOtherMastersNode` and out through the tile's master port, whose `where` is SBUS
// (HasHierarchicalElements.scala:28-31, HasTiles.scala:181-186).  That path can never reach
// MBUS, and TODO.md item 13 -- bypassing the L2 for weights -- needs exactly that.  So this
// file splits the accelerator in two:
//
//   RoccMoonShim   a LazyRoCC in hart 1's tile.  It owns nothing but the command path: a
//                  custom-1 instruction becomes one cycle on a BundleBridge, and an xd
//                  command's reply is held until the core takes it.
//   RoccMoonEngine a LazyModule on the system bus holding mbxr_engine.v as a BlackBox and
//                  two TileLink clients:
//                    W  weights, Gets only, on `weightBus` -- SBUS here, MBUS for item 13
//                    A  activations (Gets) and results (Puts), always SBUS: those bytes are
//                       dirty in a core's L1, and the L2 is the TileLink-C manager that
//                       keeps the L1s coherent with a third master
//
// The injector binds the two across the tile boundary directly, the way HasTiles binds a
// tile's hartIdNode from the subsystem (HasTiles.scala:265).
//
// PLACEMENT NEEDS TWO THINGS, and the second one is not WithMultiRoCC.
//   * `usingRoCC` is `!p(BuildRoCC).isEmpty` and BuildRoCC is a GLOBAL key, so a plain RoCC
//     fragment is visible to tile 0, where patches/0008's require(!(usePExt && usingRoCC))
//     fires.  Chipyard's WithMultiRoCC evaluates BuildRoCC per tile from MultiRoCCKey.
//   * RoCCDecode claims all four custom opcodes whenever usingRoCC.  Hart 1 must TRAP on the
//     MBP instructions (custom-0) -- that is the heterogeneity mechanism Lab B9 and
//     samples/modelblaster_pext test -- and with a custom-1 accelerator an unclaimed custom-0
//     command reaches a router with no accelerator behind it, which never raises ready: the
//     hart hangs instead of trapping.  patches/0101 lets a configuration narrow RoCCDecode to the
//     opcodes its accelerators use; WithRoccMoon narrows it to custom-1.
//
// REVISION 2b (P4, MEMORY_BANDWIDTH.md 9.9 design (ii')).  With `wLane = true` the engine is split
// along rtl_study/roccmoon/rev2's boundary into two BlackBoxes in two clock domains:
//
//   RoccMoonEngine2b  mbxr_engine_core on the system bus's clock: the command path, client A, the
//                     scratchpad (whose weight banks take their WRITE clock from the weight half),
//                     the arithmetic and the drain.
//   RoccMoonWHalf     mbxr_whalf in the private W lane's clock domain (chipyard.wlane, WLanePort.scala;
//                     DigitalTop mixes in CanHaveWLanePort by patches/0110): W's DMA, the plane mapper,
//                     the weight banks' write port, and client W, which couples straight into the
//                     lane's own TLBuffer -> TLToAXI4 -> S_AXI_HP2 chain.
//
// The two halves are joined by two BundleBridges carrying exactly the RTL's wh_* / ww_* ports.  NO
// Chisel crossing sits on them: the load request, completion and error are toggles and the beat count
// is Gray-coded, synchronised inside the RTL (mbxr_wx, W_ASYNC = 1); the descriptor fields are
// quasi-static (they need a max-delay constraint, not a synchroniser); ww_* are the weight banks'
// write port, on the weight half's clock by construction.  Each half takes its reset from its own
// domain, which Chipyard's PRCI already synchronises to that domain's clock.
//
// Two more things the weight half needs from the plumbing (rev2b, commit 624a8e0):
//   * W_WIN_LO / W_WIN_HI, the lane's weight window [base, base + size): mbxd_dma2 issues no Get
//     outside it and stops the load with a sticky error instead.
//   * w_quiet, from mbxr_wquiet (mbxr_wx.v): the AR/RLAST balance at the lane's AXI4 master pins --
//     after TLToAXI4 and the AXI4UserYanker, where the ChipTop port is -- on the lane clock.  The
//     weight half starts no load while it is low, so after a reset no load reuses a source ID with
//     a burst still on the wire.  mbxr_wquiet has NO RESET PORT and none is given to it: its
//     counters start at their bitstream values and must survive every SoC and lane reset.  It is
//     built in the subsystem's module (where the AXI4 pins are) with an explicit clock, not inside
//     a clock domain, so no implicit reset reaches it either.
//
// With `wLane = false` (the default) the injector builds exactly what it built before: revision
// 1's configurations elaborate to the same Verilog, source locators in assertion messages apart.
//
// THE VERILOG IS NOT COPIED.  mbxr_engine is a plain BlackBox, exactly as BwProbe's mbxd_dma
// is: tcl/build_rocket.tcl adds rtl_study/roccmoon/*.v and rtl_study/rocc/mbxd_{dma,spad}.v
// to the Vivado project -- the files tb_mbxr checked byte for byte against ModelBlaster's
// reference kernel.

package chipyard.roccmoon

import chisel3._
import chisel3.util._
import chisel3.experimental.IntParam
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.tilelink._
import freechips.rocketchip.subsystem._
import freechips.rocketchip.tile._
import freechips.rocketchip.prci.{AsynchronousCrossing, RationalCrossing}
import testchipip.soc.{SubsystemInjector, SubsystemInjectorKey}

case class RoccMoonParams(
  hart:      Int                  = 1,
  weightBus: TLBusWrapperLocation = SBUS,
  nch:       Int                  = 4,     // 8*nch MAC/cycle; ROCC_DECOUPLED.md 7.5
  ldepth:    Int                  = 4,     // fill source IDs
  sdepth:    Int                  = 2,     // drain source IDs
  wLane:     Boolean              = false  // revision 2b: the weight half on the private W lane (P4)
)

case object RoccMoonKey extends Field[Option[RoccMoonParams]](None)

class RoccMoonCmd extends Bundle {
  val valid = Bool()
  val funct = UInt(7.W)
  val rs1   = UInt(64.W)
  val rs2   = UInt(64.W)
  val xd    = Bool()
}

class RoccMoonRsp extends Bundle {
  val respValid = Bool()
  val respData  = UInt(64.W)
  val busy      = Bool()
}

// ---- hart 1's side ----------------------------------------------------------------------
class RoccMoonShim(opcodes: OpcodeSet)(implicit p: Parameters) extends LazyRoCC(opcodes) {
  val cmdNode = BundleBridgeSource(() => new RoccMoonCmd)
  val rspNode = BundleBridgeSink[RoccMoonRsp]()
  override lazy val module = new RoccMoonShimImp(this)
}

class RoccMoonShimImp(outer: RoccMoonShim)(implicit p: Parameters) extends LazyRoCCModuleImp(outer) {
  val c = outer.cmdNode.bundle
  val r = outer.rspNode.bundle

  // One reply at a time.  RocketCore turns a refused command into a flush and refetch
  // (replay_wb_rocc), so refusing is only ever done while a reply is still waiting.
  val respQ = Module(new Queue(new RoCCResponse, 1))
  io.cmd.ready := respQ.io.enq.ready

  c.valid := io.cmd.fire
  c.funct := io.cmd.bits.inst.funct
  c.rs1   := io.cmd.bits.rs1
  c.rs2   := io.cmd.bits.rs2
  c.xd    := io.cmd.bits.inst.xd

  // the engine answers an xd command combinationally, in the cycle it sees it
  respQ.io.enq.valid     := io.cmd.fire && io.cmd.bits.inst.xd
  respQ.io.enq.bits.rd   := io.cmd.bits.inst.rd
  respQ.io.enq.bits.data := r.respData
  io.resp <> respQ.io.deq

  // `busy` only delays fence-class instructions on this hart (RocketCore id_rocc_busy); the
  // engine's own busy is read through the fence command, so it is not exported here.
  io.busy      := respQ.io.deq.valid
  io.interrupt := false.B
  io.mem.req.valid := false.B
  io.mem.s1_kill   := false.B
  io.mem.s2_kill   := false.B
}

// ---- the engine --------------------------------------------------------------------------
class mbxr_engine(params: RoccMoonParams) extends BlackBox(Map(
    "NCH"    -> IntParam(params.nch),
    "LDEPTH" -> IntParam(params.ldepth),
    "SDEPTH" -> IntParam(params.sdepth))) {
  val io = IO(new Bundle {
    val clk        = Input(Clock())
    val rst        = Input(Bool())
    val cmd_valid  = Input(Bool())
    val cmd_funct  = Input(UInt(7.W))
    val cmd_rs1    = Input(UInt(64.W))
    val cmd_rs2    = Input(UInt(64.W))
    val cmd_xd     = Input(Bool())
    val resp_valid = Output(Bool())
    val resp_data  = Output(UInt(64.W))
    val busy       = Output(Bool())
    val wa_valid   = Output(Bool())
    val wa_ready   = Input(Bool())
    val wa_addr    = Output(UInt(40.W))
    val wa_source  = Output(UInt(4.W))
    val wd_valid   = Input(Bool())
    val wd_source  = Input(UInt(4.W))
    val wd_data    = Input(UInt(64.W))
    val wd_error   = Input(Bool())
    val aa_valid   = Output(Bool())
    val aa_ready   = Input(Bool())
    val aa_put     = Output(Bool())
    val aa_size    = Output(UInt(2.W))   // PutFullData size: 0 = 8 B, 1 = 16, 2 = 32, 3 = 64
    val aa_addr    = Output(UInt(40.W))
    val aa_source  = Output(UInt(4.W))
    val aa_data    = Output(UInt(64.W))
    val aa_last    = Output(Bool())
    val ad_valid   = Input(Bool())
    val ad_ack     = Input(Bool())
    val ad_source  = Input(UInt(4.W))
    val ad_data    = Input(UInt(64.W))
    val ad_error   = Input(Bool())
  })
}

class RoccMoonEngine(val params: RoccMoonParams)(implicit p: Parameters) extends LazyModule {
  require(params.ldepth + params.sdepth <= 16, "source IDs are 4 bits")

  val wNode = TLClientNode(Seq(TLMasterPortParameters.v1(Seq(TLMasterParameters.v1(
    name = "roccmoon_w", sourceId = IdRange(0, params.ldepth))))))
  val aNode = TLClientNode(Seq(TLMasterPortParameters.v1(Seq(TLMasterParameters.v1(
    name = "roccmoon_a", sourceId = IdRange(0, params.ldepth + params.sdepth))))))

  val cmdNode = BundleBridgeSink[RoccMoonCmd]()
  val rspNode = BundleBridgeSource(() => new RoccMoonRsp)

  lazy val module = new RoccMoonEngineImp(this)
}

class RoccMoonEngineImp(outer: RoccMoonEngine) extends LazyModuleImp(outer) {
  val params = outer.params
  val (w, we) = outer.wNode.out(0)
  val (a, ae) = outer.aNode.out(0)

  // The engine is written for 64-bit beats: one 64-byte request is eight of them.  The
  // injector puts a TLWidthWidget between the engine and a wider bus, so this holds on a
  // 128-bit system bus too -- at the widget's rate, not the wide bus's.
  require(we.bundle.dataBits == 64 && ae.bundle.dataBits == 64,
    s"mbxr_engine needs 64-bit beats at its clients (W ${we.bundle.dataBits}, A ${ae.bundle.dataBits})")

  val e = Module(new mbxr_engine(params))
  e.io.clk := clock
  e.io.rst := reset.asBool

  val c = outer.cmdNode.bundle
  e.io.cmd_valid := c.valid
  e.io.cmd_funct := c.funct
  e.io.cmd_rs1   := c.rs1
  e.io.cmd_rs2   := c.rs2
  e.io.cmd_xd    := c.xd

  val r = outer.rspNode.bundle
  r.respValid := e.io.resp_valid
  r.respData  := e.io.resp_data
  r.busy      := e.io.busy

  // ---- W: Gets --------------------------------------------------------------------------
  w.a.valid := e.io.wa_valid
  w.a.bits  := we.Get(fromSource = e.io.wa_source,
                      toAddress  = e.io.wa_addr(we.bundle.addressBits - 1, 0),
                      lgSize     = 6.U)._2
  e.io.wa_ready  := w.a.ready
  w.d.ready      := true.B
  e.io.wd_valid  := w.d.valid && w.d.bits.opcode === TLMessages.AccessAckData
  e.io.wd_source := w.d.bits.source
  e.io.wd_data   := w.d.bits.data
  e.io.wd_error  := w.d.bits.denied || w.d.bits.corrupt

  // ---- A: 64-byte Gets, and PutFullData bursts of 8, 16, 32 or 64 bytes ---------------------
  // The strided drain (mbxr_st.v) splits a row of the output tensor into naturally aligned
  // power-of-two transactions rather than writing whole blocks with byte masks, so the size is
  // per transaction and the opcode stays PutFullData -- no PutPartialData on this path, and so
  // no read-modify-write in the L2.  A Get is always a whole cache block.
  val aAddr = e.io.aa_addr(ae.bundle.addressBits - 1, 0)
  val aLg   = 3.U(3.W) + e.io.aa_size
  val aGet  = ae.Get(fromSource = e.io.aa_source, toAddress = aAddr, lgSize = 6.U)._2
  val aPut  = ae.Put(fromSource = e.io.aa_source, toAddress = aAddr, lgSize = aLg,
                     data = e.io.aa_data)._2
  a.a.valid := e.io.aa_valid
  a.a.bits  := Mux(e.io.aa_put, aPut, aGet)
  e.io.aa_ready  := a.a.ready
  a.d.ready      := true.B
  e.io.ad_valid  := a.d.valid
  e.io.ad_ack    := a.d.bits.opcode === TLMessages.AccessAck
  e.io.ad_source := a.d.bits.source
  e.io.ad_data   := a.d.bits.data
  e.io.ad_error  := a.d.bits.denied || a.d.bits.corrupt
}

// ---- revision 2b: the hook the W-lane build fills (RoccMoonWLane.scala) -------------------------
/** Builds revision 2b's engine for the injector: the core on the system bus, the weight half in the W
  * lane's domain, and mbxr_wquiet on the lane's pins.  Its implementation references chipyard.wlane,
  * which exists only in a tree with patches/0110, so it lives in RoccMoonWLane.scala, which
  * scripts/62 installs only alongside that patch.  With no builder in the configuration, a
  * `wLane = true` configuration is refused at elaboration, and this file compiles in any tree. */
trait RoccMoonWLaneBuild {
  def apply(p: Parameters, baseSubsystem: BaseSubsystem, params: RoccMoonParams):
    (BundleBridgeSink[RoccMoonCmd], BundleBridgeSource[RoccMoonRsp])
}
case object RoccMoonWLaneBuildKey extends Field[Option[RoccMoonWLaneBuild]](None)

case object RoccMoonInjector extends SubsystemInjector((p, baseSubsystem) => {
  p(RoccMoonKey).foreach { params =>
    implicit val q: Parameters = p
    val sbus = baseSubsystem.locateTLBusWrapper(SBUS)
    val wbus = baseSubsystem.locateTLBusWrapper(params.weightBus)

    // An MBUS weight client is only a configuration change while MBUS shares the core's
    // clock.  With lever 2's memory clock the fill FSM and the scratchpad's BRAM write port
    // belong in the memory domain (ROCC_DECOUPLED.md 7.6); that is not built, so refuse.
    if (params.weightBus == MBUS) {
      val sameClock = p(SbusToMbusXTypeKey) match {
        case _: AsynchronousCrossing | _: RationalCrossing => false
        case _ => true
      }
      require(sameClock,
        "RoccMoon: weights on MBUS across an sbus->mbus clock crossing needs the fill path " +
        "moved into the memory domain, which this build does not have")
    }

    val (cmdNode, rspNode) = if (!params.wLane) {
      val eng = sbus { LazyModule(new RoccMoonEngine(params)) }
      sbus.coupleFrom("roccmoon_a") { _ := TLBuffer() := TLWidthWidget(8) := eng.aNode }
      wbus.coupleFrom("roccmoon_w") { _ := TLBuffer() := TLWidthWidget(8) := eng.wNode }
      (eng.cmdNode, eng.rspNode)
    } else {
      // Revision 2b (P4): built by RoccMoonWLane.scala's WithRoccMoonWLane, when the tree has it.
      val build = p(RoccMoonWLaneBuildKey).getOrElse(throw new IllegalArgumentException(
        "RoccMoon: wLane = true needs chipyard.roccmoon.WithRoccMoonWLane in the config " +
        "(RoccMoonWLane.scala, installed by scripts/62 with patches/0110)"))
      build(p, baseSubsystem, params)
    }

    val tiles = baseSubsystem.asInstanceOf[InstantiatesHierarchicalElements].totalTiles
    require(tiles.contains(params.hart), s"RoccMoon: no tile ${params.hart}")
    val shims = tiles(params.hart).asInstanceOf[RocketTile].roccs.collect { case s: RoccMoonShim => s }
    require(shims.size == 1,
      s"RoccMoon: tile ${params.hart} has ${shims.size} RoccMoonShim(s); is WithMultiRoCC in the config?")
    cmdNode := shims.head.cmdNode
    shims.head.rspNode := rspNode
  }
})

/** The engine on `hart`, custom-1, weights on `weightBus`.  Needs chipyard.config.WithMultiRoCC
  * in the same config and patches/0101 in rocket-chip.  `wLane = true` is revision 2b (P4): it also
  * needs WithRoccMoonWLane (RoccMoonWLane.scala), chipyard.wlane.WithWLane and patches/0110, and the
  * rev2 RTL in the Vivado project. */
class WithRoccMoon(hart: Int = 1, weightBus: TLBusWrapperLocation = SBUS, nch: Int = 4, wLane: Boolean = false)
    extends Config((site, here, up) => {
  case RoccMoonKey => Some(RoccMoonParams(hart = hart, weightBus = weightBus, nch = nch, wLane = wLane))
  // patches/0101: RoCCDecode claims custom-1 (0x2B) only, so hart 1 still TRAPS on MBP's
  // custom-0.  Harmless on tile 0, which has no RoCC and therefore no RoCCDecode.
  case freechips.rocketchip.rocket.RoCCDecodeOpcodes => Some(Seq(BigInt(0x2b)))
  case SubsystemInjectorKey => up(SubsystemInjectorKey) + RoccMoonInjector
  case chipyard.config.MultiRoCCKey => up(chipyard.config.MultiRoCCKey) +
    (hart -> Seq((q: Parameters) => LazyModule(new RoccMoonShim(OpcodeSet.custom1)(q))))
})
