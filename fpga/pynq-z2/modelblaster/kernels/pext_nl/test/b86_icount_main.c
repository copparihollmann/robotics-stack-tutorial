/* SPDX-License-Identifier: Apache-2.0
 *
 * B86 -- THE INSTRUCTION ACCOUNT FOR permute4_s8 AT THE ENCODER'S OWN SHAPES.
 *
 * B76 measured -40.22 % on the DECODER's permute4_s8 and the encoder has never been built
 * with -DMBP_B76=1.  The decoder's -40.22 % is a BLEND of two independent fixes inside one
 * define, and the encoder's shape mix is not the decoder's, so the bundle figure does not
 * transfer.  This file counts the two arms at the encoder's THREE distinct shapes, taken
 * from out/b81_enc_f40/enc_q16/gen/model.c (all 25 call sites, scale_in == scale_out on
 * every one, every pointer a gen/buffers.c intermediate at aligned(64)):
 *
 *   ndisp  d0,d1,d2,d3      perm        od               os                    mode    wid
 *      18  1,165,8,36       0,2,1,3     1,8,165,36       47520,36,288,1        RUNS      4
 *       6  1,8,165,36       0,2,1,3     1,165,8,36       47520,36,5940,1       RUNS      4
 *       1  1,288,1,165      0,2,3,1     1,1,165,288      47520,165,1,165       TBLOCK    1
 *
 * The board cycles each row has to explain (out/b81_enc_f40/enc_q16/console.txt, 25 of 25
 * dispatches profiled, 8,091,376 cycles over 1,188,000 elements):
 *
 *     18 x od=(1,8,165,36)   5,641,758 cyc   855,360 el    6.596 cyc/el
 *      6 x od=(1,165,8,36)   1,737,634 cyc   285,120 el    6.094 cyc/el
 *      1 x od=(1,1,165,288)    711,984 cyc    47,520 el   14.983 cyc/el
 *
 * INSTRUCTIONS ARE NOT CYCLES.  B76's P1 missed HIGH by 32 % because the memory operations
 * its RUNS fix removed were the L1 *hits* while the compulsory misses stayed, so the CPI
 * rose.  The same correction applies here and the band applies it explicitly rather than
 * projecting CPI-neutrally.  Counted with the board's own flags, same method as
 * b76_icount.sh / b74_icount.sh.
 */

#include <stdint.h>
#include <stddef.h>

void htif_puts(const char *s);
void htif_putu(uint64_t v);
void htif_exit(int code);

void perm_ship(const int8_t *, int8_t *, int, int, int, int, int, int, int, int,
	       float, float, int, int);
void perm_b76(const int8_t *, int8_t *, int, int, int, int, int, int, int, int,
	      float, float, int, int);

static inline uint64_t rd_minstret(void)
{
	uint64_t v;

	__asm__ volatile("csrr %0, minstret" : "=r"(v));
	return v;
}

static uint64_t probe_overhead(void)
{
	uint64_t best = (uint64_t)-1;
	int i;

	for (i = 0; i < 8; i++) {
		uint64_t a = rd_minstret();
		uint64_t b = rd_minstret();

		if (b - a < best)
			best = b - a;
	}
	return best;
}

static uint64_t ovh;

#define MAXEL 65536
static int8_t in_a[MAXEL] __attribute__((aligned(64)));
static int8_t out_[MAXEL] __attribute__((aligned(64)));
static int8_t ref_[MAXEL] __attribute__((aligned(64)));

static uint64_t rs_ = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void)
{
	rs_ ^= rs_ << 13; rs_ ^= rs_ >> 7; rs_ ^= rs_ << 17;
	return rs_;
}

static float bits(uint32_t u)
{
	float f;

	__builtin_memcpy(&f, &u, sizeof(f));
	return f;
}

static void row(const char *arm, long shape, long elems, long ndisp, uint64_t instr)
{
	htif_puts("MB_B86 op=permute4_s8 arm=");
	htif_puts(arm);
	htif_puts(" shape=");
	htif_putu((uint64_t)shape);
	htif_puts(" elems=");
	htif_putu((uint64_t)elems);
	htif_puts(" ndisp=");
	htif_putu((uint64_t)ndisp);
	htif_puts(" instret=");
	htif_putu(instr);
	htif_puts("\n");
}

#define TIME(call, arm, shape, elems, ndisp)                            \
	do {                                                            \
		uint64_t t0, t1;                                        \
		t0 = rd_minstret();                                     \
		call;                                                   \
		t1 = rd_minstret();                                     \
		row(arm, shape, elems, ndisp, t1 - t0 - ovh);           \
	} while (0)

