
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <pthread.h>

#include "pa_ringbuffer.h"
#include "conf.h"
#include "util.h"

extern int g_is_quit;

PaUtilRingBuffer g_out_ringbuffer;
static pthread_t g_writer_thread;
static int g_thread_created = 0;

static void *fifo_thread(void *ptr)
{
    conf_t *conf = (conf_t *)ptr;
    ring_buffer_size_t size1, size2, available;
    void *data1, *data2;
    int fd = open(conf->out_fifo, O_WRONLY);      // will block until reader is available
    if (fd < 0) {
        fprintf(stderr, "failed to open %s: %s\n", conf->out_fifo, strerror(errno));
        return NULL;
    }

    // clear
    PaUtil_AdvanceRingBufferReadIndex(&g_out_ringbuffer, PaUtil_GetRingBufferReadAvailable(&g_out_ringbuffer));
    while (!g_is_quit)
    {
        available = PaUtil_GetRingBufferReadAvailable(&g_out_ringbuffer);
        PaUtil_GetRingBufferReadRegions(&g_out_ringbuffer, available, &data1, &size1, &data2, &size2);
        if (size1 > 0) {
            ssize_t result = write(fd, data1, size1 * g_out_ringbuffer.elementSizeBytes);
            if (result > 0) {
                PaUtil_AdvanceRingBufferReadIndex(&g_out_ringbuffer, result / g_out_ringbuffer.elementSizeBytes);
            } else if (result < 0 && errno != EINTR) {
                sleep(1);
            }
        }
        if (size2 > 0) {
            ssize_t result = write(fd, data2, size2 * g_out_ringbuffer.elementSizeBytes);
            if (result > 0) {
                PaUtil_AdvanceRingBufferReadIndex(&g_out_ringbuffer, result / g_out_ringbuffer.elementSizeBytes);
            } else if (result < 0 && errno != EINTR) {
                sleep(1);
            }
        }
        if (size1 == 0 && size2 == 0) {
            usleep(100000);
        }
    }

    close(fd);

    return NULL;
}

int fifo_setup(conf_t *conf)
{
    struct stat st;

    unsigned buffer_size = power2(conf->buffer_size);
    unsigned buffer_bytes = conf->out_channels * conf->bits_per_sample / 8;

    void *buf = calloc(buffer_size, buffer_bytes);
    if (buf == NULL)
    {
        fprintf(stderr, "Fail to allocate memory.\n");
        return -1;
    }

    ring_buffer_size_t ret = PaUtil_InitializeRingBuffer(&g_out_ringbuffer, buffer_bytes, buffer_size, buf);
    if (ret == -1)
    {
        fprintf(stderr, "Initialize ring buffer but element count is not a power of 2.\n");
        free(buf);
        return -1;
    }

    if (stat(conf->out_fifo, &st) != 0) {
        if (mkfifo(conf->out_fifo, 0666) != 0) {
            fprintf(stderr, "Failed to create FIFO %s: %s\n", conf->out_fifo, strerror(errno));
            free(buf);
            return -1;
        }
    } else if (!S_ISFIFO(st.st_mode)) {
        if (remove(conf->out_fifo) != 0) {
            fprintf(stderr, "Failed to remove existing %s: %s\n", conf->out_fifo, strerror(errno));
            free(buf);
            return -1;
        }
        if (mkfifo(conf->out_fifo, 0666) != 0) {
            fprintf(stderr, "Failed to create FIFO %s: %s\n", conf->out_fifo, strerror(errno));
            free(buf);
            return -1;
        }
    }

    if (pthread_create(&g_writer_thread, NULL, fifo_thread, conf) != 0) {
        fprintf(stderr, "Failed to create FIFO writer thread.\n");
        free(buf);
        return -1;
    }
    g_thread_created = 1;

    return 0;
}

void fifo_cleanup(void)
{
    if (g_thread_created) {
        pthread_join(g_writer_thread, NULL);
        g_thread_created = 0;
    }
}

int fifo_write(void *buf, size_t frames)
{
    return PaUtil_WriteRingBuffer(&g_out_ringbuffer, buf, frames);
}
