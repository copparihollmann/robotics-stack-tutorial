/* SPDX-License-Identifier: Apache-2.0
 *
 * mbxr -- the driver for the decoupled RoCC engine (rtl_study/roccmoon/mbxr_engine.v).
 *
 * ONE DRIVER, TWO HOSTS.  The same C runs against the RTL in Verilator (tb_mbxr.cpp, where a
 * "command" drives the engine's ports for a cycle and the memory is a behavioural TileLink
 * slave) and on hart 1 of the board (where a command is one custom-1 instruction).  So the
 * testbench does not check an engine; it checks this engine driven by this driver against
 * ModelBlaster's reference kernel, and that is what the board runs.
 *
 * WHAT IT SUPPORTS, and every refusal is a return code the caller falls back on:
 *   linear_s8 and a 1-D conv2d_s8 whose window is contiguous in memory (NHWC-ordered), with
 *   input_offset = filter_offset = output_offset = 0, K a multiple of 8, a pixel stride that
 *   is a whole number of 64-bit words, and a 8-byte aligned input tensor.
 *
 * NO FLOATING POINT, NO ALLOCATION.  The caller owns every buffer and gives each one as a
 * physical address; `p2v` turns one into a pointer the driver may read or write.  On the
 * board that is the identity (Zephyr runs in M-mode, no MMU).
 */
#ifndef MBXR_H
#define MBXR_H

#include <stddef.h>
#include <stdint.h>

/* THE ARRAY WIDTH, AND IT IS HALF OF A CONTRACT THE OTHER HALF OF WHICH IS IN THE BITSTREAM.
 * This constant lays out the weight planes (mbxr.c: the tile map n = (t*Q + q)*NCH + r, the
 * `sd` descriptor's nrows, the drain's row_bytes = qt*NCH).  mbxr_tseq.v states the other side:
 * every lane reads the SAME word address from its OWN plane, and each plane holds only that
 * lane's rows.  A host that packs 4 planes against an engine that addresses 8 produces a drain
 * descriptor half the size of what the packer emits, the store FIFO never drains, and the fence
 * never clears -- MBXR_E_TIMEOUT after the poll limit, with NO error bit.  That is exactly what
 * 0x5A5A0033 did on garden: 0 of 4,125 dispatches executed (TODO.md, B96/B98).
 *
 * Overridable so one tree builds a guest for either engine: -DMBXR_NCH=8.  It is NOT free to
 * choose -- MBXR_ID_NCH() below reads what the silicon actually is, and mbxr_rt.h refuses the
 * pairing at init rather than hanging. */
#ifndef MBXR_NCH
#define MBXR_NCH        4
#endif
#define MBXR_BUF_WORDS  1024          /* scratchpad words per buffer, per port */

/* funct7 */
enum {
  MBXR_SD = 0, MBXR_LD = 1, MBXR_CFG = 2, MBXR_MM = 3, MBXR_SQ = 4,
  MBXR_ST = 5, MBXR_FENCE = 6, MBXR_STAT = 7, MBXR_CAP = 8
};

/* fence status bits; bits 39:24 are the drain's blocks left to issue */
#define MBXR_S_FILL   (1ULL << 0)
#define MBXR_S_TSEQ   (1ULL << 1)
#define MBXR_S_DRAIN  (1ULL << 2)
#define MBXR_S_PIPE   (1ULL << 3)
#define MBXR_S_WREADY (1ULL << 41)   /* revision 2b: the W lane is out of reset and quiet */
#define MBXR_S_OVF    (1ULL << 46)
#define MBXR_S_ERR    (1ULL << 47)
#define MBXR_S_BUSY   (MBXR_S_FILL | MBXR_S_TSEQ | MBXR_S_DRAIN | MBXR_S_PIPE)
#define MBXR_S_LEFT(s) (((s) >> 24) & 0xffffULL)
/* Revision-2 engines (rtl_study/roccmoon/rev2): bits 63:48 are the drain's acknowledged
 * watermark -- every block below it has had its AccessAck.  Revision 1 reads 0 there, so on
 * it incremental placement places nothing early and stays correct. */
