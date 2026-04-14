// ec_webrtc — WebRTC AEC for WM8960 Audio HAT (loopback router design)
//
// The EC binary acts as the audio router between applications and hardware:
//
//   App plays to hw:Loopback,0,0 → (loopback) → EC reads hw:Loopback,1,0
//   EC writes to speaker (hw) + feeds AEC reference (same data, zero delay)
//   EC reads from mic (dsnoop) → AEC removes echo → writes hw:Loopback,0,1
//   App records from hw:Loopback,1,1 → gets echo-cancelled audio
//
// No FIFOs, no ring buffers, no ALSA multi/route plugins in the audio path.
// Reference signal is perfectly aligned because the EC binary controls both
// the speaker output and the AEC input in the same thread.
//
// Requires: snd-aloop kernel module, libwebrtc-audio-processing-1
// License: GPLv3

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <csignal>
#include <cerrno>
#include <unistd.h>
#include <sys/stat.h>

#include <alsa/asoundlib.h>
#include <modules/audio_processing/include/audio_processing.h>

static const char *usage_text =
    "Usage:\n %s [options]\n"
    "\n"
    "ALSA devices:\n"
    " -i PCM    app input loopback  (hw:Loopback,1,0)\n"
    " -o PCM    app output loopback (hw:Loopback,0,1)\n"
    " -m PCM    mic capture device  (dsnooper)\n"
    " -p PCM    speaker output      (plughw:ahub0wm8960,0)\n"
    "\n"
    "Audio processing:\n"
    " -r rate   sample rate: 16000, 32000, or 48000 (48000)\n"
    " -n level  noise suppression: 0=off 1=low 2=mod 3=high 4=vhigh (1)\n"
    " -g        enable automatic gain control\n"
    " -M        mobile mode (AECM — lighter CPU, less cancellation)\n"
    " -H        disable high-pass filter\n"
    " -d ms     stream delay hint in ms (0)\n"
    "\n"
    "Other:\n"
    " -s        save debug audio to /tmp/{recording,playback,out}.raw\n"
    " -D        daemonize\n"
    " -h        show this help\n"
    "\n"
    "Applications play to hw:Loopback,0,0 and record from hw:Loopback,1,1.\n"
    "Requires snd-aloop kernel module: modprobe snd-aloop\n";

static volatile sig_atomic_t g_quit = 0;
static void signal_handler(int) { g_quit = 1; }

