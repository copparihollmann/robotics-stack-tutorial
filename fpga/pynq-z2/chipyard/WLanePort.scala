// SPDX-License-Identifier: Apache-2.0
//
// WLanePort -- a private AXI4 memory channel on its OWN clock, for an accelerator's read-only weight lane.
// MEMORY_BANDWIDTH.md section 9.9, design (ii').
//
// WHY A SEPARATE CHANNEL AND NOT THE MEMORY BUS.  A requester lane on the memory bus needs the memory bus on
// a fast clock (FCLK1), and then every hart's DRAM access through the L2 pays the sbus->mbus crossing: cores'
// DRAM 1.369 -> 1.318 B/cycle at 100-111 MHz, measured on every such build.  A weight lane does not need the
// memory bus at all: it reads a baked, contiguous weight image the PS wrote before reset, never dirty in any
// cache.  So it gets its own TileLink -> AXI4 chain, in its own clock domain, out of its own ChipTop port, to
// its own HP port -- and the L2's channel stays exactly as it was, on the core clock.
//
// WHAT THIS FILE ADDS, AND WHAT IT LEAVES TO THE CLIENT.
//   * WLaneKey / WithWLane: the channel's parameters, a "wlane" clock group (so WithPassthroughClockGenerator
//     gives ChipTop a `clock_wlane` port, as it gave `clock_mem` for the memory bus), and the IOBinder and
//     harness binder below.
//   * CanHaveWLanePort: a subsystem trait (mixed into DigitalTop by patches/0110).  When WLaneKey is unset it
//     creates nothing -- no node, no port, no clock sink -- so every other config elaborates byte-identically.
//     When set, `wlane.get.inward` is a TileLink inward node IN THE WLANE CLOCK DOMAIN: TLBuffer -> TLToAXI4
//     -> AXI4IdIndexer -> AXI4UserYanker -> an AXI4 slave node covering the DDR window, READ-ONLY.
//   * The client (the engine's weight DMA, RoccMoon.scala P4) couples into `inward` and takes its clock from
//     `wlane.get.clockNode`; this file does not know who the client is.
//   * WithWLanePunchthrough: ChipTop port `axi4_wlane_0` (ClockedIO[AXI4Bundle]).  The port type is chipyard's
//     own AXI4MemPort, so the TestHarness attaches a simulated memory with the stock binders, unchanged.
//
// READ-ONLY BY CONSTRUCTION.  The slave advertises Get only.  A Put from any client is a diplomacy error at
// elaboration, so nothing on this channel can write the DDR the harts share.
//
// THE RESET HOLD (resetHold = true; MEMORY_BANDWIDTH.md s9.9, the final W-lane gate).  A reset of the lane domain that
// is released while AXI bursts are still outstanding lets their late RLASTs reach a freshly reset TLToAXI4, whose
// per-source in-flight flag then wraps from 0 to 1 and stalls that source for good.  So after every reset the lane
// domain is held in reset until the client says the lane's AXI4 pins are quiet (ARs issued == RLASTs received):
//   hold    <= rst ? 1 : (quiet ? 0 : hold)       -- one flop, NO RESET, INIT 0 (Vivado's FDRE default)
//   rst_out  = ResetCatchAndSync(clock, rst | hold)   -- async assert, sync deassert, 3 flops, as ClockGroupResetSynchronizer
// The OR feeds only the synchroniser's asynchronous input; rst and hold are both flop outputs and never change in
// opposite directions in one cycle (hold rises a cycle after rst, and falls only while rst is low).  hold samples rst
// as data: at rst's asynchronous assertion that flop may resolve late, but rst itself is then already asserting the
// output, and it stays asserted for many cycles.  `quiet` must be produced on the lane clock by a counter that no
// reset touches (the client's job: see RoccMoon.scala, mbxr_wquiet).  If the lane's PS never delivers an outstanding
// RLAST, the lane stays in reset: the lane is dead either way, and the client must time out rather than wait.
//
// THE FPGA SIDE (not in this file): src/pynqz2_rocket_top.v `PYNQZ2_WLANE` wires `axi4_wlane_0` through its own
// axi4_to_axi3 onto S_AXI_HP2 (DDR controller port 2) with the same {4'd1, addr[27:0]} fold, clocked by FCLK1;
// tcl/build_rocket.tcl `has_wlane`; scripts/check_mem_contract.py sizes it like `axi4_mem_*`.