#define MBXR_S_ACKED(s) (((s) >> 48) & 0xffffULL)

/* stat counters */
enum { MBXR_C_FILL_BEATS = 0, MBXR_C_DRAIN_BEATS, MBXR_C_STEPS, MBXR_C_CYC_FILL,
       MBXR_C_CYC_TSEQ, MBXR_C_CYC_BUSY, MBXR_C_ID };

/* return codes */
#define MBXR_OK            0
#define MBXR_E_SHAPE      -1     /* unsupported shape: fall back to the core */
#define MBXR_E_ALIGN      -2     /* input tensor not 8-byte aligned */
#define MBXR_E_HW         -3     /* the engine flagged an error (denied/corrupt/overflow) */
#define MBXR_E_TIMEOUT    -4
#define MBXR_E_LANE       -5     /* revision 2b: the W lane did not become ready within lane_wait polls */
#define MBXR_E_WIDTH      -6     /* the engine's NCH disagrees with MBXR_NCH: see MBXR_ID_NCH */

typedef struct {
  uint64_t (*cmd)(void *ctx, unsigned funct, uint64_t rs1, uint64_t rs2, int xd);
  void    *(*p2v)(void *ctx, uint64_t pa);
  void     *ctx;
  uint64_t  poll_limit;       /* fence polls before MBXR_E_TIMEOUT; 0 = forever */
  uint64_t (*now)(void *ctx); /* optional cycle clock: splits the host's time into mbxr_stats */
  int       place_chunk;      /* 0: place results byte by byte (Lab B25 run 7); 1: in runs of up
                               * to 64 bytes through a local buffer.  On the LITTLE hart's
                               * direct-mapped 64-set L1D a scratch and an output buffer that
                               * share a set evict each other on every byte. */
  int       place_early;      /* 1: INCREMENTAL PLACEMENT.  While hart 1 waits on the engine
                               * (between tiles, and for the last one), it places results whose
                               * Puts the engine reports ACKNOWLEDGED, in slices of at most
                               * MBXR_PLACE_SLICE bytes between fence polls.  0: all placement
                               * after the dispatch (as measured in Labs B25 and B26). */
  uint64_t  lane_wait;        /* revision 2b only: fence polls to wait for MBXR_S_WREADY before a
                               * dispatch arms anything; MBXR_E_LANE if it never comes.  0: no
                               * check (revisions 1 and 2a read 0 in that bit). */
  int       drain_strided;    /* 1: THE STRIDED DRAIN.  The engine's `st` descriptor is 2-D, so a
                               * weight tile's results are Put straight into their rows of
                               * out[npix][N] and there is NO placement step at all -- place_chunk
                               * and place_early become dead.  Needs an engine whose id word
                               * (MBXR_C_ID) reads 'MS', an image planned with
                               * mbxr_wimage_plan_ex(.., 1), and mbxr_run_to's out_pa; any of
                               * those missing and the run falls back to the flat drain and
                               * places, bit for bit as before. */
} mbxr_dev;

/* The engine id word (MBXR_C_ID): {NCH[15:0], LDEPTH[7:0], SDEPTH[7:0], signature[15:0]}.
 * 'MR' = the flat drain of revisions 1/2a/2b; 'MS' = the 2-D descriptor this header's
 * drain_strided needs.  A driver that asked for the strided drain on an 'MR' engine would
 * write the whole output tensor to dst_base, so the check is not optional. */
