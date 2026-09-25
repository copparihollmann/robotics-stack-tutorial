/* SPDX-License-Identifier: Apache-2.0
 *
 * Live keyword spotting on the PYNQ-Z1 Rocket SoC: the board's own PDM microphone,
 * through a fixed-point MFCC front end, into an int8 CNN executed with the MBP
 * instructions -- continuously, from the console, with nothing on the host.
 *
 * THE NUMBER THIS EXISTS TO PRODUCE IS THE DUTY CYCLE, AND IT IS MEASURED.
 * An earlier note in this project put a keyword spotter at "under 3% duty cycle";
 * that was a projection from a MAC count and it is not what this prints.  What this
 * prints is `rdcycle` accumulated inside the front end and inside the model, divided
 * by `rdcycle` elapsed over the whole capture -- so it includes the DMIC driver, the
 * copies, the ring-buffer bookkeeping and the console, and it is a fraction of real
 * wall-clock time rather than a fraction of the work someone remembered to count.
 *
 * STRUCTURE.  One thread, pinned to hart 0 (the MBP encodings trap on hart 1):
 *
 *   dmic_read()  -> 512 samples (32.0 ms)
 *     -> while >= 480 unconsumed samples: one 30 ms MFCC frame, advance 320 (20 ms)
 *        -> push 10 int8 coefficients into a 49-frame ring
 *           -> every KWS_INFER_EVERY frames: run_model() over the ring, argmax
 *
 * WHY THE FEATURE RING IS int8 AND NOT Q8.  The Q8 -> int8 map is a subtract and a
 * shift per coefficient (kws_featmap.h, generated from the same meta.json the trainer
 * wrote), and doing it once at insert costs 490 fewer operations per inference than
 * doing it at every inference.  It also means the ring IS the model's input tensor,
 * so there is no copy -- except for the wrap, which is why there are two of them.
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

#ifndef KWS_SECONDS
#define KWS_SECONDS       20      /* how long to listen */
#endif

/*
 * KWS_STOP_HOOK -- ADDITIVE AND DEFAULT-OFF, like KWS_NO_MAIN.  Lab B156.
 *
 * KWS_SECONDS bounds this loop by BLOCKS CONSUMED, not by wall clock: on the little hart
 * the software P-extension model runs ~6.9x slower than the microphone, so 8 s of audio
 * took 55.0 s of wall time in Lab B153 and set the length of a two-hart trace whose other
 * lane had finished at 11.1 s.  Two workloads cannot be made to end together by choosing
 * two counts -- one wall-clock window ends both regardless of per-model speed.
 *
 * So the block loop asks an external predicate whether the window is still open.  Nothing
 * defines KWS_STOP_HOOK but samples/tacit_duo; everywhere else this is `!0` and every image
 * scripts/37 and scripts/38 build is unchanged.  The check is per BLOCK, so the loop leaves
 * after at most one block's work (one inference, ~1.4 s measured) -- the front end is never
 * cut mid-frame and KWS_DUTY still reports whole units.
 */
#ifdef KWS_STOP_HOOK
int kws_should_stop(void);
#else
static inline int kws_should_stop(void) { return 0; }
#endif
#ifndef KWS_PIN_CPU
/* Which hart this runs on. 0 -- the BIG hart -- is the default and the only value that
 * works with MB_PEXT_HW=1, because the MBP datapath exists on tile 0 only. Lab B151
 * builds this same source with KWS_PIN_CPU=1 and MB_PEXT_HW=0, which is pext.h's
 * software model on the LITTLE hart: the same arithmetic by construction, no custom-0
 * word anywhere in the image's hot path, and a legal instruction stream on tile 1.
 * CMakeLists.txt refuses the one combination that would trap. */
#define KWS_PIN_CPU       0
#endif
#ifndef KWS_INFER_EVERY
/* Frames between inferences. 10 x 20 ms = 200 ms, i.e. five inferences a second.
 *
 * NOT ten a second, which is the number a keyword spotter is usually quoted at. Lab B17
 * measures kws_cnn at 3,557,826 cycles; ten of those plus the front end is RTF 1.136,
 * so the pipeline would fall behind real time and the microphone's 64 ms FIFO would
 * absorb it for two blocks and then drop samples. Five a second is RTF 0.620 measured,
 * and the run reports its own realtime_ratio so a future model that does not fit says
 * so rather than quietly losing audio. */
#define KWS_INFER_EVERY   10
#endif

