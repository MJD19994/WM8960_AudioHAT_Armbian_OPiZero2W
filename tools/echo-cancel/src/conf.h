/* SPDX-License-Identifier: GPL-3.0-or-later */

#ifndef ECHO_CANCEL_CONF_H
#define ECHO_CANCEL_CONF_H

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
    unsigned rate;
    unsigned rec_channels;  // recording channels
    unsigned ref_channels;  // reference (playback) channels
    unsigned out_channels;  // processed audio output channels
    unsigned bits_per_sample;
    unsigned buffer_size;
    unsigned playback_fifo_size;
    unsigned filter_length;
    ec_atomic_int bypass;   // thread-safe AEC bypass flag
} conf_t;

#endif // ECHO_CANCEL_CONF_H