/* The encoder's own quants (out/b81_enc_f40/enc_q16/gen/model.c), as bit patterns so the
 * constant in the image is the constant the board runs. scale_in == scale_out on all 25. */
#define PM_A bits(0x3EFB27F7u)   /* 0.490539283  -- the stem permute, shape 0 */
#define PM_B bits(0x3D817030u)   /* 0.0632022619 -- a rope_q head split, shape 1 */
#define PM_C bits(0x3D2B0CC1u)   /* 0.0417602099 -- a v_proj head merge, shape 2 */

/* Every DISTINCT permute4_s8 shape the ENCODER ships, with how many dispatches run it. */
static const struct { int d0, d1, d2, d3, p0, p1, p2, p3, ndisp; uint32_t s; } eshapes[] = {
	{ 1, 288, 1, 165, 0, 2, 3, 1,  1, 0x3EFB27F7u },  /* TBLOCK, os[2]==1, 165-byte reads */
	{ 1, 165,  8,  36, 0, 2, 1, 3, 18, 0x3D817030u }, /* RUNS wid 4, 1,320 runs of 36 */
	{ 1,   8, 165, 36, 0, 2, 1, 3,  6, 0x3D2B0CC1u }, /* RUNS wid 4, 1,320 runs of 36 */
};

int main(void)
{
	int i, t;

	ovh = probe_overhead();
	for (i = 0; i < MAXEL; i++)
		in_a[i] = (int8_t)(uint8_t)(rnd() & 0xff);

	for (t = 0; t < (int)(sizeof(eshapes) / sizeof(eshapes[0])); t++) {
		const long n = (long)eshapes[t].d0 * eshapes[t].d1 *
			       eshapes[t].d2 * eshapes[t].d3;
		const float s = bits(eshapes[t].s);

		TIME(perm_ship(in_a, out_, eshapes[t].d0, eshapes[t].d1, eshapes[t].d2,
			       eshapes[t].d3, eshapes[t].p0, eshapes[t].p1, eshapes[t].p2,
			       eshapes[t].p3, s, s, -128, 127),
		     "ship", t, n, eshapes[t].ndisp);
		TIME(perm_b76(in_a, out_, eshapes[t].d0, eshapes[t].d1, eshapes[t].d2,
			      eshapes[t].d3, eshapes[t].p0, eshapes[t].p1, eshapes[t].p2,
			      eshapes[t].p3, s, s, -128, 127),
		     "b76", t, n, eshapes[t].ndisp);
	}

	/* ---- The equivalence pass.  A restructuring, not an arithmetic change: the golden is
	 *      the SHIPPED kernel's own output, so this is a byte-for-byte identity check over
	 *      every element the encoder permutes, not a tolerance.  B76's gate covered the
	 *      DECODER's shapes; these three are the encoder's and one of them (shape 0) takes
	 *      a code path -- pblk_tblock -- that no encoder arm has ever run. ---- */
	{
		long bad = 0, checked = 0;

		for (t = 0; t < (int)(sizeof(eshapes) / sizeof(eshapes[0])); t++) {
			const long n = (long)eshapes[t].d0 * eshapes[t].d1 *
				       eshapes[t].d2 * eshapes[t].d3;
			const float s = bits(eshapes[t].s);
			long j;

			for (j = 0; j < n; j++) { ref_[j] = 0; out_[j] = 0; }
			perm_ship(in_a, ref_, eshapes[t].d0, eshapes[t].d1, eshapes[t].d2,
				  eshapes[t].d3, eshapes[t].p0, eshapes[t].p1, eshapes[t].p2,
				  eshapes[t].p3, s, s, -128, 127);
			perm_b76(in_a, out_, eshapes[t].d0, eshapes[t].d1, eshapes[t].d2,
				 eshapes[t].d3, eshapes[t].p0, eshapes[t].p1, eshapes[t].p2,
				 eshapes[t].p3, s, s, -128, 127);
			for (j = 0; j < n; j++) {
				checked++;
				if (ref_[j] != out_[j])
					bad++;
			}
		}
		htif_puts("MB_B86 gate checked=");
		htif_putu((uint64_t)checked);
		htif_puts(" mismatches=");
		htif_putu((uint64_t)bad);
		htif_puts(bad ? "  FAIL\n" : "  PASS\n");
		htif_exit(bad ? 1 : 0);
	}

	return 0;
}
