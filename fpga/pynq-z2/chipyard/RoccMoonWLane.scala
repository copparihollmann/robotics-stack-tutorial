// SPDX-License-Identifier: Apache-2.0
//
// RoccMoonWLane.scala -- engine revision 2b's Chisel (P4, MEMORY_BANDWIDTH.md 9.9 design (ii')):
// the weight half on the private W lane.  Split out of RoccMoon.scala because it references
// chipyard.wlane (WLanePort.scala), which exists only in a Chipyard tree with patches/0110:
// scripts/62 installs this file only together with that patch, so RoccMoon.scala compiles in every
// tree.  RoccMoon.scala's injector calls the builder below through RoccMoonWLaneBuildKey.
//
// See RoccMoon.scala's header ("REVISION 2b") for the design; the RTL is rtl_study/roccmoon/rev2.
package chipyard.roccmoon

import chisel3._
import chisel3.util._
import chisel3.experimental.IntParam
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.tilelink._
import freechips.rocketchip.subsystem._
import freechips.rocketchip.prci.{ClockSinkNode, ClockSinkParameters}

// ---- revision 2b: the weight half on its own clock (P4) -------------------------------------
/** Core -> weight half: mbxr_engine_core's wh_* outputs.  `req` toggles on an accepted weight load;
  * the rest are quasi-static from `sd`/`ld`/`cap` until the fill clears (mbxr_wx.v). */
class RoccMoonWReq extends Bundle {
  val req    = Bool()
  val base   = UInt(40.W)
  val rblk   = UInt(16.W)
  val rows   = UInt(16.W)
  val stride = UInt(32.W)
  val fbuf   = Bool()
  val lgpw   = UInt(4.W)
  val cap    = UInt(4.W)
}

/** Weight half -> core: completion and error toggles, the Gray-coded word count, the in-flight
  * diagnostic, and the weight banks' write port with its clock (the weight half's). */
class RoccMoonWRsp extends Bundle {
  val done      = Bool()
  val ready     = Bool()          // mbxr_whalf.ready_o -> mbxr_engine_core.wh_ready (fence bit 41)
  val beatsGray = UInt(32.W)
  val errTog    = Bool()
  val inflight  = UInt(8.W)
  val wwClk     = Clock()
  val wwEn      = Bool()
  val wwWord    = UInt(16.W)
  val wwData    = UInt(64.W)
}

class mbxr_engine_core(params: RoccMoonParams) extends BlackBox(Map(
    "W_ASYNC" -> IntParam(1),
    "NCH"     -> IntParam(params.nch),
    "LDEPTH"  -> IntParam(params.ldepth),
    "SDEPTH"  -> IntParam(params.sdepth))) {
  val io = IO(new Bundle {
    val clk           = Input(Clock())
    val rst           = Input(Bool())
    val cmd_valid     = Input(Bool())
    val cmd_funct     = Input(UInt(7.W))
    val cmd_rs1       = Input(UInt(64.W))
    val cmd_rs2       = Input(UInt(64.W))
    val cmd_xd        = Input(Bool())
    val resp_valid    = Output(Bool())
    val resp_data     = Output(UInt(64.W))
    val busy          = Output(Bool())
    val wh_req        = Output(Bool())
    val wh_base       = Output(UInt(40.W))
    val wh_rblk       = Output(UInt(16.W))
    val wh_rows       = Output(UInt(16.W))
    val wh_stride     = Output(UInt(32.W))
    val wh_fbuf       = Output(Bool())
    val wh_lgpw       = Output(UInt(4.W))
    val wh_cap        = Output(UInt(4.W))
    val wh_done       = Input(Bool())
    val wh_beats_gray = Input(UInt(32.W))
    val wh_err_tog    = Input(Bool())
    val wh_inflight   = Input(UInt(8.W))
    val wh_ready      = Input(Bool())
    val ww_clk        = Input(Clock())
    val ww_en         = Input(Bool())
    val ww_word       = Input(UInt(16.W))
    val ww_data       = Input(UInt(64.W))
    val aa_valid      = Output(Bool())
    val aa_ready      = Input(Bool())
    val aa_put        = Output(Bool())
    val aa_size       = Output(UInt(2.W))
    val aa_addr       = Output(UInt(40.W))
    val aa_source     = Output(UInt(4.W))
    val aa_data       = Output(UInt(64.W))
    val aa_last       = Output(Bool())
    val ad_valid      = Input(Bool())
    val ad_ack        = Input(Bool())
    val ad_source     = Input(UInt(4.W))
    val ad_data       = Input(UInt(64.W))
    val ad_error      = Input(Bool())
  })
}