#define BLOCK_SAMPLES     512
#define BLOCK_BYTES       (BLOCK_SAMPLES * 2)
#define BLOCK_COUNT       4
#define READ_TIMEOUT_MS   2000

/* A detection is reported when the winning class is not silence/unknown and its margin
 * over the runner-up clears this. int8 logits, so the unit is one quantisation step of
 * the output tensor. Deliberately a MARGIN and not a threshold on the winner: the
 * output scale moves with the input level and a fixed threshold would track the room. */
#define KWS_MARGIN        12

K_MEM_SLAB_DEFINE_STATIC(mem_slab, BLOCK_BYTES, BLOCK_COUNT, 4);

static struct fe_scratch scratch;
static int16_t pcm_acc[FE_FRAME_LEN + BLOCK_SAMPLES];  /* unconsumed tail + one block */
static int     pcm_have;
static int16_t logmel_q8[FE_NMEL];
static int16_t mfcc_q8[FE_NDCT];
static int8_t  feat_ring[KWS_NFRAMES][KWS_NCOEF];
static int     ring_head;                              /* next slot to write */
static int     ring_fill;
static int8_t  model_in[KWS_NFRAMES * KWS_NCOEF];
static int8_t  model_out[MODEL_OUTPUT_SIZE];

/* kws_featmap.h comes from the TRAINER's meta.json and model.h from the CODEGEN. If they
 * ever disagree the image would feed a differently-shaped tensor and still run, producing
 * confident nonsense, so they are pinned together here rather than by convention. */
_Static_assert(KWS_NFRAMES * KWS_NCOEF == MODEL_INPUT_SIZE,
	       "the feature map and the generated model disagree about the input shape");
_Static_assert(KWS_NCLASS == MODEL_OUTPUT_SIZE,
	       "the feature map and the generated model disagree about the class count");
_Static_assert(KWS_NCOEF == FE_NDCT,
	       "the feature map wants a different number of MFCC coefficients than "
	       "audio_fe.h produces");

static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

static uint64_t cyc_fe, cyc_model, cyc_total;
static uint32_t n_frames, n_infer, n_blocks, n_detect;

/* Signal level, tracked per block and reported at the end.
 *
 * This is here because it is the one thing that could make the demo behave
 * differently from the 5,274-clip accuracy sweep for a reason that is nobody's bug.
 * Speech Commands clips are recorded close and loud; this microphone measures a
 * -60.9 dBFS noise floor and -47.9 dBFS peak in a quiet room (MICROPHONE.md 8), so a
 * talker at arm's length may sit 20 dB below what the model was trained on. MFCC
 * coefficients c1..c9 are DIFFERENCES of log-mels and are level-invariant, so most of
 * the feature vector does not care -- but c0 is the total energy and does. Printing the
 * level means the question can be answered from the log instead of guessed at. */
static uint64_t lvl_sumsq;
static uint32_t lvl_n, lvl_peak;

/* The ring in chronological order, oldest first -- which is the axis the model's first
 * convolution strides along, so the order is not cosmetic. */
static void ring_to_input(void)
{
	int first = KWS_NFRAMES - ring_head;

	memcpy(model_in, feat_ring[ring_head], (size_t)first * KWS_NCOEF);
	if (ring_head) {
		memcpy(model_in + (size_t)first * KWS_NCOEF, feat_ring[0],
		       (size_t)ring_head * KWS_NCOEF);
	}
}

static void push_frame(const int16_t *pcm)
{
	uint64_t t0 = rdcycle();
	int k;

	fe_logmel_frame(pcm, &scratch, logmel_q8);
	fe_dct(logmel_q8, mfcc_q8);
	for (k = 0; k < KWS_NCOEF; k++) {
		feat_ring[ring_head][k] =
			fe_feat_to_int8(mfcc_q8[k], kws_feat_off[k], kws_feat_shift[k]);
	}
	ring_head = (ring_head + 1) % KWS_NFRAMES;
	if (ring_fill < KWS_NFRAMES) {
		ring_fill++;
	}
	cyc_fe += rdcycle() - t0;
	n_frames++;
}

static int infer(int *margin)
{
	uint64_t t0;
	int best = 0, second = 0, i;

	ring_to_input();
	t0 = rdcycle();
	run_model(model_in, model_out, NULL);
	cyc_model += rdcycle() - t0;
	n_infer++;
	for (i = 1; i < MODEL_OUTPUT_SIZE; i++) {
		if (model_out[i] > model_out[best]) {
			best = i;
		}
	}
	second = (best == 0) ? 1 : 0;
	for (i = 0; i < MODEL_OUTPUT_SIZE; i++) {
		if (i != best && model_out[i] > model_out[second]) {
			second = i;
		}
	}
	*margin = (int)model_out[best] - (int)model_out[second];
	return best;
}

