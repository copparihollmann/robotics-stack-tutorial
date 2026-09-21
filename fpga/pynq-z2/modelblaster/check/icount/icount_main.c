/* SPDX-License-Identifier: Apache-2.0
 *
 * Dynamic instruction counts, per LeNet dispatch, on spike.
 *
 * WHAT THIS MEASURES AND WHY IT IS THE RIGHT THING TO MEASURE.  The board is off limits
 * -- no bitstream contains the extension yet -- so a cycle count is not available and
 * would not be honest if it were.  What IS available is exactly what PEXT_SPEC.md
 * section 5 used to justify the whole extension: `minstret`, retired instructions, from
 * spike, on the real dispatch shapes with the real weights and the real quant
 * parameters.  Same compiler, same flags, same generated model.c as the board image.
 *
 * Each dispatch is called through the generated MODEL_<MID>_DISPATCH_FNS table, one at a
 * time, bracketed by a `csrr minstret` of our own.  Nothing is inferred from model.c's
 * own rdcycle instrumentation: on spike mcycle happens to equal minstret, but relying on
 * that would make the number depend on a simulator implementation detail rather than on
 * the counter the claim is about.
 *
 * The two builds this is compiled into differ in exactly one file -- the generated
 * kernels.c -- so the difference between the two columns is the kernels and nothing
 * else.  The warm-up pass before the measured one matters more than it looks: the
 * scratch buffers in the pext kernels are in .bss and the weights are in .rodata, and
 * while spike has no caches to warm, the warm-up also runs the model once so a
 * first-call lazy path (there are none, but proving it costs one pass) cannot land
 * inside the measurement.
 *
 * The output is one line per dispatch plus a total, in a format count_instructions.py
 * parses.  It also re-checks the model output against the baked golden -- an
 * instruction count from a run that computed the wrong answer would be worthless, and
 * this is the one place where the REAL encodings execute (spike decodes MBP since
 * patches/0006-spike-mbp-pext-insns.patch), as opposed to the host checks which
 * exercise pext.h's software model.
 */

#include <stdint.h>
#include <stddef.h>

#include "model.h"
#include "test_io.h"

void htif_puts(const char *s);
void htif_putu(uint64_t v);
void htif_exit(int code);

#ifndef MB_ICOUNT_WARMUP
#define MB_ICOUNT_WARMUP 1
#endif

static inline uint64_t rd_minstret(void)
{
    uint64_t v;
    __asm__ volatile("csrr %0, minstret" : "=r"(v));
    return v;
}

/* The counter reads themselves retire instructions.  Measure the empty window once and
 * subtract it, so a 200-instruction dispatch is not reported as 204. */
static uint64_t probe_overhead(void)
{
    uint64_t best = (uint64_t)-1;
    int i;

    for (i = 0; i < 8; i++) {
        uint64_t a = rd_minstret();
        uint64_t b = rd_minstret();
        if (b - a < best) best = b - a;
    }
    return best;
}

int main(void)
{
    static model_output_t out[MODEL_TEST_OUTPUT_LEN];
    model_state_t s;
    const model_op_record_t *recs;
    uint64_t counts[MODEL_OP_COUNT];
    uint64_t overhead, total = 0;
    int i, n = 0, bad = 0;

#if MB_ICOUNT_WARMUP
    model_run_test(out, 0);
#endif

    overhead = probe_overhead();

    s.input = model_test_input;
    s.output = out;
    s.pool = 0;
    model_reset_profile();
    for (i = 0; i < MODEL_OP_COUNT; i++) {
        uint64_t a = rd_minstret();
        model_dispatch_fns[i](&s);
        counts[i] = rd_minstret() - a - overhead;
        total += counts[i];
    }

    for (i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
        if (out[i] != model_test_golden[i]) bad++;
    }

    recs = model_profile_records(&n);
    htif_puts("MB_ICOUNT model=");
    htif_puts(MODEL_NAME);
    htif_puts(" quant=");
    htif_puts(MODEL_QUANT);
    htif_puts(" ops=");
    htif_putu((uint64_t)MODEL_OP_COUNT);
    htif_puts(" probe_overhead=");
    htif_putu(overhead);
    htif_puts("\n");

    for (i = 0; i < MODEL_OP_COUNT; i++) {
        htif_puts("MB_ICOUNT_OP id=");
        htif_putu((uint64_t)i);
        htif_puts(" name=");
        htif_puts(i < n ? recs[i].name : "?");
        htif_puts(" op=");
        htif_puts(i < n ? recs[i].op : "?");
        htif_puts(" shape=");
        htif_puts(i < n ? recs[i].shape : "?");
        htif_puts(" instret=");
        htif_putu(counts[i]);
        htif_puts("\n");
    }

    htif_puts("MB_ICOUNT_TOTAL instret=");
    htif_putu(total);
    htif_puts(" output_mismatches=");
    htif_putu((uint64_t)bad);
    htif_puts("\n");
    htif_puts(bad ? "MB_ICOUNT FAIL\n" : "MB_ICOUNT PASS\n");

    htif_exit(bad ? 1 : 0);
    return bad;
}