static int alsa_set_params(snd_pcm_t *handle, unsigned rate, unsigned channels)
{
    int err;
    snd_pcm_hw_params_t *hw;
    snd_pcm_hw_params_alloca(&hw);
    snd_pcm_hw_params_any(handle, hw);
    if ((err = snd_pcm_hw_params_set_access(handle, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0) {
        fprintf(stderr, "ALSA set_access failed: %s\n", snd_strerror(err));
        return -1;
    }
    if ((err = snd_pcm_hw_params_set_format(handle, hw, SND_PCM_FORMAT_S16_LE)) < 0) {
        fprintf(stderr, "ALSA set_format failed: %s\n", snd_strerror(err));
        return -1;
    }
    unsigned actual = rate;
    snd_pcm_hw_params_set_rate_near(handle, hw, &actual, 0);
    if (actual != rate) fprintf(stderr, "Warning: rate %u → %u\n", rate, actual);
    if ((err = snd_pcm_hw_params_set_channels(handle, hw, channels)) < 0) {
        fprintf(stderr, "ALSA set_channels %u failed: %s\n", channels, snd_strerror(err));
        return -1;
    }
    snd_pcm_uframes_t period = rate / 100;  // 10ms
    snd_pcm_hw_params_set_period_size_near(handle, hw, &period, 0);
    snd_pcm_uframes_t buffer = period * 4;
    snd_pcm_hw_params_set_buffer_size_near(handle, hw, &buffer);
    err = snd_pcm_hw_params(handle, hw);
    if (err < 0) {
        fprintf(stderr, "ALSA hw_params failed: %s\n", snd_strerror(err));
        return -1;
    }
    return 0;
}

static void alsa_recover(snd_pcm_t *h, int err)
{
    if (err == -EPIPE) {
        if (snd_pcm_prepare(h) < 0)
            fprintf(stderr, "alsa_recover: prepare failed after underrun\n");
    } else if (err == -ESTRPIPE) {
        while (snd_pcm_resume(h) == -EAGAIN) usleep(10000);
        if (snd_pcm_prepare(h) < 0)
            fprintf(stderr, "alsa_recover: prepare failed after suspend\n");
    }
}

int main(int argc, char *argv[])
{
    // Default device names
    const char *app_in  = "hw:Loopback,1,0";
    const char *app_out = "hw:Loopback,0,1";
    const char *mic_dev = "dsnooper";
    const char *spk_dev = "plughw:ahub0wm8960,0";

    // Processing options
    unsigned rate = 48000;
    int ns_level = 1;
    int agc = 0;
    int mobile_mode = 0;
    int highpass = 1;
    int delay_ms = 0;
    int save = 0;
    int daemon_mode = 0;

    int opt;
    while ((opt = getopt(argc, argv, "i:o:m:p:r:n:d:gMHsDh")) != -1) {
        switch (opt) {
        case 'i': app_in = optarg; break;
        case 'o': app_out = optarg; break;
        case 'm': mic_dev = optarg; break;
        case 'p': spk_dev = optarg; break;
        case 'r': rate = atoi(optarg); break;
        case 'n': ns_level = atoi(optarg); break;
        case 'd': delay_ms = atoi(optarg); break;
        case 'g': agc = 1; break;
        case 'M': mobile_mode = 1; break;
        case 'H': highpass = 0; break;
        case 's': save = 1; break;
        case 'D': daemon_mode = 1; break;
        case 'h': printf(usage_text, argv[0]); return 0;
        default:  printf(usage_text, argv[0]); return 1;
        }
    }

    // Validate rate
    if (rate != 16000 && rate != 32000 && rate != 48000) {
        fprintf(stderr, "Invalid rate %u — must be 16000, 32000, or 48000\n", rate);
        return 1;
    }

    if (daemon_mode) {
        pid_t pid = fork();
        if (pid < 0) { perror("fork"); return 1; }
        if (pid > 0) return 0;
        umask(022);
        setsid();
        if (chdir("/") < 0) { perror("chdir"); return 1; }
        if (!freopen("/dev/null", "r", stdin) ||
            !freopen("/dev/null", "w", stdout) ||
            !freopen("/dev/null", "w", stderr)) {
            return 1;
        }
    }

    unsigned frame_size = rate / 100;  // 10ms frames

    // Signal handling
    struct sigaction sa = {};
    sa.sa_handler = signal_handler;
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);

    // Open 4 ALSA devices
    snd_pcm_t *pcm_app_in = nullptr;
    snd_pcm_t *pcm_app_out = nullptr;
    snd_pcm_t *pcm_mic = nullptr;
    snd_pcm_t *pcm_spk = nullptr;

    int err;
    err = snd_pcm_open(&pcm_app_in, app_in, SND_PCM_STREAM_CAPTURE, 0);
    if (err < 0) { fprintf(stderr, "app_in %s: %s\n", app_in, snd_strerror(err)); return 1; }

    err = snd_pcm_open(&pcm_app_out, app_out, SND_PCM_STREAM_PLAYBACK, 0);
    if (err < 0) { fprintf(stderr, "app_out %s: %s\n", app_out, snd_strerror(err)); goto fail1; }

    err = snd_pcm_open(&pcm_mic, mic_dev, SND_PCM_STREAM_CAPTURE, 0);
    if (err < 0) { fprintf(stderr, "mic %s: %s\n", mic_dev, snd_strerror(err)); goto fail2; }

    err = snd_pcm_open(&pcm_spk, spk_dev, SND_PCM_STREAM_PLAYBACK, 0);
    if (err < 0) { fprintf(stderr, "spk %s: %s\n", spk_dev, snd_strerror(err)); goto fail3; }

    // Loopback: mono. Mic: stereo (dsnoop). Speaker: stereo.
    if (alsa_set_params(pcm_app_in, rate, 1) < 0 ||
        alsa_set_params(pcm_app_out, rate, 1) < 0 ||
        alsa_set_params(pcm_mic, rate, 2) < 0 ||
        alsa_set_params(pcm_spk, rate, 2) < 0) goto fail4;

    {
    // Create WebRTC Audio Processing Module
    webrtc::AudioProcessing *apm = webrtc::AudioProcessingBuilder().Create();
    if (!apm) { fprintf(stderr, "WebRTC AudioProcessing init failed\n"); goto fail4; }

    // Configure processing
    webrtc::AudioProcessing::Config cfg;
    cfg.echo_canceller.enabled = true;
    cfg.echo_canceller.mobile_mode = (mobile_mode != 0);
    cfg.high_pass_filter.enabled = (highpass != 0);
    cfg.gain_controller2.enabled = (agc != 0);

    if (ns_level > 0) {
        cfg.noise_suppression.enabled = true;
        cfg.noise_suppression.analyze_linear_aec_output_when_available = true;
        switch (ns_level) {
        case 1:  cfg.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kLow; break;
        case 2:  cfg.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kModerate; break;
        case 3:  cfg.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kHigh; break;
        default: cfg.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kVeryHigh; break;
        }
    }
    apm->ApplyConfig(cfg);
    webrtc::StreamConfig mono_cfg(rate, 1);

    // Allocate buffers
    int16_t *ref_buf     = (int16_t *)calloc(frame_size, sizeof(int16_t));
    int16_t *ref_aec     = (int16_t *)calloc(frame_size, sizeof(int16_t));
    int16_t *spk_stereo  = (int16_t *)calloc(frame_size * 2, sizeof(int16_t));
    int16_t *mic_stereo  = (int16_t *)calloc(frame_size * 2, sizeof(int16_t));
    int16_t *mic_mono    = (int16_t *)calloc(frame_size, sizeof(int16_t));
    int16_t *out_buf     = (int16_t *)calloc(frame_size, sizeof(int16_t));
    if (!ref_buf || !ref_aec || !spk_stereo || !mic_stereo || !mic_mono || !out_buf) {
        fprintf(stderr, "Buffer allocation failed\n");
        free(ref_buf); free(ref_aec); free(spk_stereo);
        free(mic_stereo); free(mic_mono); free(out_buf);
        delete apm;
        goto fail4;
    }

    // Debug files
    FILE *fp_rec = nullptr, *fp_far = nullptr, *fp_out = nullptr;
    if (save) {
        fp_rec = fopen("/tmp/recording.raw", "wb");
        fp_far = fopen("/tmp/playback.raw", "wb");
        fp_out = fopen("/tmp/out.raw", "wb");
        if (!fp_rec || !fp_far || !fp_out) {
            fprintf(stderr, "Warning: failed to open debug files, disabling debug recording\n");
            if (fp_rec) fclose(fp_rec);
            if (fp_far) fclose(fp_far);
            if (fp_out) fclose(fp_out);
            fp_rec = fp_far = fp_out = nullptr;
        }
    }

    printf("WebRTC AEC — %s mode\n", mobile_mode ? "AECM (mobile)" : "AEC3");
    printf("NS=%d AGC=%s HPF=%s rate=%u delay=%dms\n",
           ns_level, agc ? "on" : "off", highpass ? "on" : "off", rate, delay_ms);
    printf("App→ %s  Speaker→ %s  Mic← %s  App← %s\n",
           app_in, spk_dev, mic_dev, app_out);
    printf("Running... Ctrl+C to exit\n");

    // Pre-fill speaker with silence to start the stream
    memset(spk_stereo, 0, frame_size * 2 * sizeof(int16_t));
    for (int i = 0; i < 4; i++)
        snd_pcm_writei(pcm_spk, spk_stereo, frame_size);

    // The mic (dsnoop) drives the loop timing — it always has data at a
    // steady rate. The loopback reference is read non-blocking so it
    // doesn't stall the mic reads and cause temporal misalignment.
    snd_pcm_nonblock(pcm_app_in, 1);

    while (!g_quit)
    {
        // 1. Read mic (stereo from dsnoop → mono downmix)
        ssize_t mr = snd_pcm_readi(pcm_mic, mic_stereo, frame_size);
        if (mr < 0) {
            alsa_recover(pcm_mic, mr);
            mr = snd_pcm_readi(pcm_mic, mic_stereo, frame_size);
            if (mr < 0) {
                memset(mic_stereo, 0, frame_size * 2 * sizeof(int16_t));
                mr = 0;
            }
        }
        // Zero-fill on short read to avoid processing stale data
        if (mr > 0 && (unsigned)mr < frame_size)
            memset(mic_stereo + mr * 2, 0, (frame_size - mr) * 2 * sizeof(int16_t));
        for (unsigned i = 0; i < frame_size; i++)
            mic_mono[i] = (mic_stereo[i * 2] + mic_stereo[i * 2 + 1]) / 2;

        // 2. Read loopback reference (non-blocking)
        ssize_t ar = snd_pcm_readi(pcm_app_in, ref_buf, frame_size);
        if (ar < 0) {
            memset(ref_buf, 0, frame_size * sizeof(int16_t));
            if (ar != -EAGAIN) alsa_recover(pcm_app_in, ar);
        }

        // 3. Feed reference to AEC (copy — speaker gets unmodified audio)
        memcpy(ref_aec, ref_buf, frame_size * sizeof(int16_t));
        apm->ProcessReverseStream(ref_aec, mono_cfg, mono_cfg, ref_aec);

        // 4. Write to speaker (mono → stereo duplication)
        for (unsigned i = 0; i < frame_size; i++) {
            spk_stereo[i * 2]     = ref_buf[i];
            spk_stereo[i * 2 + 1] = ref_buf[i];
        }
        ssize_t sw = snd_pcm_writei(pcm_spk, spk_stereo, frame_size);
        if (sw < 0) {
            alsa_recover(pcm_spk, sw);
            snd_pcm_writei(pcm_spk, spk_stereo, frame_size);
        }

        // 5. Process mic through AEC
        apm->set_stream_delay_ms(delay_ms);
        apm->ProcessStream(mic_mono, mono_cfg, mono_cfg, out_buf);

        // 6. Write processed audio to output loopback
        ssize_t ow = snd_pcm_writei(pcm_app_out, out_buf, frame_size);
        if (ow < 0) {
            alsa_recover(pcm_app_out, ow);
            snd_pcm_writei(pcm_app_out, out_buf, frame_size);
        }

        // 7. Debug files
        if (fp_rec) {
            fwrite(mic_mono, sizeof(int16_t), frame_size, fp_rec);
            fwrite(ref_buf, sizeof(int16_t), frame_size, fp_far);
            fwrite(out_buf, sizeof(int16_t), frame_size, fp_out);
        }
    }

    // Normal cleanup after successful run
    if (fp_rec) { fclose(fp_rec); fclose(fp_far); fclose(fp_out); }
    free(ref_buf);
    free(ref_aec);
    free(spk_stereo);
    free(mic_stereo);
    free(mic_mono);
    free(out_buf);
    delete apm;
    }

    snd_pcm_close(pcm_spk);
    snd_pcm_close(pcm_mic);
    snd_pcm_close(pcm_app_out);
    snd_pcm_close(pcm_app_in);
    return 0;

fail4: snd_pcm_close(pcm_spk);
fail3: snd_pcm_close(pcm_mic);
fail2: snd_pcm_close(pcm_app_out);
fail1: snd_pcm_close(pcm_app_in);
    return 1;
}
