/* SPDX-License-Identifier: GPL-3.0-or-later */

#ifndef ECHO_CANCEL_UTIL_H
#define ECHO_CANCEL_UTIL_H

/*
 * power2: round v up to the next power of two.
 * Returns 1 for v == 0, the value itself if already a power of two, and 0
 * for v > 0x80000000 (the next power of two would overflow 32 bits — see
 * util.c).
 */

#ifdef __cplusplus
extern "C" {
#endif

unsigned power2(unsigned v);

#ifdef __cplusplus
}
#endif

#endif // ECHO_CANCEL_UTIL_H