/*
 * THE PIN, AND WHY IT HAS TO BE A NEW THREAD TO REACH HART 1.
 *
 * This function used to be main() and its first statement was
 * `k_thread_cpu_pin(k_current_get(), 0)`. That call is a no-op dressed as a guarantee:
 * k_thread_cpu_pin() only binds a thread that HAS NOT STARTED, so calling it on the
 * running main thread changes nothing. It looked correct for four labs because main
 * already runs on CPU 0 and 0 was the only value ever asked for.
 *
 * Lab B151 asked for 1 and got `KWS_PIN want_cpu=1 hart=0 ok=0` on silicon -- the
 * software-model build ran on the BIG hart and would have reported the little hart's
 * duty cycle as the big one's. The fix is the pattern samples/tacit_pext_smp and
 * samples/signdet_live already use: create K_FOREVER, pin, then start.
 *
 * KWS_PIN_CPU=0 still runs the body on the main thread exactly as before, so every
 * image scripts/38 has ever produced is unchanged. Only the non-default value pays for
 * a second stack.
 */
#ifdef KWS_NO_MAIN
/* Lab B151 links this file into samples/tacit_duo; that sample's main() owns the
 * thread, the pin and the join. Visible there, static everywhere else. */
int kws_body(void);
#define KWS_BODY_LINKAGE
#else
#define KWS_BODY_LINKAGE static
#endif
KWS_BODY_LINKAGE int kws_body(void)
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
	uint64_t t_start, t_end;
	uint32_t rate;
	int ret, blocks_wanted, since_infer = 0;

	MB_PEXT_ASSERT_BIG_HART();

	printk("KWS_LIVE start arch=%s macs=%d nframes=%d ncoef=%d nclass=%d "
	       "infer_every=%d mb_pext_hw=%d hart=%lu clock=%d\n",
	       KWS_ARCH, KWS_MACS, KWS_NFRAMES, KWS_NCOEF, KWS_NCLASS,
	       KWS_INFER_EVERY, (int)MB_PEXT_HW, mb_pext_mhartid(),
	       CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);

	/* The pin is a request; this is the answer. An image with MB_PEXT_HW=1 that landed
	 * on the wrong hart halts on the first DOT8 and says so, but one with
	 * MB_PEXT_HW=0 would run perfectly well on the WRONG core and report a duty cycle
	 * for the other one -- which is the failure Lab B151 exists to not make. */
	printk("KWS_PIN want_cpu=%d hart=%lu ok=%d\n", KWS_PIN_CPU,
	       mb_pext_mhartid(), (int)(mb_pext_mhartid() == (unsigned long)KWS_PIN_CPU));

	/* The front end is checked on this silicon before a single word is spotted. A
	 * fast wrong front end feeds a model that was trained on a different one. */
	if (audio_fe_selftest() != 0) {
		printk("KWS_LIVE FAIL front-end self-test\n");
		return 0;
	}

	/* And so is the model. ModelBlaster bakes one input and the int8 output the SCALAR
	 * codegen produced from the same IR; running it here proves the network inside THIS
	 * image is bit-for-bit the one Lab B17 measured, on this silicon, in this session.
	 * Without it, "the demo ran" would be compatible with a stale MODEL_DIR, a curated
	 * kernel that silently fell back, or a weights.c from a different training run --
	 * none of which would look wrong on a console watching a quiet room. */
	{
		int8_t chk[MODEL_TEST_OUTPUT_LEN];
		int i, err = 0;

		model_run_test(chk, NULL);
		for (i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
			int d = (int)chk[i] - (int)model_test_golden[i];

			if (d < 0) {
				d = -d;
			}
			if (d > err) {
				err = d;
			}
		}
		printk("KWS_MODEL_CHECK outputs=%d max_abs_err=%d\n",
		       MODEL_TEST_OUTPUT_LEN, err);

		/* THE WHOLE OUTPUT VECTOR, not just its distance from the golden.
		 *
		 * max_abs_err=0 says this image agrees with the codegen's own golden.
		 * It does not let two DIFFERENT images be compared against each other,
		 * and that is exactly what Lab B151 needs: the MBP build on hart 0 and
		 * the software-model build on hart 1 run the same network over the same
		 * baked input, and the claim is that the twelve int8 logits come out
		 * IDENTICAL -- not merely that both round to the same class. Printing
		 * the vector makes that a diff rather than an assertion, and a diff can
		 * fail. */
		printk("KWS_GOLDEN_LOGITS n=%d mb_pext_hw=%d v=",
		       MODEL_TEST_OUTPUT_LEN, (int)MB_PEXT_HW);
		for (i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
			printk("%d%s", (int)chk[i],
			       i + 1 == MODEL_TEST_OUTPUT_LEN ? "" : ",");
		}
		{
			int b = 0;

			for (i = 1; i < MODEL_TEST_OUTPUT_LEN; i++) {
				if (chk[i] > chk[b]) {
					b = i;
				}
			}
			printk(" argmax=%d\n", b);
		}
		if (err != 0) {
			printk("KWS_LIVE FAIL the model in this image is not the one that was "
			       "verified -- see SPEECH_ON_ROCKET.md section 4.2\n");
			return 0;
		}
	}

	if (!device_is_ready(mic)) {
		printk("KWS_LIVE FAIL dmic not ready\n");
		return 0;
	}
	cfg.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);
	ret = dmic_configure(mic, &cfg);
	if (ret < 0) {
		printk("KWS_LIVE FAIL dmic_configure %d\n", ret);
		return 0;
	}
	rate = cfg.streams[0].pcm_rate;     /* the driver writes back what it really got */
	printk("KWS_LIVE mic rate=%u block=%d samples frame=%d hop=%d\n",
	       rate, BLOCK_SAMPLES, FE_FRAME_LEN, FE_HOP_LEN);

	ret = dmic_trigger(mic, DMIC_TRIGGER_START);
	if (ret < 0) {
		printk("KWS_LIVE FAIL dmic_trigger %d\n", ret);
		return 0;
	}

	blocks_wanted = (int)(((uint64_t)KWS_SECONDS * rate) / BLOCK_SAMPLES);
	t_start = rdcycle();
	while ((int)n_blocks < blocks_wanted && !kws_should_stop()) {
		void *buf;
		size_t size;

		ret = dmic_read(mic, 0, &buf, &size, READ_TIMEOUT_MS);
		if (ret < 0) {
			printk("KWS_LIVE FAIL dmic_read %d after %u blocks\n", ret, n_blocks);
			break;
		}
		n_blocks++;
		/* Append, then consume whole frames. The tail that is shorter than a frame
		 * stays for the next block -- that is what makes the 20 ms hop continuous
		 * across a 32.01 ms block boundary rather than restarting at it. */
		memcpy(pcm_acc + pcm_have, buf, size);
		{
			const int16_t *s = (const int16_t *)buf;
			int i, ns = (int)(size / 2);

			for (i = 0; i < ns; i++) {
				int32_t v = s[i];
				uint32_t a = (uint32_t)(v < 0 ? -v : v);

				lvl_sumsq += (uint64_t)((int64_t)v * v);
				if (a > lvl_peak) {
					lvl_peak = a;
				}
			}
			lvl_n += (uint32_t)ns;
		}
		pcm_have += (int)(size / 2);
		k_mem_slab_free(&mem_slab, buf);

		/* The first ~50 ms after START is the CIC/FIR settling transient
		 * (MICROPHONE.md section 10.2) -- real, well-formed, and not audio.
		 * Two blocks is 64 ms. */
		if (n_blocks <= 2) {
			pcm_have = 0;
			continue;
		}

		while (pcm_have >= FE_FRAME_LEN) {
			push_frame(pcm_acc);
			memmove(pcm_acc, pcm_acc + FE_HOP_LEN,
				(size_t)(pcm_have - FE_HOP_LEN) * 2);
			pcm_have -= FE_HOP_LEN;
			if (ring_fill < KWS_NFRAMES) {
				continue;
			}
			if (++since_infer >= KWS_INFER_EVERY) {
				int margin, cls = infer(&margin);

				since_infer = 0;
				if (cls > 1 && margin >= KWS_MARGIN) {
					n_detect++;
					printk("KWS_HIT t=%ums label=%s margin=%d logit=%d\n",
					       (unsigned)((uint64_t)n_frames * FE_HOP_LEN
							  * 1000u / rate),
					       kws_labels[cls], margin, model_out[cls]);
				}
			}
		}
	}
	t_end = rdcycle();
	dmic_trigger(mic, DMIC_TRIGGER_STOP);
	cyc_total = t_end - t_start;

	/* Per mille rather than per cent, and integer, because this core has no FPU and
	 * printk has no %f. */
	printk("KWS_DUTY blocks=%u frames=%u inferences=%u detections=%u\n",
	       n_blocks, n_frames, n_infer, n_detect);
	printk("KWS_CYCLES total=%llu frontend=%llu model=%llu\n",
	       (unsigned long long)cyc_total, (unsigned long long)cyc_fe,
	       (unsigned long long)cyc_model);
	printk("KWS_PERMILLE frontend=%llu model=%llu busy=%llu\n",
	       (unsigned long long)(cyc_fe * 1000u / cyc_total),
	       (unsigned long long)(cyc_model * 1000u / cyc_total),
	       (unsigned long long)((cyc_fe + cyc_model) * 1000u / cyc_total));
	printk("KWS_PER_UNIT frame_cycles=%llu infer_cycles=%llu\n",
	       (unsigned long long)(n_frames ? cyc_fe / n_frames : 0),
	       (unsigned long long)(n_infer ? cyc_model / n_infer : 0));
	printk("KWS_AUDIO seconds_x1000=%llu\n",
	       (unsigned long long)((uint64_t)n_blocks * BLOCK_SAMPLES * 1000u / rate));
	{
		/* Integer rms, and dBFS to one decimal without a single float:
		 * 20*log10(rms/32768) = 6.0206 * log2(rms/32768), and fe_log2_q8 is
		 * already here and already checked. */
		uint64_t ms = lvl_n ? lvl_sumsq / lvl_n : 0;
		uint32_t rms = 0;

		while ((uint64_t)(rms + 1) * (rms + 1) <= ms) {
			rms++;
		}
		/* dBFS x 10 = 10 * 20*log10(r/32768) = 60.206 * log2(r/32768), and
		 * fe_log2_q8 returns 256*log2, so the constant is 60206/256/1000.
		 * The intermediate is at most 2588*60206 = 1.6e8 and fits int32. */
		printk("KWS_LEVEL rms=%u peak=%u samples=%u rms_dbfs_x10=%d peak_dbfs_x10=%d\n",
		       rms, lvl_peak, lvl_n,
		       rms ? (int)(((int32_t)fe_log2_q8(rms) - (15 << 8)) * 60206 / 256 / 1000)
			   : -9990,
		       lvl_peak ? (int)(((int32_t)fe_log2_q8(lvl_peak) - (15 << 8)) * 60206
					/ 256 / 1000) : -9990);
	}
	printk("KWS_LIVE done\n");
	return 0;
}