/* `st`'s rs2: {row_stride[63:32], row_bytes[31:16], nrows[15:0]}.  A FLAT drain of `blocks`
 * 64-byte blocks to a 64-byte aligned base is the one-block-per-row case -- the engine's size
 * select then picks 64 bytes every time, so the A channel is beat for beat what the flat
 * `nblocks` descriptor emitted.
 *
 * WHY `nrows` IS IN THE LOW SIXTEEN BITS, and it is the whole of this ABI.  A PRE-0x5A5A002E
 * ENGINE READS rs2[15:0] AS `nblocks` AND IGNORES EVERYTHING ABOVE IT (mbxr_engine.v before
 * the 2-D descriptor: `.nblocks(cmd_rs2[15:0])`).  Putting the ROW COUNT there makes the flat
 * command word mean the SAME THING on both engines -- `blocks` rows of one block on the new
 * one, `blocks` blocks on the old one -- so one runtime drives either.  The first cut of this
 * put `row_bytes` there instead, and an old engine then read `nblocks = 64` for every drain,
 * waited for blocks that never came, and every dispatch returned MBXR_E_TIMEOUT.  That is not
 * a theory: it killed four board runs across two boards and two workstreams before it was
 * found, and tb_mbxr's OLD-ENGINE case now fails if this field order is ever swapped back. */
#define MBXR_ST_RS2(row_bytes, nrows, row_stride) \
  (((uint64_t)(uint32_t)(row_stride) << 32) | ((uint64_t)((row_bytes) & 0xffff) << 16) | \
   (uint64_t)((nrows) & 0xffff))
#define MBXR_ST_FLAT(blocks)  MBXR_ST_RS2(64, (blocks), 64)

/* THE PRE-002E ABI, CHECKED AT COMPILE TIME rather than on a board.  A flat descriptor's low
 * sixteen bits must be the block count, because that is what an engine without the 2-D
 * descriptor will use.  Anything that breaks this stops the build, not a lock-holding run. */
/* AND THE SAME PAIRING, CHECKED BEFORE A BOARD RUN TAKES A LOCK.  `st`'s encoding is an ABI
 * between a GUEST IMAGE and a BITSTREAM, and neither can see the other: a v2 image on a
 * pre-002E engine used to read nblocks = 64 and hang, and a PRE-v2 image on a 002E engine reads
 * row_bytes = 0, never starts its drain, and hangs the same way.  Both directions are silent:
 * MBXR_E_TIMEOUT after 20 M polls, with no error bit and nothing in the console to say why.
 * Four board sessions were spent on the first direction before it was found.
 *
 * So every image stamps what it speaks, once, where `strings` can find it, and
 * scripts/lib/mbxr_abi.sh refuses the pairing before with_board.sh is ever called.  Put
 * MBXR_ABI_STAMP(name, strided) at file scope in exactly one translation unit per image. */
/* `used` stops the COMPILER dropping it; it does not stop the LINKER.  Zephyr builds with
 * -fdata-sections -Wl,--gc-sections, which collected the first version of this stamp silently
 * -- the image linked, `strings` found nothing, and the gate then read a v2 image as an
 * untagged one.  `retain` (SHF_GNU_RETAIN) is what --gc-sections honours; where the toolchain
 * is too old for it the stamp is declared volatile and referenced, which no collector removes. */
#if defined(__has_attribute)
# if __has_attribute(retain)
#  define MBXR_ABI_KEEP __attribute__((used, retain))
# endif
#endif
#ifndef MBXR_ABI_KEEP
# define MBXR_ABI_KEEP __attribute__((used))
#endif
/* Two levels, because `#x` stringifies the parameter AS WRITTEN.  The first cut had one, so
 * MBXR_ABI_STAMP(s, RMB_DRAIN_STRIDED) put the literal text "strided=RMB_DRAIN_STRIDED" in the
 * image -- present, retained, and useless: the gate read it as an untagged image. */
#define MBXR_ABI_STR_(x) #x
#define MBXR_ABI_STR(x)  MBXR_ABI_STR_(x)
#define MBXR_ABI_STAMP(name, strided)                                                  \
  MBXR_ABI_KEEP volatile const char name[] = "MBXR_ABI:v2:strided=" MBXR_ABI_STR(strided); \
  MBXR_ABI_KEEP const void *name##_ref(void);                                           \
  MBXR_ABI_KEEP const void *name##_ref(void) { return (const void *)name; }

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert((MBXR_ST_FLAT(0x1234u) & 0xffffu) == 0x1234u,
               "MBXR_ST_FLAT must keep the block count in rs2[15:0]: a pre-0x5A5A002E engine "
               "reads exactly those bits as nblocks and ignores the rest");
