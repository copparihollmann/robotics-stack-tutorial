/*
 * Copyright (c) 2026 IISWC tutorial
 * SPDX-License-Identifier: Apache-2.0
 *
 * Capture from the PYNQ-Z1's on-board PDM microphone through Zephyr's DMIC API, and
 * print enough about what came back that a reader can tell real audio from a stuck pin
 * without leaving the serial console.
 *
 * What it prints, and why each line is the one to look at:
 *
 *   rate            what dmic_configure() NEGOTIATED. It will say 15993, not 16000 --
 *                   the decimator cannot make exactly 16 kHz from a 1000/29 MHz clock.
 *   dc, rms, peak   a dead pin gives dc = 0 or +-32767 and rms = 0. A live microphone in
 *                   a quiet room gives |dc| < a few counts (the hardware DC blocker) and
 *                   an rms of tens of counts.
 *   zero crossings  a DC level has none; noise has thousands per block.
 *   8-band spectrum a Goertzel at eight frequencies. Ambient machine noise is loudest in
 *                   the low bands and falls away above a few kHz; a stuck or aliasing
 *                   input is flat or rises. This is the line that says the decimation
 *                   chain is doing its job.
 *
 * Whistle at the board while it runs and the 2 kHz or 4 kHz band jumps 20-30 dB.
 *
 * It ALSO parks the captured PCM in DRAM so the host can look at it properly. The console
 * is 115200 baud; 16 kHz of 16-bit audio is not going down it. Rocket 0x8C00_0000 is PS
 * physical 0x1C00_0000 through the FPGA top's {4'd1, addr[27:0]} fold, well clear of the
 * image at the bottom of RAM and of samples/tacit_dma's buffer at 0x8800_0000.
 *
 * THE L2 FLUSH AT THE END IS NOT OPTIONAL. These are ordinary stores, so they sit in
 * Rocket's L1 and the inclusive L2; the PS reads DRAM. Without the flush the host sees
 * whatever was in DRAM before. Same mechanism, and the same register, as
 * samples/tacit_dma uses for the trace buffer.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/audio/dmic.h>
#include <stdlib.h>
#include <string.h>

#define SAMPLE_BIT_WIDTH 16
#define BYTES_PER_SAMPLE sizeof(int16_t)
#define READ_TIMEOUT_MS  2000

/* 32 ms a block: half the hardware FIFO, so a late reader is still covered. */
#define BLOCK_SAMPLES 512
#define BLOCK_BYTES   (BLOCK_SAMPLES * BYTES_PER_SAMPLE)
#define BLOCK_COUNT   4
/* 2.0 s of audio: long enough for a 2048-point Welch average on the host and for a
 * whistle to land inside the window. */
#define NBLOCKS       62

/* Where the PCM is parked, in ROCKET's address space. */
#ifndef PCM_BUF_ADDR
#define PCM_BUF_ADDR 0x8C000000UL
#endif

/* SiFive InclusiveCache control node: cache-controller@2010000, reg-names "control". */
#define L2_CTRL_BASE 0x2010000UL
#define L2_FLUSH64   (L2_CTRL_BASE + 0x200) /* write a phys addr -> flush that block */
#define L2_BLOCK     64

/*
 * Flush a physical range out of the L2 (and, because it is inclusive, out of L1 too).
 * Flush64's TileLink write does not complete until the scheduler has finished with the
 * block, so the store itself is the handshake -- there is nothing to poll.
 */
static void l2_flush_range(uintptr_t base, size_t bytes)
{
	volatile uint64_t *flush = (volatile uint64_t *)L2_FLUSH64;
	uintptr_t a = base & ~(uintptr_t)(L2_BLOCK - 1);
	uintptr_t end = base + bytes;

	__asm__ volatile("fence" ::: "memory");
	for (; a < end; a += L2_BLOCK) {
		*flush = (uint64_t)a;
	}
	__asm__ volatile("fence" ::: "memory");
}

K_MEM_SLAB_DEFINE_STATIC(mem_slab, BLOCK_BYTES, BLOCK_COUNT, 4);