#if defined(KWS_NO_MAIN)

/* samples/tacit_duo creates, pins and starts this body itself -- see the note on
 * SD_NO_MAIN in samples/signdet_live/src/main.c. Strictly additive: nothing else
 * defines KWS_NO_MAIN, so scripts/38's image is unchanged. */

#elif KWS_PIN_CPU == 0

int main(void)
{
	/* The historical image: the body on the main thread, on the hart it booted on.
	 * k_thread_cpu_pin() was never doing anything here and is not pretended at. */
	return kws_body();
}

#else

K_THREAD_STACK_DEFINE(kws_stack, CONFIG_MAIN_STACK_SIZE);
static struct k_thread kws_thread;

static void kws_entry(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);
	(void)kws_body();
}

int main(void)
{
	k_tid_t tid = k_thread_create(&kws_thread, kws_stack,
				      K_THREAD_STACK_SIZEOF(kws_stack), kws_entry,
				      NULL, NULL, NULL, 5, 0, K_FOREVER);
	int rc = k_thread_cpu_pin(tid, KWS_PIN_CPU);

	k_thread_name_set(tid, "kws_live");
	printk("KWS_PIN_RC rc=%d want_cpu=%d\n", rc, KWS_PIN_CPU);
	if (rc != 0) {
		/* Refuse rather than measure the wrong core. With MB_PEXT_HW=0 the body
		 * would run happily on hart 0 and every cycle count in this run would be
		 * the big core's. */
		printk("KWS_LIVE FAIL could not pin to CPU %d (rc=%d) -- refusing to "
		       "report another hart's duty cycle as this one's\n",
		       KWS_PIN_CPU, rc);
		return 0;
	}
	k_thread_start(tid);
	k_thread_join(tid, K_FOREVER);
	return 0;
}

#endif /* KWS_PIN_CPU */
