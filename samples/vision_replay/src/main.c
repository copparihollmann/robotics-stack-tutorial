/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * The whole camera path on one hart: a 324x324 frame sitting in DRAM, the front end,
 * the network, an answer -- timed stage by stage.
 *
 * WHY THE FRAMES ARE REPLAYED FROM DRAM RATHER THAN CAPTURED.  A measurement wants the
 * same input every time, and a sensor pointed at a room does not give one.  The frames
 * here are held-out Visual Wake Words images synthesised to 324x324 and baked into
 * .rodata by fpga/pynq-z2/sw/tools/gen_replay_frames.py, so they sit in DDR exactly
 * where the capture DMA would leave them and every stage downstream of the pixel is the
 * real one.  Lab B17 fed the speech models stored features for the same reason, and that
 * is what makes its cycle counts reproduce to 0.00 % of the median.
 *
 * FOUR THINGS ARE MEASURED AND ONE IS CHECKED.
 *
 *   1. All THREE front ends on every frame -- monochrome, demosaiced colour, and raw
 *      Bayer -- from the two sensor frames the image carries.  The sensor sends 104,976
 *      bytes either way; the difference between these three numbers is what colour
 *      actually costs on this core, and it is the answer to a question that is otherwise
 *      argued rather than measured.
 *
 *   2. The model, on the feature this build's architecture takes.
 *
 *   3. End to end: front end + model, per frame, as frames per second.
 *
 *   4. CHECKED: the device's feature against the one the HOST build of the same
 *      frame_fe.c produced, element by element.  max_abs_err must be 0.  This is the
 *      model's baked-golden gate applied one stage earlier, and it is what would catch a
 *      front end that is subtly different on the target -- a shift that is arithmetic on
 *      one side and logical on the other, an integer promotion, a different rounding.
 *      A wrong front end produces a plausible classification and a believable cycle
 *      count, which is exactly the failure this repo has been bitten by before.
 *
 * Pinned to CPU 0, which is the hart with MBP.  Interrupts are locked around every timed
 * window.  Everything printed is integer; no float appears in this image.
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>

#include "pext.h"
#include "frame_fe.h"
#include "replay_frames.h"
#include "model.h"
#include "test_io.h"

#define WORKER_STACK   16384
#define BIG_CPU        0

K_THREAD_STACK_DEFINE(big_stack, WORKER_STACK);
static struct k_thread big_thread;
static K_SEM_DEFINE(done_sem, 0, 1);

/* Front-end outputs.  Static, not stack: 3 x 96 x 96 is 27 KB and the thread stack is
 * not the place for it. */
static int8_t fe_mono[FE_MONO_ELEMS];
static int8_t fe_rgb[FE_RGB_ELEMS];
static int8_t fe_bay[FE_BAYER_ELEMS];
static model_output_t out_buf[MODEL_OUTPUT_SIZE];

static struct {
	unsigned long fe_mono_cyc[VR_NFRAMES];
	unsigned long fe_rgb_cyc[VR_NFRAMES];
	unsigned long fe_bay_cyc[VR_NFRAMES];
	unsigned long model_cyc[VR_NFRAMES];
	int           feat_err[VR_NFRAMES];
	int           pred[VR_NFRAMES];
	int           golden_err;
	int           selftest;
	int           correct;
	unsigned int  cpu_id, hartid;
	bool          ran;
} R;