/* Eight Goertzel probes. Integer arithmetic throughout -- this SoC has no FPU
 * (riscv,isa has no f), so a float here would pull in the whole soft-float library and
 * blow the loop budget for no benefit.
 */
#define NBANDS 8
static const uint32_t band_hz[NBANDS] = { 125, 250, 500, 1000, 2000, 3000, 5000, 7000 };

/* Q14 cosine table, filled once the real sample rate is known. */
static int32_t band_coeff[NBANDS];

static int32_t isqrt64(uint64_t v)
{
	uint64_t x = v, y = (v + 1) / 2;

	if (v == 0) {
		return 0;
	}
	while (y < x) {
		x = y;
		y = (x + v / x) / 2;
	}
	return (int32_t)x;
}

/* 20*log10(x) in HUNDREDTHS of a dB, integer only, for x expressed as a ratio n/d.
 * 60206 is 6.0206 dB in units of 1e-4 dB, one per octave; the final /100 lands on
 * hundredths. The caller divides again to print whole dB. */
static int32_t db10(uint64_t n, uint64_t d)
{
	int32_t e = 0;

	if (n == 0 || d == 0) {
		return -9999;
	}
	/* Bring n/d into [1,2) by powers of two, counting 6.0206 dB each. */
	while (n >= 2 * d) { d *= 2; e += 60206; }
	while (n < d)      { n *= 2; e -= 60206; }
	/* log2(1+f) ~ f*(1.0 - 0.33*f) over [0,1), good to ~0.1 dB here. */
	{
		int64_t f = (int64_t)((n - d) * 1024 / d);            /* Q10 in [0,1024) */
		int64_t l2 = (f * (1024 - (f * 338) / 1024)) / 1024;  /* Q10 */
		e += (int32_t)((l2 * 60206) / 1024);
	}
	return e / 100;   /* hundredths of a dB */
}

static void goertzel_setup(uint32_t fs)
{
	/* cos(2*pi*f/fs) in Q14, from a 4th-order Taylor series about 0 -- f/fs is at
	 * most 7000/15994 = 0.44, so the series is evaluated at up to 2.75 rad and needs
	 * the argument folded into [-pi/2, pi/2] first.
	 */
	for (int i = 0; i < NBANDS; i++) {
		/* theta in Q16 radians */
		int64_t th = ((int64_t)band_hz[i] * 411775) / fs;   /* 2*pi*65536 = 411775 */
		int64_t half_pi = 102944;                            /* pi/2 in Q16 */
		int32_t sign = 1;

		if (th > half_pi) {            /* cos(x) = -cos(pi - x) */
			th = 2 * half_pi - th;
			sign = -1;
		}
		{
			int64_t x2 = (th * th) >> 16;                       /* Q16 */
			int64_t x4 = (x2 * x2) >> 16;
			int64_t c = 65536 - x2 / 2 + x4 / 24;               /* Q16 */
			band_coeff[i] = (int32_t)((sign * c) >> 2);         /* Q14 */
		}
	}
}

/* One Goertzel pass, returning the magnitude scaled by n/2 (i.e. amplitude*n/2). */
static uint64_t goertzel(const int16_t *x, int n, int32_t coeff_q14)
{
	int64_t s0 = 0, s1 = 0, s2 = 0;

	for (int i = 0; i < n; i++) {
		s0 = (int64_t)x[i] + ((2 * coeff_q14 * s1) >> 14) - s2;
		s2 = s1;
		s1 = s0;
	}
	{
		int64_t re = s1 - ((coeff_q14 * s2) >> 14);
		int64_t im = s2;   /* times sin(theta); dropped, so this is a 1-2 dB estimate */
		return isqrt64((uint64_t)(re * re + im * im));
	}
}