package chipyard.wlane

import chisel3._
import chisel3.reflect.DataMirror
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import org.chipsalliance.diplomacy.lazymodule._
import freechips.rocketchip.diplomacy.{AddressSet, RegionType, TransferSizes}
import freechips.rocketchip.amba.axi4.{AXI4Bundle, AXI4SlaveNode, AXI4SlavePortParameters, AXI4SlaveParameters,
  AXI4UserYanker, AXI4IdIndexer}
import freechips.rocketchip.tilelink.{TLToAXI4, TLBuffer, TLInwardNode, TLNameNode}
import freechips.rocketchip.prci._
import freechips.rocketchip.subsystem._
import chipyard.iobinders.{OverrideLazyIOBinder, GetSystemParameters, AXI4MemPort}
import freechips.rocketchip.util.ResetCatchAndSync
import testchipip.util.ClockedIO

case class WLaneParams(
  base:      BigInt = 0x80000000L,   // the ExtMem window the weights live in
  size:      BigInt = 0x10000000L,
  beatBytes: Int    = 8,             // S_AXI_HP ports are 64-bit
  idBits:    Int    = 4,             // S_AXI_HP IDs are 6 bits; the shim adds nothing
  getBytes:  Int    = 64,            // 8-beat bursts on the pins (MEMORY_BANDWIDTH.md s9.7: 8 or 16 only)
  freqMHz:   Double = 100.0,         // a DTS/harness value; the real clock is FCLK1, set and read back
  clockName: String = "wlane",
  resetHold: Boolean = false)        // hold the lane in reset until its pins are quiet (needs a `quiet` driver)

case object WLaneKey extends Field[Option[WLaneParams]](None)

/** The lane domain's reset, held after every reset until `io.quiet` (see the file header). */
class WLaneResetHold(implicit p: Parameters) extends LazyModule {
  val node = ClockAdapterNode()
  lazy val module = new Impl
  class Impl extends LazyRawModuleImp(this) {
    val io = IO(new Bundle { val quiet = Input(Bool()) })   // lane clock, from a reset-free AR/RLAST balance counter
    require(node.in.size == 1 && node.out.size == 1, "WLaneResetHold: one clock in, one clock out")
    val (o, _) = node.out.head
    val (i, _) = node.in.head
    o.clock := i.clock
    val hold = withClock(i.clock) { Reg(Bool()) }            // no reset: INIT 0
    hold := Mux(i.reset.asBool, true.B, Mux(io.quiet, false.B, hold))
    o.reset := ResetCatchAndSync(i.clock, i.reset.asBool || hold, name = Some("wlane_rst_sync"))
  }
}

/** The channel: a clock sink named `clockName`, and the TileLink -> AXI4 chain inside it. */
class WLane(val params: WLaneParams)(implicit p: Parameters) {
  require(Seq(64, 128).contains(params.getBytes), s"WLane: 64- or 128-byte Gets (8 or 16 beats), not ${params.getBytes}")

  // One clock group member, named so the combiner can give it a group of its own.
  val clockGroup = LazyModule(new ClockGroup(params.clockName))
  val domain = LazyModule(new ClockSinkDomain(ClockSinkParameters(
    name = Some(params.clockName), take = Some(ClockParameters(params.freqMHz)))))
  val clockNode = FixedClockBroadcast(None)
  /** Present when params.resetHold: the client must drive `resetHold.get.module.io.quiet`. */
  val resetHold: Option[WLaneResetHold] = if (params.resetHold) Some(LazyModule(new WLaneResetHold)) else None
  resetHold match {
    case Some(h) => domain.clockNode := h.node := clockNode
    case None    => domain.clockNode := clockNode
  }
  clockNode := clockGroup.node

