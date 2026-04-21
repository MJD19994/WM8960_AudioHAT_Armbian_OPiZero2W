// ec - echo canceller

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdatomic.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <limits.h>
#include <sys/stat.h>

#include <speex/speex_echo.h>

#include "conf.h"
#include "audio.h"

// Parse a non-negative integer from optarg; abort on garbage, negatives, or
// values above UINT_MAX (which would silently truncate when callers cast to
// unsigned). atoi silently turns "-1" into a huge unsigned and "abc" into 0.
static unsigned parse_nonneg(const char *s, const char *name)
{
    char *end;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno != 0 || end == s || *end != '\0' || v < 0 || v > UINT_MAX) {
        fprintf(stderr, "Invalid value for -%s: '%s' (must be 0..%u)\n", name, s, UINT_MAX);
        exit(1);
    }
    return (unsigned)v;
}

// Open a debug file safely: service runs as root, so O_NOFOLLOW + 0600 keeps
// a symlink planted at the path from clobbering arbitrary files.
static FILE *open_debug_file(const char *path)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0)
        return NULL;
    FILE *fp = fdopen(fd, "wb");
    if (!fp)
        close(fd);
    return fp;
}

const char *usage =
    "Usage:\n %s [options]\n"
    "Options:\n"
    " -i PCM            capture PCM (default)\n"
    " -o PCM            playback PCM (default)\n"
    " -r rate           sample rate (16000)\n"
    " -c channels       recording channels (2)\n"
    " -b size           buffer size (262144)\n"
    " -d delay          system delay between playback and capture (0)\n"
    " -f filter_length  AEC filter length (2048)\n"
    " -s                save audio to /tmp/playback.raw, /tmp/recording.raw and /tmp/out.raw\n"
    " -D                daemonize\n"
    " -h                display this help text\n"
    "Note:\n"
    " Access audio I/O through named pipes (/tmp/ec.input for playback and /tmp/ec.output for recording)\n"
    "  `cat audio.raw > /tmp/ec.input` to play audio\n"
    "  `cat /tmp/ec.output > out.raw` to get recording audio\n"
    " Only support mono playback\n";

volatile sig_atomic_t g_is_quit = 0;

extern int fifo_setup(conf_t *conf);
extern void fifo_cleanup(void);
extern int fifo_write(void *buf, size_t frames);

static void int_handler(int signal)
{
    (void)signal;
    const char msg[] = "Caught signal, quit...\n";
    write(STDOUT_FILENO, msg, sizeof(msg) - 1);

    g_is_quit = 1;
}

