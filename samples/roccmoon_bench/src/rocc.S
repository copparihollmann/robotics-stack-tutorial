/* SPDX-License-Identifier: Apache-2.0
 *
 * The decoupled engine's nine commands, as custom-1 (0x2B) RoCC instructions.
 *
 * rs1 = a0, rs2 = a1.  funct3 is RoCC's {xd, xs1, xs2}: 011 for a command that only sends,
 * 111 for one whose reply lands in rd = a0.  One stub per funct7 because `.insn` needs the
 * funct7 as a constant; mbxr_rocc_cmd() in main.c picks the stub.
 */
#define NOXD(f) .globl mbxr_rocc_##f; .type mbxr_rocc_##f, @function; mbxr_rocc_##f: .insn r 0x2B, 3, f, x0, a0, a1; ret
#define XD(f)   .globl mbxr_roccx_##f; .type mbxr_roccx_##f, @function; mbxr_roccx_##f: .insn r 0x2B, 7, f, a0, a0, a1; ret

	.text
	.balign 4
NOXD(0)
NOXD(1)
NOXD(2)
NOXD(3)
NOXD(4)
NOXD(5)
XD(6)
XD(7)
NOXD(8)