class mbxr_whalf(params: RoccMoonParams, winLo: BigInt, winHi: BigInt) extends BlackBox(Map(
    "W_ASYNC"  -> IntParam(1),
    "NCH"      -> IntParam(params.nch),
    "LDEPTH"   -> IntParam(params.ldepth),
    "W_WIN_LO" -> IntParam(winLo),     // 41-bit, the window is [W_WIN_LO, W_WIN_HI)
    "W_WIN_HI" -> IntParam(winHi))) {
  val io = IO(new Bundle {
    val clk        = Input(Clock())
    val rst        = Input(Bool())
    val w_quiet    = Input(Bool())
    val req        = Input(Bool())
    val base       = Input(UInt(40.W))
    val rblk       = Input(UInt(16.W))
    val rows       = Input(UInt(16.W))
    val stride     = Input(UInt(32.W))
    val fbuf       = Input(Bool())
    val lgpw       = Input(UInt(4.W))
    val cap        = Input(UInt(4.W))
    val done       = Output(Bool())
    val beats_gray = Output(UInt(32.W))
    val err_tog    = Output(Bool())
    val inflight_o = Output(UInt(8.W))
    val ready_o    = Output(Bool())
    val wa_valid   = Output(Bool())
    val wa_ready   = Input(Bool())
    val wa_addr    = Output(UInt(40.W))
    val wa_source  = Output(UInt(4.W))
    val wd_valid   = Input(Bool())
    val wd_source  = Input(UInt(4.W))
    val wd_data    = Input(UInt(64.W))
    val wd_error   = Input(Bool())
    val ww_en      = Output(Bool())
    val ww_word    = Output(UInt(16.W))
    val ww_data    = Output(UInt(64.W))
  })
}

/** The reset-free AR/RLAST balance counter (rtl_study/roccmoon/rev2/mbxr_wx.v, W_QUIET).  No reset
  * port by design; see the file header. */
class mbxr_wquiet extends BlackBox {
  val io = IO(new Bundle {
    val aclk        = Input(Clock())
    val ar_fire     = Input(Bool())
    val r_last_fire = Input(Bool())
    val quiet       = Output(Bool())
  })
}

/** Everything but the weight half, on the system bus's clock: client A, the command bridges, and
  * the two bridges to the weight half. */
class RoccMoonEngine2b(val params: RoccMoonParams)(implicit p: Parameters) extends LazyModule {
  require(params.ldepth + params.sdepth <= 16, "source IDs are 4 bits")

  val aNode = TLClientNode(Seq(TLMasterPortParameters.v1(Seq(TLMasterParameters.v1(
    name = "roccmoon_a", sourceId = IdRange(0, params.ldepth + params.sdepth))))))

  val cmdNode  = BundleBridgeSink[RoccMoonCmd]()
  val rspNode  = BundleBridgeSource(() => new RoccMoonRsp)
  val wReqNode = BundleBridgeSource(() => new RoccMoonWReq)
  val wRspNode = BundleBridgeSink[RoccMoonWRsp]()

  lazy val module = new RoccMoonEngine2bImp(this)
}

class RoccMoonEngine2bImp(outer: RoccMoonEngine2b) extends LazyModuleImp(outer) {
  val params = outer.params
  val (a, ae) = outer.aNode.out(0)
  require(ae.bundle.dataBits == 64, s"mbxr_engine_core needs 64-bit beats at client A (${ae.bundle.dataBits})")

