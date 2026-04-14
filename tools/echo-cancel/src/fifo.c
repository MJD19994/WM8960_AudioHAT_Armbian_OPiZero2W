
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

#include <signal.h>
extern volatile sig_atomic_t g_is_quit;

PaUtilRingBuffer g_out_ringbuffer;
static pthread_t g_writer_thread;
static int g_thread_created = 0;

static void *fifo_thread(void *ptr)
{
    conf_t *conf = (conf_t *)ptr;
    ring_buffer_size_t size1, size2, available;
    void *data1, *data2;

    // Non-blocking open so we can check g_is_quit while waiting for a reader
    int fd = -1;
    while (!g_is_quit) {
        fd = open(conf->out_fifo, O_WRONLY | O_NONBLOCK);
        if (fd >= 0) {
            // Clear non-blocking flag for normal writes
            int flags = fcntl(fd, F_GETFL);
            if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) < 0) {
                fprintf(stderr, "fcntl failed on %s: %s\n", conf->out_fifo, strerror(errno));
                close(fd);
                return NULL;
            }
            break;
        }
        if (errno != ENXIO) {  // ENXIO = no reader yet
            fprintf(stderr, "failed to open %s: %s\n", conf->out_fifo, strerror(errno));
            return NULL;
        }
        usleep(100000);
    }
    if (fd < 0)
        return NULL;

    // clear
    PaUtil_AdvanceRingBufferReadIndex(&g_out_ringbuffer, PaUtil_GetRingBufferReadAvailable(&g_out_ringbuffer));
    while (!g_is_quit)
    {
        available = PaUtil_GetRingBufferReadAvailable(&g_out_ringbuffer);
        if (available > 0) {
            ring_buffer_size_t total_advanced = 0;
            PaUtil_GetRingBufferReadRegions(&g_out_ringbuffer, available, &data1, &size1, &data2, &size2);
            if (size1 > 0) {
                ssize_t result = write(fd, data1, size1 * g_out_ringbuffer.elementSizeBytes);
                if (result > 0) {
                    ring_buffer_size_t elements = result / g_out_ringbuffer.elementSizeBytes;
                    total_advanced += elements;
                    // Only write data2 if data1 was fully written
                    if (elements == size1 && size2 > 0) {
                        result = write(fd, data2, size2 * g_out_ringbuffer.elementSizeBytes);
                        if (result > 0)
                            total_advanced += result / g_out_ringbuffer.elementSizeBytes;
                        else if (result < 0) {
                            if (errno == EPIPE) {
                                fprintf(stderr, "FIFO reader closed, exiting writer thread\n");
                                break;
                            }
                            if (errno != EINTR)
                                sleep(1);
                        }
                    }
                } else if (result < 0) {
                    if (errno == EPIPE) {
                        fprintf(stderr, "FIFO reader closed, exiting writer thread\n");
                        break;
                    }
                    if (errno != EINTR)
                        sleep(1);
                }
            }
            if (total_advanced > 0)
                PaUtil_AdvanceRingBufferReadIndex(&g_out_ringbuffer, total_advanced);
        } else {
            usleep(5000);
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
        if (mkfifo(conf->out_fifo, 0660) != 0) {
            fprintf(stderr, "Failed to create FIFO %s: %s\n", conf->out_fifo, strerror(errno));
            free(buf);
            g_out_ringbuffer.buffer = NULL;
            return -1;
        }
    } else if (!S_ISFIFO(st.st_mode)) {
        if (remove(conf->out_fifo) != 0) {
            fprintf(stderr, "Failed to remove existing %s: %s\n", conf->out_fifo, strerror(errno));
            free(buf);
            g_out_ringbuffer.buffer = NULL;
            return -1;
        }
        if (mkfifo(conf->out_fifo, 0660) != 0) {
            fprintf(stderr, "Failed to create FIFO %s: %s\n", conf->out_fifo, strerror(errno));
            free(buf);
            g_out_ringbuffer.buffer = NULL;
            return -1;
        }
    }

    if (pthread_create(&g_writer_thread, NULL, fifo_thread, conf) != 0) {
        fprintf(stderr, "Failed to create FIFO writer thread.\n");
        free(buf);
        g_out_ringbuffer.buffer = NULL;
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
    if (g_out_ringbuffer.buffer) {
        free(g_out_ringbuffer.buffer);
        g_out_ringbuffer.buffer = NULL;
    }
}

int fifo_write(void *buf, size_t frames)
{
    return PaUtil_WriteRingBuffer(&g_out_ringbuffer, buf, frames);
}
