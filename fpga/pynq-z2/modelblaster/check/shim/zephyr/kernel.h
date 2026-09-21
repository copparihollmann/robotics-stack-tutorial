/* SPDX-License-Identifier: Apache-2.0
 *
 * A stand-in for <zephyr/kernel.h>, so ModelBlaster's generated model.c -- which is
 * used UNMODIFIED, exactly as the board image uses it -- also builds for the host and
 * for the bare-metal spike harness in ../icount/.
 *
 * model.c pulls in one thing from Zephyr and one only: k_cycle_get_64(), for the
 * wall-clock cross-check it reports alongside the per-dispatch rdcycle deltas.  Neither
 * of the harnesses here uses that number -- the host one compares tensors and the spike
 * one brackets each dispatch with minstret itself -- so returning a constant changes
 * nothing either of them measures.  Anything else model.c needed would fail to compile
 * here rather than silently doing something different, which is the point of keeping
 * this file as small as it is.
 */

#ifndef MB_PEXT_ZEPHYR_SHIM_H_
#define MB_PEXT_ZEPHYR_SHIM_H_

#include <stdint.h>

static inline uint64_t k_cycle_get_64(void) { return 0; }

#endif /* MB_PEXT_ZEPHYR_SHIM_H_ */