  val e = Module(new mbxr_engine_core(params))
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

  // ---- to and from the weight half: wires only (the RTL synchronises; see the file header) ----
  val q = outer.wReqNode.bundle
  q.req    := e.io.wh_req
  q.base   := e.io.wh_base
  q.rblk   := e.io.wh_rblk
  q.rows   := e.io.wh_rows
  q.stride := e.io.wh_stride
  q.fbuf   := e.io.wh_fbuf
  q.lgpw   := e.io.wh_lgpw
  q.cap    := e.io.wh_cap

  val w = outer.wRspNode.bundle
  e.io.wh_done       := w.done
  e.io.wh_beats_gray := w.beatsGray
  e.io.wh_err_tog    := w.errTog
  e.io.wh_inflight   := w.inflight
  e.io.wh_ready      := w.ready
  e.io.ww_clk        := w.wwClk
  e.io.ww_en         := w.wwEn
  e.io.ww_word       := w.wwWord
  e.io.ww_data       := w.wwData

  // ---- A: Gets and 8-beat PutFullData bursts (as revision 1) --------------------------------
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

/** The weight half.  Instantiated inside the W lane's ClockSinkDomain, so `clock` and `reset` are
  * the lane's (FCLK1 on the board). */
class RoccMoonWHalf(val params: RoccMoonParams, val winLo: BigInt, val winHi: BigInt)(implicit p: Parameters)
    extends LazyModule {
  require(winLo >= 0 && winLo < winHi && winHi <= (BigInt(1) << 40),
    s"RoccMoon: weight window [0x${winLo.toString(16)}, 0x${winHi.toString(16)}) must lie in the 40-bit address space")
  val wNode = TLClientNode(Seq(TLMasterPortParameters.v1(Seq(TLMasterParameters.v1(
    name = "roccmoon_w", sourceId = IdRange(0, params.ldepth))))))
  val wReqNode  = BundleBridgeSink[RoccMoonWReq]()
  val wRspNode  = BundleBridgeSource(() => new RoccMoonWRsp)
  val quietNode = BundleBridgeSink[Bool]()      // mbxr_wquiet's output, lane clock
  lazy val module = new RoccMoonWHalfImp(this)
}

class RoccMoonWHalfImp(outer: RoccMoonWHalf) extends LazyModuleImp(outer) {
  val params = outer.params
  val (w, we) = outer.wNode.out(0)
  require(we.bundle.dataBits == 64, s"mbxr_whalf needs 64-bit beats at client W (${we.bundle.dataBits})")

  val e = Module(new mbxr_whalf(params, outer.winLo, outer.winHi))
  e.io.clk     := clock
  e.io.rst     := reset.asBool
  e.io.w_quiet := outer.quietNode.bundle

  val q = outer.wReqNode.bundle
  e.io.req    := q.req
  e.io.base   := q.base
  e.io.rblk   := q.rblk
  e.io.rows   := q.rows
  e.io.stride := q.stride
  e.io.fbuf   := q.fbuf
  e.io.lgpw   := q.lgpw
  e.io.cap    := q.cap

  val r = outer.wRspNode.bundle
  r.done      := e.io.done
  r.beatsGray := e.io.beats_gray
  r.errTog    := e.io.err_tog
  r.inflight  := e.io.inflight_o
  r.ready     := e.io.ready_o
  r.wwClk     := clock
  r.wwEn      := e.io.ww_en
  r.wwWord    := e.io.ww_word
  r.wwData    := e.io.ww_data

