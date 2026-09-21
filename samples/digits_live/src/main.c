/* SPDX-License-Identifier: Apache-2.0
 *
 * Offline connected-digit TRANSCRIPTION on the PYNQ-Z1 Rocket SoC: record four seconds
 * from the board's own microphone, then post-process into a digit string.
 *
 * WHY OFFLINE IS THE RIGHT SHAPE HERE, and it is not a concession.  Lab B18 found that
 * the constraint on a LIVE spotter is inference latency against the microphone's 64 ms
 * FIFO -- while the model runs, nothing drains it.  Record-then-process removes that
 * constraint by construction: the recording finishes before the model starts, so the
 * only question left is whether the wait is tolerable.  It is 292 ms for 4.01 s of
 * audio, which is not a wait at all.
 *
 * WHY THIS IS TRANSCRIPTION AND NOT CLASSIFICATION.  The output is a variable-length
 * string decoded with CTC, and the model can get its LENGTH wrong -- which is exactly
 * what a twelve-way classifier cannot do and why the score is a word error rate.
 *
 * WHY IT RUNS AT ALL, when section 6 says open-vocabulary transcription misses by two
 * orders of magnitude: the graph is four conv2d_s8 dispatches and nothing else. No
 * softmax, no LayerNorm, no attention -- and a greedy CTC decode needs no softmax
 * because argmax is invariant under it. Every one of the 28 float-tainted kernels that
 * made Lab B19's transformer blocks 84-98 % soft-float is simply absent from this graph.
 */

#include <zephyr/kernel.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/device.h>
#include <zephyr/sys/printk.h>
#include <string.h>

#include "audio_fe.h"
#include "pext.h"
#include "kws_featmap.h"
#include "model.h"
#include "test_io.h"

#ifndef DG_UTTERANCES
#define DG_UTTERANCES 4          /* how many 4 s windows to record and transcribe */
#endif

#define BLOCK_SAMPLES  512
#define BLOCK_BYTES    (BLOCK_SAMPLES * 2)
#define BLOCK_COUNT    4
#define READ_TIMEOUT   2000
#define CLIP_SAMPLES   64160     /* 4.01 s -> exactly KWS_NFRAMES frames */
#define BLANK          10

K_MEM_SLAB_DEFINE_STATIC(mem_slab, BLOCK_BYTES, BLOCK_COUNT, 4);

static int16_t pcm[CLIP_SAMPLES];
static struct fe_scratch scratch;
static int16_t logmel_q8[FE_NMEL];
static int16_t mfcc_q8[FE_NDCT];
static int8_t  feat[KWS_NFRAMES * KWS_NCOEF];
static int8_t  logits[MODEL_OUTPUT_SIZE];

_Static_assert(KWS_NFRAMES * KWS_NCOEF == MODEL_INPUT_SIZE, "feature/model shape mismatch");

static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/* The generated model emits [1, C, T, 1] in NCHW, so class c at frame t is at c*T + t. */
#define OUT_T   (MODEL_OUTPUT_SIZE / KWS_NCLASS)

/* Greedy CTC: argmax per frame, collapse runs, drop blanks.  No softmax -- argmax is
 * invariant under a monotone transform, and that is the whole reason this model needs
 * none of the kernels Lab B19 measured. */
static int ctc_decode(const int8_t *lg, int *out, int maxout)
{
	int n = 0, prev = -1, t;

	for (t = 0; t < OUT_T; t++) {
		int best = 0, c;

		for (c = 1; c < KWS_NCLASS; c++) {
			if (lg[c * OUT_T + t] > lg[best * OUT_T + t]) {
				best = c;
			}
		}
		if (best != prev && best != BLANK && n < maxout) {
			out[n++] = best;
		}
		prev = best;
	}
	return n;
}