int main(int argc, char *argv[])
{
    SpeexEchoState *echo_state;
    int16_t *rec = NULL;
    int16_t *far = NULL;
    int16_t *out = NULL;
    FILE *fp_rec = NULL;
    FILE *fp_far = NULL;
    FILE *fp_out = NULL;

    int opt = 0;
    int delay = 0;
    int save_audio = 0;
    int daemonize = 0;

    conf_t config = {
        .rec_pcm = "default",
        .out_pcm = "default",
        .playback_fifo = "/tmp/ec.input",
        .out_fifo = "/tmp/ec.output",
        .rate = 16000,
        .rec_channels = 2,
        .ref_channels = 1,
        .out_channels = 2,
        .bits_per_sample = 16,
        .buffer_size = 1024 * 16,
        .playback_fifo_size = 1024 * 4,
        .filter_length = 4096,
        .bypass = 1
    };

    while ((opt = getopt(argc, argv, "b:c:d:Df:hi:o:r:s")) != -1)
    {
        switch (opt)
        {
        case 'b':
            config.buffer_size = parse_nonneg(optarg, "b");
            break;
        case 'c':
            config.rec_channels = parse_nonneg(optarg, "c");
            config.out_channels = config.rec_channels;
            break;
        case 'd':
            delay = (int)parse_nonneg(optarg, "d");
            break;
        case 'D':
            daemonize = 1;
            break;
        case 'f':
            config.filter_length = parse_nonneg(optarg, "f");
            break;
        case 'h':
            printf(usage, argv[0]);
            exit(0);
        case 'i':
            config.rec_pcm = optarg;
            break;
        case 'o':
            config.out_pcm = optarg;
            break;
        case 'r':
            config.rate = parse_nonneg(optarg, "r");
            break;
        case 's':
            save_audio = 1;
            break;
        case '?':
            printf("\n");
            printf(usage, argv[0]);
            exit(1);
        default:
            break;
        }
    }

    /* Validate critical parameters */
    if (delay < 0) {
        fprintf(stderr, "Invalid delay: %d\n", delay);
        exit(1);
    }
    if (config.rate == 0 || config.rate > 192000) {
        fprintf(stderr, "Invalid sample rate: %u\n", config.rate);
        exit(1);
    }
    if (config.rec_channels == 0 || config.rec_channels > 32) {
        fprintf(stderr, "Invalid channel count: %u\n", config.rec_channels);
        exit(1);
    }
    if (config.buffer_size == 0) {
        fprintf(stderr, "Invalid buffer size: %u\n", config.buffer_size);
        exit(1);
    }
    if (config.filter_length == 0) {
        fprintf(stderr, "Invalid filter length: %u\n", config.filter_length);
        exit(1);
    }

    if (daemonize)
    {
        pid_t pid, sid;

        /* Fork off the parent process */
        pid = fork();
        if (pid < 0)
        {
            printf("fork() failed\n");
            exit(1);
        }
        /* If we got a good PID, then
           we can exit the parent process. */
        if (pid > 0)
        {
            exit(0);
        }

        /* Change the file mode mask */
        umask(022);  /* Restrict write access for group/others */

        /* Open any logs here */

        /* Create a new SID for the child process */
        sid = setsid();
        if (sid < 0)
        {
            printf("setsid() failed\n");
            exit(1);
        }

        /* Change the current working directory */
        if ((chdir("/")) < 0)
        {
            printf("chdir() failed\n");
            exit(1);
        }

        /* Redirect stdio to /dev/null */
        if (freopen("/dev/null", "r", stdin) == NULL ||
            freopen("/dev/null", "w", stdout) == NULL ||
            freopen("/dev/null", "w", stderr) == NULL)
        {
            exit(1);
        }
    }

    int frame_size = config.rate * 10 / 1000; // 10 ms

    if (save_audio)
    {
        fp_far = open_debug_file("/tmp/playback.raw");
        fp_rec = open_debug_file("/tmp/recording.raw");
        fp_out = open_debug_file("/tmp/out.raw");

        if (fp_far == NULL || fp_rec == NULL || fp_out == NULL)
        {
            printf("Fail to open file(s)\n");
            if (fp_far) fclose(fp_far);
            if (fp_rec) fclose(fp_rec);
            if (fp_out) fclose(fp_out);
            exit(1);
        }
    }

    rec = (int16_t *)calloc(frame_size * config.rec_channels, sizeof(int16_t));
    far = (int16_t *)calloc(frame_size * config.ref_channels, sizeof(int16_t));
    out = (int16_t *)calloc(frame_size * config.out_channels, sizeof(int16_t));

    if (rec == NULL || far == NULL || out == NULL)
    {
        printf("Fail to allocate memory\n");
        exit(1);
    }

    // Configures signal handling.
    struct sigaction sig_int_handler;
    sig_int_handler.sa_handler = int_handler;
    sigemptyset(&sig_int_handler.sa_mask);
    sig_int_handler.sa_flags = 0;
    sigaction(SIGINT, &sig_int_handler, NULL);
    sigaction(SIGTERM, &sig_int_handler, NULL);
    // systemctl stop sends SIGTERM; without this the service waits for
    // TimeoutStopSec then gets SIGKILL'd, leaving FIFO and ALSA state dirty.
    signal(SIGPIPE, SIG_IGN);

    echo_state = speex_echo_state_init_mc(frame_size,
                                          config.filter_length,
                                          config.rec_channels,
                                          config.ref_channels);
    if (echo_state == NULL) {
        fprintf(stderr, "Failed to initialize Speex echo canceller\n");
        exit(1);
    }
    spx_int32_t sr = (spx_int32_t)config.rate;
    speex_echo_ctl(echo_state, SPEEX_ECHO_SET_SAMPLING_RATE, &sr);

    if (playback_start(&config) < 0) {
        fprintf(stderr, "Failed to start playback\n");
        exit(1);
    }
    if (capture_start(&config) < 0) {
        fprintf(stderr, "Failed to start capture\n");
        exit(1);
    }
    if (fifo_setup(&config) < 0) {
        fprintf(stderr, "Failed to setup FIFO\n");
        exit(1);
    }

    printf("Running... Press Ctrl+C to exit\n");

    int timeout = 200 * 1000 * frame_size / config.rate;    // ms

    // system delay between recording and playback
    int skipped = capture_skip(delay, timeout);
    printf("skip frames %d\n", skipped);

    time_t last_short_warn = 0;
    unsigned int short_write_count = 0;

    while (!g_is_quit)
    {
        if (capture_read(rec, frame_size, timeout) < 0) {
            // Drain one playback frame even on capture stall so the playback
            // ringbuffer doesn't monotonically grow and drift far/rec alignment.
            (void)playback_read(far, frame_size, timeout);
            continue;
        }
        if (playback_read(far, frame_size, timeout) < 0)
            memset(far, 0, frame_size * config.ref_channels * sizeof(int16_t));

        if (!atomic_load(&config.bypass))
        {
            speex_echo_cancellation(echo_state, rec, far, out);
        }
        else
        {
            memcpy(out, rec, frame_size * config.rec_channels * config.bits_per_sample / 8);
        }

        if (save_audio)
        {
            fwrite(rec, 2, frame_size * config.rec_channels, fp_rec);
            fwrite(far, 2, frame_size * config.ref_channels, fp_far);
            fwrite(out, 2, frame_size * config.out_channels, fp_out);
        }

        int written = fifo_write(out, frame_size);
        if (written < (int)frame_size) {
            // Ring-buffer overrun — FIFO reader is too slow. Log rate-limited
            // (every 5s) so the drop is observable during tuning without spam.
            short_write_count += (frame_size - written);
            time_t now = time(NULL);
            if (now - last_short_warn >= 5) {
                fprintf(stderr, "fifo_write: %u frames dropped in last 5s (reader too slow?)\n",
                        short_write_count);
                last_short_warn = now;
                short_write_count = 0;
            }
        }
    }

    if (save_audio)
    {
        fclose(fp_rec);
        fclose(fp_far);
        fclose(fp_out);
    }

    free(rec);
    free(far);
    free(out);

    speex_echo_state_destroy(echo_state);

    capture_stop();
    playback_stop();
    fifo_cleanup();

    return 0;
}