  // ---- W: Gets (as revision 1) -------------------------------------------------------------
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
}


object RoccMoonWLaneBuilder extends RoccMoonWLaneBuild {
  def apply(p: Parameters, baseSubsystem: BaseSubsystem, params: RoccMoonParams):
      (BundleBridgeSink[RoccMoonCmd], BundleBridgeSource[RoccMoonRsp]) = {
    implicit val q: Parameters = p
    val sbus = baseSubsystem.locateTLBusWrapper(SBUS)
    require(params.weightBus == SBUS,
      "RoccMoon: wLane replaces weightBus; leave weightBus at its default")
    val wl = baseSubsystem match {
      case s: chipyard.wlane.CanHaveWLanePort => s.wlane.getOrElse(throw new IllegalArgumentException(
        "RoccMoon: wLane needs chipyard.wlane.WithWLane in the config"))
      case _ => throw new IllegalArgumentException(
        "RoccMoon: wLane needs DigitalTop to mix in chipyard.wlane.CanHaveWLanePort (patches/0110)")
    }
    // The lane's AXI side is 64-bit with 8-beat bursts; the weight half issues 64-byte Gets of
    // 64-bit beats, so no width widget sits between them.
    require(wl.params.beatBytes == 8 && wl.params.getBytes == 64,
      s"RoccMoon: the W lane must be 8 bytes/beat and 64-byte Gets (is ${wl.params.beatBytes}, ${wl.params.getBytes})")
    require(params.ldepth <= (1 << wl.params.idBits),
      s"RoccMoon: ${params.ldepth} W sources do not fit the lane's ${wl.params.idBits}-bit AXI IDs")
    // THE LANE'S RESET IS HELD UNTIL ITS PINS ARE QUIET (MEMORY_BANDWIDTH.md 9.9, the W-lane gate).  A reset released
    // while AXI bursts are still outstanding lets their late RLASTs reach a freshly reset TLToAXI4, whose per-source
    // in-flight flag wraps from 0 to 1 and stalls that source for good: the next weight load then stops at its first
    // Get and FILL never clears.  WithWLane(resetHold = true) puts the hold in the lane's reset path, and mbxr_wquiet
    // below drives it -- the same `quiet` the weight half holds new loads on, and the same one fence bit 41 reports.
    require(wl.resetHold.isDefined,
      "RoccMoon: wLane needs chipyard.wlane.WithWLane(resetHold = true); the gate fails without it")
    val eng = sbus { LazyModule(new RoccMoonEngine2b(params)) }
    val wh  = wl.domain { LazyModule(new RoccMoonWHalf(params, wl.params.base, wl.params.base + wl.params.size)) }
    sbus.coupleFrom("roccmoon_a") { _ := TLBuffer() := TLWidthWidget(8) := eng.aNode }
    wl.inward := wh.wNode
    wh.wReqNode := eng.wReqNode
    eng.wRspNode := wh.wRspNode

    // W_QUIET at the lane's AXI4 master pins.  The pins (wl.axi's inward edge, the ChipTop port) live
    // in this subsystem module, so the counter is built here, clocked from the lane's clock node and
    // with no reset: a BlackBox gets no implicit reset, and this is outside every clock domain block.
    val quietClock = ClockSinkNode(Seq(ClockSinkParameters(name = Some("roccmoon_wquiet"))))
    quietClock := wl.clockNode
    val quietSrc = BundleBridgeSource(() => Bool())
    wh.quietNode := quietSrc
    InModuleBody {
      val (pins, _) = wl.axi.in.head
      val wq = Module(new mbxr_wquiet).suggestName("roccmoon_wquiet")
      wq.io.aclk        := quietClock.in.head._1.clock
      wq.io.ar_fire     := pins.ar.valid && pins.ar.ready
      wq.io.r_last_fire := pins.r.valid && pins.r.ready && pins.r.bits.last
      quietSrc.bundle   := wq.io.quiet
      wl.resetHold.get.module.io.quiet := wq.io.quiet   // the lane's reset hold (WLanePort.scala), same clock, no crossing
    }

    (eng.cmdNode, eng.rspNode)
  }
}

/** Revision 2b's engine: WithRoccMoon(wLane = true) plus the builder.  Needs chipyard.wlane.WithWLane
  * and patches/0110 in the tree. */
class WithRoccMoonWLane extends Config((site, here, up) => {
  case RoccMoonWLaneBuildKey => Some(RoccMoonWLaneBuilder)
  case RoccMoonKey => up(RoccMoonKey, site).map(_.copy(wLane = true))
})