_Static_assert((MBXR_ST_FLAT(0xffffu) & 0xffffu) == 0xffffu, "the same at the 16-bit limit");
#endif

/* THE ID WORD'S FIELDS, ALL OF THEM.  mbxr_engine.v:
 *
 *     reg [47:0] stat_sel;
 *     default: stat_sel = {NCH[15:0], LDEPTH[7:0], SDEPTH[7:0], 16'h4D53};
 *     assign resp_data = ... : {16'd0, stat_sel};
 *
 * so the 64-bit word is 0x0000_NNNN_LL_SS_ssss and the WIDTH IS AT BIT 32, not 16.  Measured,
 * not read off the concatenation: 0x0000000404024d53 from the NCH = 4 engine and
 * 0x0000000804024d53 from the NCH = 8 one, both in Verilator against the 0x5A5A0033 sources.
 *
 * WHY THIS EXISTS.  Until 2026-09-19 the runtime parsed this word for its SIGNATURE ONLY and
 * threw the top thirty-two bits away, so an NCH = 8 engine was indistinguishable from an
 * NCH = 4 one to the software and the mismatch could only ever present as a 20-million-poll
 * hang with no error bit -- the same silent-hang signature the `st` ABI note above records
 * four board sessions being spent on.  The engine states its width; parse it. */
#define MBXR_ID_SIG(idword)     ((uint32_t)((idword) & 0xffffU))
#define MBXR_ID_SDEPTH(idword)  ((uint32_t)(((idword) >> 16) & 0xffU))
#define MBXR_ID_LDEPTH(idword)  ((uint32_t)(((idword) >> 24) & 0xffU))
#define MBXR_ID_NCH(idword)     ((uint32_t)(((idword) >> 32) & 0xffffU))
#define MBXR_ID_FLAT   0x4D52U
#define MBXR_ID_STRIDE 0x4D53U

#ifndef MBXR_PLACE_SLICE
#define MBXR_PLACE_SLICE   512
#endif
/* TEST ONLY.  MBXR_PLACE_TEST_MARGIN=m gates placement on elapsed blocks (issued - m) instead
 * of acknowledgements.  That is a timing assumption, and tb_mbxr's L2-like latency case shows
 * it corrupting results; it exists as that test's negative control and must never be built
 * for a board. */

/* A layer's weights, laid out planar once: tile t, plane r (lane r = output channel n with
 * n % 4 == r), row q = one output channel: word 0 is the int32 bias, words 1..G the K
 * weights zero-padded to 8G.  Planes are 2^lgpw words.  Built from the model's own weights,
 * never modified afterwards -- which is what makes it safe to read from MBUS. */
typedef struct {
  uint64_t pa;
  int      N, K, G;
  int      Q;            /* quads per tile */
  int      tiles;
  int      lgpw;
  int      strided;      /* 1: planned for the 2-D drain -- every tile's rows are whole 64-bit
                          * words and no row runs past column N */
  /* THE WEIGHT GRID AND THE ACTIVATION EXTENT ARE TWO DIFFERENT LENGTHS, and before 2026-09-18
   * they were one field.  `K` is the ACTIVATION row extent in bytes -- what a pixel's window
   * spans in memory, what act_extent fetches, what the pixel stride is measured against.  `Kw`
   * is the WEIGHT row length in the image, K * wbits / 8, and it is what `G` is derived from.
   *
   * WHY IT HAS TO BE TWO FIELDS.  At wbits = 6 a K = 288 row is 216 image bytes and 288
   * activation bytes.  Handing a planner with one K the PACKED width gives the right G, Q,
   * lgpw and tile count with no new arithmetic -- and then fetches 216 activation bytes for a
   * 288-byte row.  Nothing checks it: the plan is self-consistent, the engine runs, the drain
   * drains, and the numbers are wrong.  It would look exactly like a defect in the unpacker.
   * At wbits = 8, Kw == K and every field below is what it always was. */
  int      Kw;           /* weight row bytes in the image = K * wbits / 8 */
  int      wbits;        /* 8 (a byte a code) or 6 (packed, LSB-first, two's complement) */
  size_t   bytes;
} mbxr_wimage;

