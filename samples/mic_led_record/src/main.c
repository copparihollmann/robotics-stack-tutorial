/*
 * Copyright (c) 2026 IISWC tutorial
 * SPDX-License-Identifier: Apache-2.0
 *
 * Record the board's own PDM microphone, with the RGB LEDs telling the person in the room
 * when to speak. Timing a recording from chat messages does not work; an LED across a desk
 * does.
 *
 * THE ONE QUESTION THE LEDS MUST ANSWER is "should I be talking right now?", and the
 * answer is carried by COLOUR and COUNT, not by brightness:
 *
 *   LD4 RED, steady ................ idle. Do not speak.
 *   LD4 AMBER, 3 blinks at 1 Hz .... get ready. Still do not speak.
 *   LD4 + LD5 both GREEN ........... SPEAK NOW. Recording. Two green LEDs, not one.
 *   LD5 green -> amber -> red ...... how much of the recording is left; red blinks fast
 *                                    for the last fifth.
 *   LD4 BLUE, steady ............... done. Stop speaking.
 *
 * LD4 stays GREEN for the whole recording, so "am I still being recorded?" never depends
 * on reading the countdown.
 *
 * WHY THE COUNTDOWN IS ON LD5 AND NOT ON LD0-LD3. The four plain LEDs are NOT software
 * LEDs on any of these bitstreams: fpga/pynq-z2/src/pynqz2_rocket_top.v ends with
 *
 *     assign leds = {err_burst_any, saw_mem, soc_resetn, hb[25]};
 *
 * so LD0 is a ~0.5 Hz PL heartbeat, LD1 is "the SoC is out of reset", LD2 is "the memory
 * port has seen traffic" and LD3 is a burst-error flag. They are hard-wired in the fabric,
 * outside the SoC's address map, and Zephyr cannot drive them without a new bitstream.
 * LD0's steady blinking during a recording is the PL heartbeat and means nothing about the
 * cue -- which is worth knowing, because it is the most eye-catching LED on the board.
 *
 * The capture path is samples/dmic_capture's, unchanged: Zephyr's DMIC API, PCM parked in
 * DRAM at Rocket 0x8C00_0000 (PS physical 0x1C00_0000), and an L2 flush before the host
 * reads it. The console stays quiet while recording -- no console traffic competes with
 * the read loop, and nothing distracts the person speaking.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/drivers/gpio.h>
#include <stdlib.h>
#include <string.h>

#define BYTES_PER_SAMPLE sizeof(int16_t)
#define READ_TIMEOUT_MS  2000
#define BLOCK_SAMPLES    512
#define BLOCK_BYTES      (BLOCK_SAMPLES * BYTES_PER_SAMPLE)
#define BLOCK_COUNT      4

#ifndef PCM_BUF_ADDR
#define PCM_BUF_ADDR 0x8C000000UL
#endif

#define L2_CTRL_BASE 0x2010000UL
#define L2_FLUSH64   (L2_CTRL_BASE + 0x200)
#define L2_BLOCK     64

K_MEM_SLAB_DEFINE_STATIC(mem_slab, BLOCK_BYTES, BLOCK_COUNT, 4);

/* ---- LEDs: six channels, two lamps -------------------------------------------------- */

#define LED_SPEC(n) GPIO_DT_SPEC_GET(DT_ALIAS(n), gpios)

static const struct gpio_dt_spec ld4_b = LED_SPEC(led0);
static const struct gpio_dt_spec ld4_g = LED_SPEC(led1);
static const struct gpio_dt_spec ld4_r = LED_SPEC(led2);
static const struct gpio_dt_spec ld5_b = LED_SPEC(led3);
static const struct gpio_dt_spec ld5_g = LED_SPEC(led4);
static const struct gpio_dt_spec ld5_r = LED_SPEC(led5);

