/* SPDX-License-Identifier: GPL-3.0-or-later */

#ifndef ECHO_CANCEL_AUDIO_H
#define ECHO_CANCEL_AUDIO_H

#include <stddef.h>
#include "conf.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * SpeexDSP audio I/O: spawn a worker thread that reads from / writes to an
 * ALSA PCM and stages frames in a ring buffer. The main thread drains the
 * ring buffer via the *_read / *_skip helpers below.
 *
 * Naming note: playback_read reads frames *out of the playback ring buffer*
 * — i.e. the AEC engine pulls speaker-bound samples to use as the far-end
 * reference. From the engine's perspective it is a read; the playback
 * thread is the producer that feeds the buffer.
 *
 * Return conventions (all int APIs):
 *   capture_start / playback_start: 0 on success, -1 on error
 *   capture_stop  / playback_stop : always 0 (worker thread joined)
 *   capture_read  / playback_read : frames transferred on success,
 *                                   -1 on timeout
 *   capture_skip                  : frames advanced on success,
 *                                   -1 on timeout / overflow
 */

int capture_start(conf_t *conf);
int capture_stop(void);
int capture_read(void *buf, size_t frames, int timeout_ms);
int capture_skip(size_t frames, int timeout_ms);

int playback_start(conf_t *conf);
int playback_stop(void);
int playback_read(void *buf, size_t frames, int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif // ECHO_CANCEL_AUDIO_H