typedef struct {
  int32_t mult;
  int     shift;
  int     amin, amax;
} mbxr_quant;

typedef struct {
  uint64_t loads_act, loads_wgt;      /* ld commands issued */
  uint64_t bytes_act, bytes_wgt;      /* bytes those loads fetched */
  uint64_t pairs;                     /* mm commands (incl. the padding one) */
  uint64_t polls;                     /* fence commands */
  uint64_t out_bytes;                 /* bytes drained, incl. padding */
  uint64_t last_status;               /* the last fence word seen (diagnosis on a timeout) */
  /* with dev->now: where the HOST's cycles went.  Everything in mbxr_run that is neither is
   * command issue and tile planning. */
  uint64_t cyc_wait;                  /* inside mbxr_wait: fence polls, engine running or idle */
  uint64_t cyc_place;                 /* placing the drained bytes into out[npix, N], all of it */
  uint64_t placed_early;              /* bytes of that placed while waiting (place_early) */
} mbxr_stats;

/* Plan an image.  Returns its size in bytes, 0 if the shape is unsupported.
 *
 * `for_strided_drain` rounds the quads per tile DOWN TO EVEN.  NCH = 4 bytes a quad, so an even
 * quad count makes every drained row a whole number of 64-bit words, which is what lets the
 * engine Put rows straight into out[npix][N] with no byte masks and no byte funnel (mbxr_st.v).
 * It sets img->strided when the shape can take it -- N a multiple of 8 and at least two quads
 * per tile -- and leaves it 0 otherwise, so mbxr_run_to falls back to the flat drain.
 *
 * WHAT ROUNDING COSTS, measured against mbxr_run's own tile plan on Moonshine's six encoder
 * shapes: enc_qkvo Q 27 -> 26 with the tile count (3), the plane size (lgpw 10) and the fill
 * traffic (237.8 KB) ALL UNCHANGED; enc_fc1 and enc_fc2 lose a tile each (11 -> 12) for +9.1 %
 * fill; the three stem convolutions are unchanged.  Encoder fill 44.07 -> 45.91 MB, +4.2 %,
 * against a `cyc_place` of 53.4 M cycles removed.  Rounding to a multiple of SIXTEEN instead --
 * which would make each row a whole number of 64-byte blocks -- costs +16.6 % fill AND STILL
 * DOES NOT GIVE BLOCK-ALIGNED ROWS, because a row's address is p*N + n0 and N = 288 is not a
 * multiple of 64.  That is why the drain splits by alignment rather than by block. */
size_t mbxr_wimage_plan_ex(mbxr_wimage *img, int N, int K, int for_strided_drain);
size_t mbxr_wimage_plan(mbxr_wimage *img, int N, int K);

/* The same plan with a SUB-BYTE weight grid.  `wbits` is 8 or 6; `K` is still the activation
 * row extent in bytes, and the image rows become K * wbits / 8 bytes of packed codes.
 *
 * At wbits = 6 the caller's rows must hold codes in [-31, 31], one per byte, and
 * mbxr_wimage_build* packs them: code k occupies bits [6k, 6k+6) of the row, LSB first, two's
 * complement, so a little-endian 64-bit scratchpad word yields ascending k with no byte swap.
 * That bit order is the contract with the engine's read-port unpacker (mbxr_tseq's phase
 * counter and mbxr_engine's 48-bit select); it is not free to change on one side.
 *
 * Refused (returns 0) unless K * wbits is a multiple of 64 -- a packed row has to be a whole
 * number of 64-bit words, because the scratchpad has no sub-word addressing.
 * mbxr_wimage_plan_ex(img, N, K, s) == mbxr_wimage_plan_bits(img, N, K, 8, s), byte for byte. */
size_t mbxr_wimage_plan_bits(mbxr_wimage *img, int N, int K, int wbits, int for_strided_drain);