static int leds_init(void)
{
	const struct gpio_dt_spec *all[] = {&ld4_b, &ld4_g, &ld4_r, &ld5_b, &ld5_g, &ld5_r};

	for (int i = 0; i < 6; i++) {
		if (!gpio_is_ready_dt(all[i])) {
			printk("MICLED: FAIL led %d not ready\n", i);
			return -ENODEV;
		}
		if (gpio_pin_configure_dt(all[i], GPIO_OUTPUT_INACTIVE) < 0) {
			printk("MICLED: FAIL led %d configure\n", i);
			return -EIO;
		}
	}
	return 0;
}

static void ld4(int r, int g, int b)
{
	gpio_pin_set_dt(&ld4_r, r);
	gpio_pin_set_dt(&ld4_g, g);
	gpio_pin_set_dt(&ld4_b, b);
}

static void ld5(int r, int g, int b)
{
	gpio_pin_set_dt(&ld5_r, r);
	gpio_pin_set_dt(&ld5_g, g);
	gpio_pin_set_dt(&ld5_b, b);
}

static void legend(void)
{
	printk("MICLED: legend -- the LEDs, not the console, say when to speak\n");
	printk("MICLED:   LD4 RED steady .............. idle, DO NOT SPEAK\n");
	printk("MICLED:   LD4 AMBER blinking x%d ....... get ready, still silent\n",
	       CONFIG_MIC_LED_READY_BLINKS);
	printk("MICLED:   LD4 + LD5 GREEN ............. SPEAK NOW, recording\n");
	printk("MICLED:   LD5 green>amber>red ........ time left; red blinks for the last fifth\n");
	printk("MICLED:   LD4 BLUE steady ............. done, stop speaking\n");
	printk("MICLED:   LD0-LD3 are PL status, NOT cues: heartbeat, reset, memory, error\n");
	printk("MICLED:   LD0 BLINKS ON ITS OWN THROUGHOUT -- that is the PL heartbeat, not a\n");
	printk("MICLED:   cue. It is the most eye-catching lamp on the board and it means\n");
	printk("MICLED:   nothing here. The cue is LD4 and LD5, the two RGB lamps, only.\n");
}

/* ---- L2 flush, as samples/dmic_capture --------------------------------------------- */

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

