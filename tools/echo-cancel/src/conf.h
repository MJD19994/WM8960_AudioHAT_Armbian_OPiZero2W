/* SPDX-License-Identifier: GPL-3.0-or-later */

#ifndef ECHO_CANCEL_CONF_H
#define ECHO_CANCEL_CONF_H

/*
 * <stdatomic.h> requires C11 or later. The Makefile builds C sources with
 * -std=gnu11; if you build this project with a stricter or older standard,
 * the SpeexDSP engine will fail to compile.
 */
#ifdef __cplusplus
#include <atomic>
typedef std::atomic<int> ec_atomic_int;
#else
#include <stdatomic.h>
typedef atomic_int ec_atomic_int;
#endif

typedef struct conf_t {
    const char *rec_pcm;          // recording PCM
    const char *out_pcm;          // output PCM
    const char *playback_fifo;    // playback FIFO
    const char *out_fifo;         // AEC output FIFO
    unsigned rate;                // sample rate, Hz (e.g. 48000)
    unsigned rec_channels;        // recording channel count
    unsigned ref_channels;        // reference (playback) channel count
    unsigned out_channels;        // processed audio output channel count
    unsigned bits_per_sample;     // sample width in bits (typically 16)
    unsigned buffer_size;         // ring buffer size, in frames (rounded up to power of 2)
    unsigned playback_fifo_size;  // playback FIFO ring buffer size, in frames
    unsigned filter_length;       // SpeexDSP AEC filter length, in samples
    ec_atomic_int bypass;         // thread-safe AEC bypass flag (0 = process, 1 = passthrough)
} conf_t;

#endif // ECHO_CANCEL_CONF_H
