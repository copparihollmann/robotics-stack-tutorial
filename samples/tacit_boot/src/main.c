/*
 * TACIT tracing from the reset vector: Rocket on a PYNQ-Z1, sink = DMA to DRAM.
 *
 * samples/tacit_dma brackets only workload() with start/stop, so its trace opens inside
 * main(). This one is enabled in arch/riscv/core/reset.S, before anything else runs, so
 * the trace covers z_prep_c, the BSS zeroing, z_cstart, the device init levels, the boot
 * banner and then the same workload -- the whole unikernel lifecycle, which is what Lab
 * A's Spike trace shows.
 *
 * What reset.S does, and why the order is not negotiable:
 *
 *   1. TR_SK_DMA_ADDR = CONFIG_STARTUP_TACIT_SINK_DMA_ADDR
 *   2. TR_TE_TARGET   = CONFIG_STARTUP_TACIT_TARGET   (1: the DMA sink)
 *   3. fence
 *   4. TR_TE_CTRL     = 0x2                           (enable)
 *
 * The encoder emits its sync packet -- the absolute PC the decoder starts from -- on the
 * 0->1 edge of enable, and TR_TE_TARGET is a live mux into TraceSinkArbiter rather than a
 * latched configuration. Enable first and re-target later and the sink's byte stream
 * begins in the middle of a packet; the decoder has nothing to lock onto. Stock reset.S
 * does exactly that (enable, no target), and since this SoC has no sink at target 0 and
 * TraceSinkArbiter drives ready for unmatched targets, the boot trace is accepted at full
 * rate and discarded without a word.
 *
 * main() only closes the capture:
 *
 *   5. workload
 *   6. encoder OFF     the encoder re-enters sSync and emits a trailing sync packet,
 *                      which only advances on retired instructions: hence the nop spin.
 *   7. sink flush      the sink writes whole 8-byte beats; flush pushes the tail out and
 *                      makes addr_counter final.
 *   8. L2 flush        the sink is a master on the system bus, so its writes land in the
 *                      inclusive L2. The PS reads DRAM. Without this the trace has holes.
 *
 * Addresses are transcribed from the DTS Chipyard emits next to the Verilog:
 *   trace-encoder-controller@3000000, trace-sink-dma@3010000, cache-controller@2010000,
 *   memory@80000000 (256 MB).
 */

#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include <zephyr/arch/cpu.h>

#include <tacit/tacit.h>

/*
 * Where reset.S pointed the sink, in ROCKET's address space. The FPGA top folds Rocket's
 * DRAM window with {4'd1, addr[27:0]}, so Rocket 0x8800_0000 is PS physical 0x1800_0000.
 *
 * 128 MB into a 256 MB window. That distance matters more here than it does in
 * samples/tacit_dma: BSS zeroing, the 0xAA stack fill and the interrupt stacks all run
 * *inside* this traced window, so the buffer has to be clear of everything the boot
 * writes, not just of what a running application writes.
 */
#define TACIT_BUF_ADDR ((uintptr_t)CONFIG_STARTUP_TACIT_SINK_DMA_ADDR)

/* Only used to bound the L2 flush and to sanity-check the byte count. */
#ifndef TACIT_BUF_SIZE
#define TACIT_BUF_SIZE (64UL * 1024 * 1024)
#endif

/* Same kernel and same iteration count as samples/tacit_dma, so the difference between
 * the two traces is exactly the boot. */
#ifndef NUM_ITERS
#define NUM_ITERS 60
#endif

#define M_PI 3.14159265358979323846

/* SiFive InclusiveCache control node: cache-controller@2010000, reg-names "control". */
#define L2_CTRL_BASE   0x2010000UL
#define L2_CONFIG      (L2_CTRL_BASE + 0x000) /* banks | ways<<8 | lgSets<<16 | lgBlk<<24 */
#define L2_FLUSH64     (L2_CTRL_BASE + 0x200) /* write a phys addr -> flush that block */

static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/*
 * Flush a physical range out of the L2.
 *
 * Flush64 is a write-only register whose TileLink write does not complete until the
 * scheduler has finished with that block, so the store itself is the handshake -- there
 * is nothing to poll. Blocks that are not resident answer immediately.
 */
static void l2_flush_range(uintptr_t base, uint64_t bytes, uint32_t block)
{
	volatile uint64_t *flush = (volatile uint64_t *)L2_FLUSH64;
	uintptr_t a = base & ~(uintptr_t)(block - 1);
	uintptr_t end = base + bytes;

	__asm__ volatile("fence" ::: "memory");
	for (; a < end; a += block) {
		*flush = (uint64_t)a;
	}
	__asm__ volatile("fence" ::: "memory");
}

void FOC_invParkTransform(float *v_alpha, float *v_beta, float v_q, float v_d,
			  float sin_theta, float cos_theta)
{
	*v_alpha = -(sin_theta * v_q) + (cos_theta * v_d);
	*v_beta  =  (cos_theta * v_q) + (sin_theta * v_d);
}

void FOC_invClarkSVPWM(float *v_a, float *v_b, float *v_c, float v_alpha, float v_beta)
{
	float v_a_phase = v_alpha;
	float v_b_phase = (-.5f * v_alpha) + ((sqrtf(3.f) / 2.f) * v_beta);
	float v_c_phase = (-.5f * v_alpha) - ((sqrtf(3.f) / 2.f) * v_beta);

	float v_neutral = .5f * (fmaxf(fmaxf(v_a_phase, v_b_phase), v_c_phase) +
				 fminf(fminf(v_a_phase, v_b_phase), v_c_phase));

	*v_a = v_a_phase - v_neutral;
	*v_b = v_b_phase - v_neutral;
	*v_c = v_c_phase - v_neutral;
}