int main(void)
{
	const struct device *dmic_dev = DEVICE_DT_GET(DT_NODELABEL(dmic_dev));
	struct pcm_stream_cfg stream = {
		.pcm_width = 16,
		.mem_slab = &mem_slab,
		.pcm_rate = 16000,
		.block_size = BLOCK_BYTES,
	};
	struct dmic_cfg cfg = {
		.io = { .min_pdm_clk_freq = 1000000, .max_pdm_clk_freq = 3500000,
			.min_pdm_clk_dc = 40, .max_pdm_clk_dc = 60 },
		.streams = &stream,
		.channel = { .req_num_chan = 1, .req_num_streams = 1 },
	};
	uint32_t fs;
	int ret;

	printk("MICLED: start\n");
	legend();

	if (leds_init() < 0) {
		return 0;
	}
	if (!device_is_ready(dmic_dev)) {
		printk("MICLED: FAIL %s is not ready\n", dmic_dev->name);
		ld4(1, 0, 0);
		return 0;
	}

	cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);
	ret = dmic_configure(dmic_dev, &cfg);
	if (ret < 0) {
		printk("MICLED: FAIL dmic_configure %d\n", ret);
		return 0;
	}
	fs = cfg.streams[0].pcm_rate;

	/*
	 * 15,994 Hz, not 16,000: the decimator cannot make exactly 16 kHz from this SoC's
	 * 1000/29 MHz clock, and the driver reports what it actually got. The WAV header
	 * carries this number, not 16,000 -- 0.04 % slow, and deliberate.
	 */
	int blocks = (int)(((uint64_t)CONFIG_MIC_LED_SECONDS * fs) / BLOCK_SAMPLES);
	int max_blocks = CONFIG_MIC_LED_MAX_BYTES / BLOCK_BYTES;

	if (blocks > max_blocks) {
		blocks = max_blocks;
	}
	printk("MICLED: rate %u Hz  channels %u  block %u samples  blocks %d  seconds %d.%02d\n",
	       fs, cfg.channel.act_num_chan, (unsigned)BLOCK_SAMPLES, blocks,
	       (int)((uint64_t)blocks * BLOCK_SAMPLES / fs),
	       (int)(((uint64_t)blocks * BLOCK_SAMPLES * 100 / fs) % 100));

	/* ---- phase 1: idle, red ---- */
	ld4(1, 0, 0);
	ld5(0, 0, 0);
	printk("MICLED: phase idle t=%lld ms -- LD4 RED, do not speak\n", k_uptime_get());
	k_sleep(K_MSEC(CONFIG_MIC_LED_IDLE_MS));

	/* ---- phase 2: get ready, amber blinks ---- */
	printk("MICLED: phase ready t=%lld ms -- LD4 AMBER x%d, still silent\n",
	       k_uptime_get(), CONFIG_MIC_LED_READY_BLINKS);
	for (int i = 0; i < CONFIG_MIC_LED_READY_BLINKS; i++) {
		ld4(1, 1, 0);          /* red + green on one die reads as amber */
		k_sleep(K_MSEC(400));
		ld4(0, 0, 0);
		k_sleep(K_MSEC(600));
	}

	/* ---- phase 3: recording, both green, LD5 counts down ---- */
	ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
	if (ret < 0) {
		printk("MICLED: FAIL dmic_trigger START %d\n", ret);
		ld4(1, 0, 0);
		return 0;
	}
	ld4(0, 1, 0);
	ld5(0, 1, 0);
	printk("MICLED: phase record t=%lld ms -- LD4+LD5 GREEN, SPEAK NOW\n", k_uptime_get());

	int16_t *pcm = (int16_t *)PCM_BUF_ADDR;
	size_t pcm_n = 0;
	int64_t sum = 0;
	uint64_t sq = 0;
	int32_t peak = 0;
	int clipped = 0;

	for (int b = 0; b < blocks; b++) {
		void *buffer;
		size_t size;
		int16_t *x;
		int n;

		ret = dmic_read(dmic_dev, 0, &buffer, &size, READ_TIMEOUT_MS);
		if (ret < 0) {
			printk("MICLED: FAIL dmic_read block %d: %d\n", b, ret);
			ld4(1, 0, 0);
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
			if (x[i] >= 32700 || x[i] <= -32700) {
				clipped++;
			}
		}
		k_mem_slab_free(&mem_slab, buffer);

		/*
		 * The countdown, updated once per 32 ms block. Two thirds of the way
		 * through it goes amber, and for the last fifth red at about 4 Hz -- so
		 * "wrap up" is visible without counting anything.
		 */
		int left = blocks - b - 1;

		if (left * 2 > blocks) {
			ld5(0, 1, 0);
		} else if (left * 5 > blocks) {
			ld5(1, 1, 0);
		} else {
			ld5((b & 4) ? 1 : 0, 0, 0);
		}
	}

	ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
	if (ret < 0) {
		printk("MICLED: FAIL dmic_trigger STOP %d\n", ret);
	}

	/* ---- phase 4: done, blue ---- */
	ld4(0, 0, 1);
	ld5(0, 0, 0);
	printk("MICLED: phase done t=%lld ms -- LD4 BLUE, stop speaking\n", k_uptime_get());

	l2_flush_range(PCM_BUF_ADDR, pcm_n * BYTES_PER_SAMPLE);

	{
		int32_t dc = pcm_n ? (int32_t)(sum / (int64_t)pcm_n) : 0;
		int32_t rms = pcm_n ? isqrt64(sq / pcm_n) : 0;

		printk("MICLED: audio dc %d rms %d peak %d clipped %d\n", dc, rms, peak, clipped);
	}
	printk("MICLED: pcm_buf 0x%08lx samples %u bytes %u rate %u\n",
	       (unsigned long)PCM_BUF_ADDR, (unsigned)pcm_n,
	       (unsigned)(pcm_n * BYTES_PER_SAMPLE), fs);
	printk("MICLED: DONE\n");
	return 0;
}