/* Pack/unpack one row of `K` codes in [-31, 31] to/from `K * 6 / 8` bytes, in the order above.
 * Exposed so a builder and a checker can share the one definition of the bit order. */
void mbxr_pack6(const int8_t *codes, int K, uint8_t *dst);
void mbxr_unpack6(const uint8_t *src, int K, int8_t *codes);

/* The builder's form: `Kp` codes, the first `n` from `codes` and the rest the row's zero
 * padding, clamped to [-31, 31] with the clamps COUNTED and returned.  No staging buffer.  A
 * non-zero return means a six-bit image is being built from an eight-bit grid -- a different
 * defect from a broken unpacker, and one that a wrong answer alone cannot separate from it. */
uint64_t mbxr_pack6_rowz(const int8_t *codes, int n, int Kp, uint8_t *dst);

/* Write the planned image at physical address `pa` (64-byte aligned).  `rows` is [N, K],
 * row-major, ONE CODE PER BYTE at every grid (a linear layer's weight, or a conv weight
 * already reordered to the input window's byte order); at wbits = 6 this function packs them.
 * `bias` may be NULL. */
int mbxr_wimage_build(const mbxr_dev *dev, mbxr_wimage *img, uint64_t pa,
                      const int8_t *rows, const int32_t *bias);

/* The same image, built in ONE PASS with no staging buffer.  `row_fn(ctx, n, dst)` writes
 * row n's K bytes straight into the image; the tile map n = (t*Q + q)*NCH + r inverts in
 * closed form, so the build can walk n instead of (t, q, r):
 *
 *     r = n % NCH ;  u = n / NCH ;  q = u % Q ;  t = u / Q
 *
 * Verified exhaustively over all seven Moonshine shapes -- 19,264 of 19,264 (t,q,r) triples
 * round-trip and every n in [0, N) is covered -- and gated by building each image BOTH ways
 * into differently-poisoned arenas and comparing byte for byte: identical at every shape,
 * including lm_head's 4,980,736 bytes across 152 tiles.
 *
 * It replaces two passes and a full-plane zeroing with one pass and a padding zero: the
 * staged write, the staged read back and the plane write become one write, and only the
 * slots no n maps to are cleared.  4.01x fewer byte-operations on both halves.
 * ENGINE/ENGINE_WAIT_ANATOMY.md sections 18-20. */
int mbxr_wimage_build_fn(const mbxr_dev *dev, mbxr_wimage *img, uint64_t pa,
                         void (*row_fn)(void *ctx, int n, int8_t *dst), void *ctx,
                         const int32_t *bias);

/* One dispatch.  `in_pa`: the input tensor; pixel p's window starts at in_pa + p*8*astride
 * and is K bytes long.  A linear layer is astride = K/8, npix = M.  Output is written to
 * out[p*N + n].  `scratch_pa` must hold npix*ceil(N/4)*4 + 64 bytes, 64-byte aligned. */
int mbxr_run(const mbxr_dev *dev, const mbxr_wimage *img,
             uint64_t in_pa, int npix, int astride,
             const mbxr_quant *q, uint64_t scratch_pa, int8_t *out, mbxr_stats *st);

/* The same dispatch, told where `out` IS.  The strided drain writes the output tensor itself,
 * so it needs out's PHYSICAL address; `out` stays the pointer the driver would place through.
 * out_pa = 0 (what mbxr_run passes) means "not addressable by the engine": the flat drain and
 * the placement step, unchanged.  scratch_pa is unused by the strided path and the scratch is
 * never read, but it is still checked and still required, so one caller serves both arms. */
int mbxr_run_to(const mbxr_dev *dev, const mbxr_wimage *img,
                uint64_t in_pa, int npix, int astride,
                const mbxr_quant *q, uint64_t scratch_pa, int8_t *out, uint64_t out_pa,
                mbxr_stats *st);

/* Wait until every bit in `mask` is clear.  Returns the last status, or ~0 on timeout. */
uint64_t mbxr_wait(const mbxr_dev *dev, uint64_t mask, mbxr_stats *st);

#endif
