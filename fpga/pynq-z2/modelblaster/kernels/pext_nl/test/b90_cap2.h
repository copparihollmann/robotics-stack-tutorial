/* SPDX-License-Identifier: Apache-2.0
 *
 * B90 -- force the engine's outstanding-Get cap to 2 for ONE ARM, without editing anything
 * shared.
 *
 * WHY THIS FILE EXISTS INSTEAD OF A FLAG.  scripts/58 sets the cap from the bitstream's MAGIC
 * (`CAP_CFLAG="-DMBXR_RT_CAP=4"` for every 0092-bearing build) and appends it to the compiler
 * line AFTER whatever `--kernel-cflags` supplied, so a later `-DMBXR_RT_CAP=2` cannot win: the
 * last -D on the line is the one that stands.  There is no `--rt-cap` option and no environment
 * hook.  Editing scripts/58 to add one would be editing a shared script that five labs are
 * executing (TODO.md:8190 records what that costs), and it is not this lab's to edit.
 *
 * HOW THIS WORKS.  GCC builds its initial macro table from ALL -D and -U options first, and only
 * then pushes any `-include` file in front of the primary source.  So an `-include` of this file
 * is processed AFTER the script's `-DMBXR_RT_CAP=4`, whatever order the two appear in, and the
 * #undef below removes it cleanly rather than triggering a redefinition diagnostic.
 *
 * SCOPE.  `--kernel-cflags` reaches kernels.c only, which is the translation unit that issues the
 * cap command -- checked, not assumed: `qatu_bothlanes_{off,on}` were built with
 * `-DMBXR_RT_CAP=3` through that same path and their records report `cap_asked = 3`.
 *
 * AND THE RECORD VERIFIES IT.  `mbxr_rt_stats.cap_asked` is written from this macro and lands in
 * run.json.  An arm built with this header that does not report `cap_asked = 2` did not get the
 * override and MUST be discarded, not interpreted.  That is B90's F0.
 *
 * 2 is inside the contract: mbxr_rt.h requires 1..4 (the fill has LDEPTH = 4 source IDs), and a
 * LOWER cap is safe on every build -- the 3-vs-4 caveat in that header is about builds WITHOUT
 * patch 0092, where four in flight dips.  Nothing dips downward.
 */
#undef  MBXR_RT_CAP
#define MBXR_RT_CAP 2