int main(void)
{
	const struct device *mic = DEVICE_DT_GET(DT_NODELABEL(dmic_dev));
	struct pcm_stream_cfg stream = {
		.pcm_width = 16, .pcm_rate = 16000,
		.block_size = BLOCK_BYTES, .mem_slab = &mem_slab,
	};
	struct dmic_cfg cfg = {
		.io = { .min_pdm_clk_freq = 1000000, .max_pdm_clk_freq = 3300000 },
		.streams = &stream,
		.channel = { .req_num_streams = 1, .req_num_chan = 1 },
	};
	uint32_t rate;
	int u, ret;

	k_thread_cpu_pin(k_current_get(), 0);
	MB_PEXT_ASSERT_BIG_HART();
	printk("DIGITS start arch=%s macs=%d frames=%d ncoef=%d nclass=%d out_t=%d "
	       "mb_pext_hw=%d hart=%lu clock=%d\n",
	       KWS_ARCH, KWS_MACS, KWS_NFRAMES, KWS_NCOEF, KWS_NCLASS, OUT_T,
	       (int)MB_PEXT_HW, mb_pext_mhartid(), CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);

	if (audio_fe_selftest() != 0) {
		printk("DIGITS FAIL front-end self-test\n");
		return 0;
	}
	{
		int8_t chk[MODEL_TEST_OUTPUT_LEN];
		int i, err = 0;

		model_run_test(chk, NULL);
		for (i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
			int d = (int)chk[i] - (int)model_test_golden[i];

			err = (d < 0 ? -d : d) > err ? (d < 0 ? -d : d) : err;
		}
		printk("DIGITS_MODEL_CHECK outputs=%d max_abs_err=%d\n",
		       MODEL_TEST_OUTPUT_LEN, err);
		if (err) {
			printk("DIGITS FAIL the model in this image is not the verified one\n");
			return 0;
		}
	}

	if (!device_is_ready(mic)) {
		printk("DIGITS FAIL dmic not ready\n");
		return 0;
	}
	cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);
	if (dmic_configure(mic, &cfg) < 0) {
		printk("DIGITS FAIL dmic_configure\n");
		return 0;
	}
	rate = cfg.streams[0].pcm_rate;
	printk("DIGITS mic rate=%u clip=%d samples (%u ms)\n",
	       rate, CLIP_SAMPLES, (unsigned)((uint64_t)CLIP_SAMPLES * 1000u / rate));

	for (u = 0; u < DG_UTTERANCES; u++) {
		int have = 0, f, k, n, dig[32];
		uint64_t t_fe, t_md, t0;
		uint32_t lvl_peak = 0;
		uint64_t lvl_ss = 0;

		printk("DIGITS_SPEAK utterance=%d -- say some digits now\n", u);
		ret = dmic_trigger(mic, DMIC_TRIGGER_START);
		if (ret < 0) {
			printk("DIGITS FAIL trigger %d\n", ret);
			return 0;
		}
		/* RECORD. Nothing else runs, so the FIFO is drained every 32 ms and the
		 * 64 ms depth is never tested -- which is the whole point of doing this
		 * offline rather than live (Lab B18 section 4.4). */
		while (have < CLIP_SAMPLES) {
			void *buf;
			size_t size;
			int ns;

			if (dmic_read(mic, 0, &buf, &size, READ_TIMEOUT) < 0) {
				printk("DIGITS FAIL dmic_read\n");
				return 0;
			}
			ns = (int)(size / 2);
			if (ns > CLIP_SAMPLES - have) {
				ns = CLIP_SAMPLES - have;
			}
			memcpy(pcm + have, buf, (size_t)ns * 2);
			for (k = 0; k < ns; k++) {
				int32_t v = pcm[have + k];
				uint32_t av = (uint32_t)(v < 0 ? -v : v);

				lvl_ss += (uint64_t)((int64_t)v * v);
				if (av > lvl_peak) {
					lvl_peak = av;
				}
			}
			have += ns;
			k_mem_slab_free(&mem_slab, buf);
		}
		dmic_trigger(mic, DMIC_TRIGGER_STOP);

		/* POST-PROCESS. */
		t0 = rdcycle();
		for (f = 0; f < KWS_NFRAMES; f++) {
			fe_logmel_frame(pcm + (size_t)f * FE_HOP_LEN, &scratch, logmel_q8);
			fe_dct(logmel_q8, mfcc_q8);
			for (k = 0; k < KWS_NCOEF; k++) {
				int8_t v = fe_feat_to_int8(mfcc_q8[k], kws_feat_off[k],
							  kws_feat_shift[k]);
#if KWS_TRANSPOSED
				feat[k * KWS_NFRAMES + f] = v;
#else
				feat[f * KWS_NCOEF + k] = v;
#endif
			}
		}
		t_fe = rdcycle() - t0;
		t0 = rdcycle();
		run_model(feat, logits, NULL);
		t_md = rdcycle() - t0;
		n = ctc_decode(logits, dig, 32);

		printk("DIGITS_RESULT utterance=%d ndigits=%d text=", u, n);
		for (k = 0; k < n; k++) {
			printk("%s%d", k ? " " : "", dig[k]);
		}
		if (!n) {
			printk("(nothing)");
		}
		printk("\n");
		{
			uint64_t ms = lvl_ss / (uint64_t)CLIP_SAMPLES;
			uint32_t rms = 0;

			while ((uint64_t)(rms + 1) * (rms + 1) <= ms) {
				rms++;
			}
			printk("DIGITS_TIME utterance=%d frontend=%llu model=%llu total_ms=%llu "
			       "audio_ms=%u rtf_x1000=%llu rms=%u peak=%u\n",
			       u, (unsigned long long)t_fe, (unsigned long long)t_md,
			       (unsigned long long)((t_fe + t_md) * 1000u
						    / CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC
						    / 1000u),
			       (unsigned)((uint64_t)CLIP_SAMPLES * 1000u / rate),
			       (unsigned long long)((t_fe + t_md) * 1000u
						    / CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC
						    * rate / CLIP_SAMPLES),
			       rms, lvl_peak);
		}
	}
	printk("DIGITS done utterances=%d\n", DG_UTTERANCES);
	return 0;
}
