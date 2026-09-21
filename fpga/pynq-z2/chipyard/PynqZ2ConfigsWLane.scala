// SPDX-License-Identifier: Apache-2.0
// THE 2b CONFIG LIVES HERE, NOT IN PynqZ2Configs.scala, for the same reason RoccMoonWLane.scala does:
// it names chipyard.wlane and chipyard.roccmoon.WithRoccMoonWLane, which exist only in a tree that has
// patches/0110 applied.  With this block inside PynqZ2Configs.scala the shared donor tree could not
// compile AT ALL without 0110 -- not this config, not the camera's, not the base P-extension one -- so
// every elaboration and the MBP RTL selftest failed with 'object wlane is not a member of package
// chipyard' (found 2026-09-17 when the selftest was run against 0x5A5A0028 after the fact).
// scripts/62_patch_chipyard_roccmoon.sh installs this file only alongside patches/0110 and removes a
// stale copy otherwise.
package chipyard
import chisel3._
import org.chipsalliance.cde.config.Config

// ENGINE REVISION 2b: THE WEIGHT HALF ON ITS OWN AXI4 CHANNEL.  SOC_MAGIC 0x5A5A0013
// (MEMORY_BANDWIDTH.md sections 9.9 and 9.10, design (ii')).
//
// 0x5A5A0028 plus the W lane, and nothing else: the engine's weight half moves into the lane's clock
// domain (chipyard.wlane, patches/0110) and its Gets leave the system bus for ChipTop's axi4_wlane_0,
// which the top level takes onto S_AXI_HP2 at FCLK1 = 100 MHz.  Activations and results stay on SBUS
// through the L2, so the coherence contract does not change; the memory bus stays on FCLK0, so the
// harts' path is untouched.
//
// WithRoccMoonWLane MUST PRECEDE WithRoccMoon (which RoccMoonAllConfig carries): it sets the builder
// and copies wLane = true onto the params through up(RoccMoonKey), so it has to see them.
// WithWLane(resetHold = true) is required by the builder: without the hold, a short reset releases the
// lane with bursts outstanding and the next weight load stalls for good (s9.9, the W-lane gate).
class PynqZ2RocketBigLittlePextTacitMicRgbRoccMoon2bConfig extends Config(
  new chipyard.roccmoon.WithRoccMoonWLane ++
  new chipyard.wlane.WithWLane(freqMHz = 100.0, resetHold = true) ++
  new PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonAllConfig)
