/*
 * TACIT tracing on real silicon: Rocket on a PYNQ-Z1, trace sink = DMA to DRAM.
 *
 * samples/tacit (Lab A) points the encoder at sink target 0, the "always ready" sink that
 * a simulator taps to write a file. On the FPGA that sink is not even instantiated --
 * PynqZ2RocketTacitConfig has only `tacit.WithTraceSinkDMA(1)` -- so target 0 means the
 * arbiter accepts every byte and discards it. This sample uses target 1, the DMA sink,
 * which streams the encoded bytes into DRAM where the PS can read them over /dev/mem.
 *
 * The order below matters:
 *
 *   1. encoder OFF          the encoder emits its sync packet on the 0->1 edge of enable;
 *                           the sink target is a live mux, so re-targeting a running
 *                           encoder hands the sink a packet that starts mid-stream.
 *   2. sink address         TraceSinkDMA only latches dma_start_addr while its write FSM
 *                           is idle, and acks the write either way -- so read it back.
 *   3. encoder target = 1
 *   4. encoder ON           -> sync packet is the first thing the sink sees
 *   5. workload
 *   6. encoder OFF          the encoder re-enters sSync and emits a trailing sync packet,
 *                           which needs the core to keep retiring instructions: hence the
 *                           nop spin below.
 *   7. sink flush           the sink only writes DRAM in whole 8-byte beats; flush pushes
 *                           the partial tail out and makes addr_counter final.
 *   8. L2 flush             the sink is a master on the system bus, so its writes land in
 *                           the inclusive L2, not in DRAM. The PS reads DRAM. Without
 *                           this step the tail of the trace is missing.
 *
 * The addresses are transcribed from the DTS Chipyard emits next to the Verilog:
 *   trace-encoder-controller@3000000, trace-sink-dma@3010000, cache-controller@2010000,
 *   memory@80000000 (256 MB).
 */

#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include <zephyr/arch/cpu.h>

#include <tacit/tacit.h>

/*
 * Where the DMA sink parks the trace, in ROCKET's address space. The FPGA top folds
 * Rocket's DRAM window with {4'd1, addr[27:0]}, so Rocket 0x8000_0000 is PS physical
 * 0x1000_0000 and this buffer is PS physical 0x1800_0000.
 *
 * 128 MB into a 256 MB window: Zephyr's image plus heap and stacks live in the first few
 * hundred KB of 0x8000_0000, so nothing the core touches can alias the buffer.
 */
#ifndef TACIT_BUF_ADDR
#define TACIT_BUF_ADDR 0x88000000UL
#endif

/* Only used to bound the L2 flush and to sanity-check the byte count. */
#ifndef TACIT_BUF_SIZE
#define TACIT_BUF_SIZE (64UL * 1024 * 1024)
#endif

/* Iterations of the FOC kernel below. Same workload as samples/tacit, so the two traces
 * are of the same program -- though not the same instruction stream, because this core
 * has no FPU and the float math is emulated. */
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

/*
 * The accumulator is not decoration. samples/tacit writes its results into `volatile
 * float` locals that nothing ever reads; at -O2 (CONFIG_SPEED_OPTIMIZATIONS=y) gcc drops
 * the whole computation and the loop retires in 73 cycles, which traces as exactly two
 * sync packets. Summing the outputs and printing the sum keeps the soft-float trig alive.
 */
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
	uint32_t l2cfg = *(volatile uint32_t *)L2_CONFIG;
	uint32_t l2_block = 1u << ((l2cfg >> 24) & 0xff);
	uint64_t t0, t1, t2;
	uint64_t count;
	uint64_t addr_rb;
	float acc;

	printf("tacit_dma on %s\n", CONFIG_BOARD_TARGET);
	printf("l2: banks=%u ways=%u lgSets=%u block=%u\n", l2cfg & 0xff,
	       (l2cfg >> 8) & 0xff, (l2cfg >> 16) & 0xff, l2_block);

	/* 1. encoder off before anything else is touched. */
	l_trace_encoder_stop(enc);

	/* 2/3. point the sink at DRAM, point the encoder at the sink. */
	l_trace_sink_dma_configure_addr(sink, TACIT_BUF_ADDR, 0);
	l_trace_encoder_configure_target(enc, TARGET_DMA);
	l_trace_encoder_configure_branch_mode(enc, BRANCH_MODE_TARGET);

	addr_rb = sink->TR_SK_DMA_ADDR;
	printf("sink: addr=0x%08x%08x target=%u ctrl=0x%x\n",
	       (unsigned int)(addr_rb >> 32), (unsigned int)addr_rb,
	       (unsigned int)enc->TR_TE_TARGET, (unsigned int)enc->TR_TE_CTRL);
	if (addr_rb != (uint64_t)TACIT_BUF_ADDR) {
		printf("TACIT_FAIL sink address did not latch\n");
		goto done;
	}

	/* 4/5/6. trace the workload. */
	t0 = rdcycle();
	l_trace_encoder_start(enc);
	acc = workload();
	l_trace_encoder_stop(enc);
	t1 = rdcycle();

	/* The trailing sync packet needs retired instructions to push it through. */
	for (volatile int i = 0; i < 2000; i++) {
		__asm__ volatile("nop");
	}

	/* 7. push the sink's partial beat out and freeze addr_counter. */
	sink->TR_SK_DMA_FLUSH = 1;
	while (sink->TR_SK_DMA_FLUSH_DONE == 0) {
	}
	count = sink->TR_SK_DMA_COUNT;

	if (count > TACIT_BUF_SIZE) {
		printf("TACIT_FAIL count %u exceeds buffer\n", (unsigned int)count);
		goto done;
	}

	/* 8. the sink's writes are in the L2; the PS reads DRAM. */
	t2 = rdcycle();
	l2_flush_range((uintptr_t)TACIT_BUF_ADDR, count, l2_block);
	t2 = rdcycle() - t2;

	printf("workload_acc=%d trace_cycles=%u flush_cycles=%u\n",
	       (int)(acc * 1000.f), (unsigned int)(t1 - t0), (unsigned int)t2);
	printf("TACIT_DONE addr=0x%08x bytes=%u\n",
	       (unsigned int)TACIT_BUF_ADDR, (unsigned int)count);

done:
	printf("tacit_dma finished\n");
	return 0;
}
