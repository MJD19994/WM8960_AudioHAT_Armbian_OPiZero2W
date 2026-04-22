
#ifndef ECHO_CANCEL_AUDIO_H
#define ECHO_CANCEL_AUDIO_H

#include <stddef.h>
#include "conf.h"

#ifdef __cplusplus
extern "C" {
#endif

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