static inline unsigned long rdcycle(void)
{
	unsigned long c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

static unsigned long median_ul(const unsigned long *a, int n)
{
	unsigned long t[VR_NFRAMES];
	int i, j;

	for (i = 0; i < n; i++) {
		t[i] = a[i];
	}
	for (i = 1; i < n; i++) {
		unsigned long v = t[i];

		j = i - 1;
		while (j >= 0 && t[j] > v) {
			t[j + 1] = t[j];
			j--;
		}
		t[j + 1] = v;
	}
	return t[n / 2];
}

static const int8_t *feat_for_build(void)
{
#if VR_FEED == 0
	return fe_mono;
#elif VR_FEED == 1
	return fe_rgb;
#else
	return fe_bay;
#endif
}

static void worker(void *p1, void *p2, void *p3)
{
	int f, i;

	ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
	R.cpu_id = arch_curr_cpu()->id;
	R.hartid = csr_read(mhartid);
	R.ran = true;
	MB_PEXT_ASSERT_BIG_HART();

	R.selftest = frame_fe_selftest();

	/* The model against its own baked int8 golden, before any frame is touched.
	 * Without this, "the demo classified something" is compatible with a stale
	 * MODEL_DIR or a curated kernel that silently fell back. */
	model_run_test(out_buf, NULL);
	R.golden_err = 0;
	for (i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
		int d = (int)out_buf[i] - (int)model_test_golden[i];

		if (d < 0) {
			d = -d;
		}
		if (d > R.golden_err) {
			R.golden_err = d;
		}
	}

	R.correct = 0;
	for (f = 0; f < VR_NFRAMES; f++) {
		const uint8_t *mono = vr_mono_frame + (size_t)f * FRAME_BYTES;
		const uint8_t *bay  = vr_bayer_frame + (size_t)f * FRAME_BYTES;
		const int8_t *gold  = vr_feat_golden + (size_t)f * VR_FEAT_ELEMS;
		const int8_t *feat;
		unsigned long a, b;
		unsigned int key;
		int best, bi;

		key = irq_lock();
		a = rdcycle(); frame_fe_mono96(mono, fe_mono);     b = rdcycle();
		R.fe_mono_cyc[f] = b - a;
		a = rdcycle(); frame_fe_rgb96(bay, fe_rgb);        b = rdcycle();
		R.fe_rgb_cyc[f] = b - a;
		a = rdcycle(); frame_fe_bayer4_48(bay, fe_bay);    b = rdcycle();
		R.fe_bay_cyc[f] = b - a;
		irq_unlock(key);

		feat = feat_for_build();
		R.feat_err[f] = 0;
		for (i = 0; i < VR_FEAT_ELEMS; i++) {
			int d = (int)feat[i] - (int)gold[i];

			if (d < 0) {
				d = -d;
			}
			if (d > R.feat_err[f]) {
				R.feat_err[f] = d;
			}
		}

		key = irq_lock();
		a = rdcycle();
		run_model(feat, out_buf, NULL);
		b = rdcycle();
		irq_unlock(key);
		R.model_cyc[f] = b - a;

		best = -32768; bi = 0;
		for (i = 0; i < MODEL_OUTPUT_SIZE; i++) {
			if ((int)out_buf[i] > best) {
				best = (int)out_buf[i];
				bi = i;
			}
		}
		R.pred[f] = bi;
		if (bi == (int)vr_label[f]) {
			R.correct++;
		}
	}
	k_sem_give(&done_sem);
}

int main(void)
{
	unsigned long fem, fer, feb, mm, tot;
	int f, bad = 0;

	printk("\nVISION_REPLAY arch=%s feed=%s model=%s frames=%d feat_elems=%d "
	       "frame_bytes=%d pext=%d\n",
	       VR_ARCH, VR_FEED_NAME, MODEL_NAME, VR_NFRAMES, VR_FEAT_ELEMS,
	       FRAME_BYTES, frame_fe_uses_pext());

	k_thread_create(&big_thread, big_stack, WORKER_STACK, worker,
			NULL, NULL, NULL, 5, 0, K_FOREVER);
	k_thread_cpu_pin(&big_thread, BIG_CPU);
	k_thread_name_set(&big_thread, "replay");
	k_thread_start(&big_thread);
	if (k_sem_take(&done_sem, K_SECONDS(300)) != 0) {
		printk("FAIL: the worker did not finish\n");
		return 1;
	}

	printk("VR_ENV cpu=%u mhartid=%u selftest=%d golden_max_abs_err=%d\n",
	       R.cpu_id, R.hartid, R.selftest, R.golden_err);
	if (R.selftest != 0) {
		printk("FAIL: frame_fe_selftest returned %d\n", R.selftest);
		bad++;
	}
	if (R.golden_err != 0) {
		printk("FAIL: model max_abs_err=%d against the baked int8 golden\n",
		       R.golden_err);
		bad++;
	}

	for (f = 0; f < VR_NFRAMES; f++) {
		printk("VR_FRAME i=%d fe_mono=%lu fe_rgb=%lu fe_bayer=%lu model=%lu "
		       "feat_max_abs_err=%d pred=%s label=%s\n",
		       f, R.fe_mono_cyc[f], R.fe_rgb_cyc[f], R.fe_bay_cyc[f],
		       R.model_cyc[f], R.feat_err[f],
		       vr_label_name[R.pred[f]], vr_label_name[vr_label[f]]);
		if (R.feat_err[f] != 0) {
			bad++;
		}
	}

	fem = median_ul(R.fe_mono_cyc, VR_NFRAMES);
	fer = median_ul(R.fe_rgb_cyc, VR_NFRAMES);
	feb = median_ul(R.fe_bay_cyc, VR_NFRAMES);
	mm  = median_ul(R.model_cyc, VR_NFRAMES);
	tot = mm + (VR_FEED == 0 ? fem : (VR_FEED == 1 ? fer : feb));

	printk("VR_MEDIAN fe_mono=%lu fe_rgb=%lu fe_bayer=%lu model=%lu end_to_end=%lu\n",
	       fem, fer, feb, mm, tot);
	printk("VR_ACC correct=%d of=%d\n", R.correct, VR_NFRAMES);
	printk("VISION_REPLAY: %s\n", bad ? "FAIL" : "PASS");
	return bad ? 1 : 0;
}