int main(void)
{
	const struct device *const dmic_dev = DEVICE_DT_GET(DT_NODELABEL(dmic_dev));
	struct pcm_stream_cfg stream = {
		.pcm_width = SAMPLE_BIT_WIDTH,
		.pcm_rate  = 16000,
		.block_size = BLOCK_BYTES,
		.mem_slab  = &mem_slab,
	};
	struct dmic_cfg cfg = {
		.io = {
			.min_pdm_clk_freq = 1000000,
			.max_pdm_clk_freq = 3300000,   /* the reference manual's range */
			.min_pdm_clk_dc   = 40,
			.max_pdm_clk_dc   = 60,
		},
		.streams = &stream,
		.channel = { .req_num_streams = 1, .req_num_chan = 1 },
	};
	int ret;
	uint32_t fs;

	printk("MIC: dmic_capture start\n");

	if (!device_is_ready(dmic_dev)) {
		printk("MIC: FAIL %s is not ready\n", dmic_dev->name);
		return 0;
	}

	cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);

	ret = dmic_configure(dmic_dev, &cfg);
	if (ret < 0) {
		printk("MIC: FAIL dmic_configure %d\n", ret);
		return 0;
	}
	fs = cfg.streams[0].pcm_rate;
	printk("MIC: rate %u Hz  channels %u  block %u samples\n",
	       fs, cfg.channel.act_num_chan, (unsigned)(BLOCK_BYTES / BYTES_PER_SAMPLE));
	goertzel_setup(fs);

	ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
	if (ret < 0) {
		printk("MIC: FAIL dmic_trigger START %d\n", ret);
		return 0;
	}

	int16_t *pcm = (int16_t *)PCM_BUF_ADDR;
	size_t pcm_n = 0;

	for (int b = 0; b < NBLOCKS; b++) {
		void *buffer;
		size_t size;
		int16_t *x;
		int n;
		int64_t sum = 0;
		uint64_t sq = 0;
		int32_t peak = 0;
		int zc = 0;

		ret = dmic_read(dmic_dev, 0, &buffer, &size, READ_TIMEOUT_MS);
		if (ret < 0) {
			printk("MIC: FAIL dmic_read block %d: %d\n", b, ret);
			return 0;
		}
		x = buffer;
		n = size / BYTES_PER_SAMPLE;
		memcpy(&pcm[pcm_n], x, size);
		pcm_n += n;

		for (int i = 0; i < n; i++) {
			sum += x[i];
			sq += (uint64_t)((int32_t)x[i] * (int32_t)x[i]);
			if (abs(x[i]) > peak) {
				peak = abs(x[i]);
			}
			if (i && ((x[i] < 0) != (x[i - 1] < 0))) {
				zc++;
			}
		}

		/* Print every 8th block to keep the console readable at 115200. */
		if ((b % 8) == 0) {
			int32_t dc = (int32_t)(sum / n);
			int32_t rms = isqrt64(sq / n);

			printk("MIC: blk %2d dc %5d rms %5d peak %5d zc %4d | ",
			       b, dc, rms, peak, zc);
			for (int k = 0; k < NBANDS; k++) {
				uint64_t m = goertzel(x, n, band_coeff[k]);
				/* amplitude = 2*m/n, expressed in whole dBFS. A single
				 * Goertzel bin, so it sits below the band integrals the
				 * host prints -- it is here to move when you whistle,
				 * not to be compared with them.
				 */
				printk("%u:%d ", band_hz[k],
				       (int)(db10(2 * m, (uint64_t)n * 32768) / 100));
			}
			printk("\n");
		}

		k_mem_slab_free(&mem_slab, buffer);
	}

	ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
	if (ret < 0) {
		printk("MIC: FAIL dmic_trigger STOP %d\n", ret);
		return 0;
	}

	l2_flush_range(PCM_BUF_ADDR, pcm_n * BYTES_PER_SAMPLE);

	printk("MIC: captured %d blocks of %d samples at %u Hz\n",
	       NBLOCKS, BLOCK_SAMPLES, fs);
	printk("MIC: pcm_buf 0x%08lx samples %u bytes %u rate %u\n",
	       (unsigned long)PCM_BUF_ADDR, (unsigned)pcm_n,
	       (unsigned)(pcm_n * BYTES_PER_SAMPLE), fs);
	printk("MIC: DONE\n");
	return 0;
}