  val axi = AXI4SlaveNode(Seq(AXI4SlavePortParameters(
    slaves = Seq(AXI4SlaveParameters(
      address       = AddressSet.misaligned(params.base, params.size),
      regionType    = RegionType.UNCACHED,
      executable    = false,
      supportsRead  = TransferSizes(1, params.getBytes),
      supportsWrite = TransferSizes.none,
      interleavedId = Some(0))),
    beatBytes = params.beatBytes)))

  val inward: TLInwardNode = domain {
    val name = TLNameNode("wlane_in")
    (axi
      := AXI4UserYanker()
      := AXI4IdIndexer(params.idBits)
      := TLToAXI4()
      := TLBuffer()
      := name)
    name
  }
}

trait CanHaveWLanePort { this: BaseSubsystem =>
  /** Lazy, so a SubsystemInjector that runs before this trait's body can still reach it. */
  lazy val wlane: Option[WLane] = p(WLaneKey).map { w =>
    val l = new WLane(w)(p)
    l.clockGroup.node := allClockGroupsNode
    l
  }
  val wlane_axi4 = wlane.map(l => InModuleBody { l.axi.makeIOs() })
}

/** ChipTop port `axi4_wlane_0`, clocked by the lane's own clock.  AXI4MemPort, so the harness's stock
  * WithSimAXIMem / WithBlackBoxSimMem attach a memory to it in simulation. */
class WithWLanePunchthrough extends OverrideLazyIOBinder({
  (system: CanHaveWLanePort) => {
    implicit val p: Parameters = GetSystemParameters(system)
    val clockSinkNode = system.wlane.map(_ => ClockSinkNode(Seq(ClockSinkParameters())))
    clockSinkNode.foreach(_ := system.wlane.get.clockNode)
    InModuleBody {
      val ports: Seq[AXI4MemPort] = system.wlane_axi4.toSeq.flatMap { mv =>
        val bag = mv.getWrappedValue
        bag.zipWithIndex.map { case (m, i) =>
          val w = system.wlane.get.params
          val port = IO(new ClockedIO(DataMirror.internal.chiselTypeClone[AXI4Bundle](m))).suggestName(s"axi4_wlane_${i}")
          port.bits <> m
          port.clock := clockSinkNode.get.in.head._1.clock
          AXI4MemPort(() => port,
            MemoryPortParams(MasterPortParams(base = w.base, size = w.size, beatBytes = w.beatBytes, idBits = w.idBits), 1),
            system.wlane.get.axi.edges.in(i), w.freqMHz.toInt)
        }
      }
      (ports, Nil)
    }
  }
})

/** The lane's own clock group, appended to the combiner the way WithTileClockGroup appends "tile". */
class WithWLaneClockGroup(clockName: String = "wlane") extends Config((site, here, up) => {
  case chipyard.clocking.ClockGroupCombinerKey => up(chipyard.clocking.ClockGroupCombinerKey, site) :+
    ((clockName, (m: ClockSinkParameters) => m.name.get.contains(clockName)))
})

class WithWLane(freqMHz: Double = 100.0, base: BigInt = 0x80000000L, size: BigInt = 0x10000000L,
                getBytes: Int = 64, resetHold: Boolean = false) extends Config(
  new WithWLanePunchthrough ++
  new WithWLaneClockGroup ++
  new Config((site, here, up) => {
    case WLaneKey => Some(WLaneParams(base = base, size = size, getBytes = getBytes, freqMHz = freqMHz, resetHold = resetHold))
  }))