void FOC_update(float *v_a, float *v_b, float *v_c, float vq, float vd)
{
	float v_alpha, v_beta;

	FOC_invParkTransform(&v_alpha, &v_beta, vq, vd, sin(vq), cos(vq));
	FOC_invClarkSVPWM(v_a, v_b, v_c, v_alpha, v_beta);
}

/* The accumulator keeps the soft-float trig alive at -O2; see samples/tacit_dma. */
static float workload(void)
{
	float acc = 0.f;

	for (int i = 0; i < NUM_ITERS; i++) {
		float vq = 2 * M_PI * i / NUM_ITERS;
		float vd = 0;
		float v_a, v_b, v_c;

		for (int j = 0; j < 2; j++) {
			FOC_update(&v_a, &v_b, &v_c, vq, vd);
			acc += v_a + v_b + v_c;
		}
	}
	return acc;
}

int main(void)
{
	LTraceEncoderType *enc = l_trace_encoder_get(arch_curr_cpu()->id);
	LTraceSinkDmaType *sink = l_trace_sink_dma_get(arch_curr_cpu()->id);
	uint64_t t_main, t1, t2;
	uint64_t addr_rb, boot_bytes, count;
	uint32_t ctrl_rb, target_rb;
	uint32_t l2cfg, l2_block;
	float acc;

	/*
	 * Snapshot what reset.S left behind, BEFORE printing anything -- every printf is
	 * inside the traced window and each character is a poll loop on the UART.
	 * addr_counter here is the boot's share of the trace: bytes the sink had already
	 * committed to memory by the time main() was reached.
	 */
	t_main = rdcycle();
	addr_rb = sink->TR_SK_DMA_ADDR;
	ctrl_rb = enc->TR_TE_CTRL;
	target_rb = enc->TR_TE_TARGET;
	boot_bytes = sink->TR_SK_DMA_COUNT;

	/* Trace the same workload samples/tacit_dma traces, so the two are comparable. */
	acc = workload();
	t1 = rdcycle();

	/* 6. stop, then keep retiring: the trailing sync packet rides on pipeline_advance. */
	l_trace_encoder_stop(enc);
	for (volatile int i = 0; i < 2000; i++) {
		__asm__ volatile("nop");
	}

	/* 7. push the sink's partial beat out and freeze addr_counter. */
	sink->TR_SK_DMA_FLUSH = 1;
	while (sink->TR_SK_DMA_FLUSH_DONE == 0) {
	}
	count = sink->TR_SK_DMA_COUNT;

	/* From here on the encoder is off, so printing is free. */
	l2cfg = *(volatile uint32_t *)L2_CONFIG;
	l2_block = 1u << ((l2cfg >> 24) & 0xff);

	printf("tacit_boot on %s\n", CONFIG_BOARD_TARGET);
	printf("l2: banks=%u ways=%u lgSets=%u block=%u\n", l2cfg & 0xff,
	       (l2cfg >> 8) & 0xff, (l2cfg >> 16) & 0xff, l2_block);
	printf("reset.S: ctrl=0x%x target=%u addr=0x%08x%08x\n",
	       (unsigned int)ctrl_rb, (unsigned int)target_rb,
	       (unsigned int)(addr_rb >> 32), (unsigned int)addr_rb);

	if (addr_rb != (uint64_t)TACIT_BUF_ADDR) {
		printf("TACIT_FAIL sink address did not latch in reset.S\n");
		goto done;
	}
	if ((ctrl_rb & 0x2u) == 0u) {
		printf("TACIT_FAIL encoder was not enabled at reset\n");
		goto done;
	}
	if (target_rb != (uint32_t)CONFIG_STARTUP_TACIT_TARGET) {
		printf("TACIT_FAIL encoder target is %u, expected %u\n",
		       (unsigned int)target_rb,
		       (unsigned int)CONFIG_STARTUP_TACIT_TARGET);
		goto done;
	}
	if (boot_bytes == 0u) {
		printf("TACIT_FAIL sink wrote nothing before main()\n");
		goto done;
	}
	if (count > TACIT_BUF_SIZE) {
		printf("TACIT_FAIL count %u exceeds buffer\n", (unsigned int)count);
		goto done;
	}

	/* 8. the sink's writes are in the L2; the PS reads DRAM. */
	t2 = rdcycle();
	l2_flush_range(TACIT_BUF_ADDR, count, l2_block);
	t2 = rdcycle() - t2;

	/*
	 * boot_bytes / boot_cycles are the numbers this sample exists to produce: what the
	 * encoder captured before main() was reached, which samples/tacit_dma cannot see.
	 */
	printf("boot_bytes=%u boot_cycles=%u workload_acc=%d trace_cycles=%u flush_cycles=%u\n",
	       (unsigned int)boot_bytes, (unsigned int)t_main, (int)(acc * 1000.f),
	       (unsigned int)t1, (unsigned int)t2);
	printf("TACIT_DONE addr=0x%08x bytes=%u\n",
	       (unsigned int)TACIT_BUF_ADDR, (unsigned int)count);

done:
	printf("tacit_boot finished\n");
	return 0;
}
