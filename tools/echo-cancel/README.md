# WM8960 Echo Canceller (Bare ALSA)

Standalone acoustic echo cancellation for the WM8960 Audio HAT, using SpeexDSP. Works directly with ALSA — no PipeWire or PulseAudio required.

Based on [voice-engine/ec](https://github.com/voice-engine/ec) (GPLv3), maintained as part of the WM8960 Audio HAT project.

## When to Use This

Use this if you're running **bare ALSA** (no PipeWire or PulseAudio) and need echo cancellation — e.g., classic Rhasspy, custom voice assistant pipelines, or intercom applications.

If you have PipeWire or PulseAudio, use the WebRTC AEC configs in [`configs/`](../../configs/README.md#echo-cancellation-setup) instead — they provide better echo cancellation (~40dB vs ~20-30dB) with no background daemon.

## How It Works

The echo canceller runs as a background daemon that:

1. **Captures** audio from the WM8960 microphone
2. **Plays** audio from a named pipe (`/tmp/ec.input`) to the WM8960 speaker
3. **Subtracts** the played audio from the captured signal using SpeexDSP AEC
4. **Outputs** echo-cancelled audio to a named pipe (`/tmp/ec.output`)

Applications read from `/tmp/ec.output` for echo-free microphone audio, and write to `/tmp/ec.input` for playback.

## Install

```bash
cd tools/echo-cancel
sudo ./install.sh
```

This will:
- Install build dependencies (`libasound2-dev`, `libspeexdsp-dev`, `build-essential`)
- Build the `wm8960-ec` binary from source
- Install it to `/usr/local/bin/wm8960-ec`
- Create and start a systemd service (`wm8960-echo-cancel`)

## Usage

### Record echo-cancelled audio

```bash
# Record 5 seconds of echo-cancelled audio at 16kHz
cat /tmp/ec.output | arecord -r 16000 -c 2 -f S16_LE -t wav -d 5 recording.wav
```

### Play audio through the echo canceller

```bash
# Play a WAV file (must be 16kHz, mono, S16_LE raw PCM)
sox input.wav -r 16000 -c 1 -b 16 -e signed -t raw - > /tmp/ec.input

# Or use ffmpeg
ffmpeg -i input.wav -ar 16000 -ac 1 -f s16le - > /tmp/ec.input
```

### Voice assistant integration

Configure your voice assistant to use the named pipes:
- **Microphone input:** `/tmp/ec.output` (echo-cancelled)
- **Speaker output:** `/tmp/ec.input` (routed through AEC)

### Service management

```bash
# Check status
systemctl status wm8960-echo-cancel

# View logs
journalctl -u wm8960-echo-cancel -f

# Restart
sudo systemctl restart wm8960-echo-cancel

# Stop
sudo systemctl stop wm8960-echo-cancel
```

## Tuning

### Delay compensation (`-d` flag)

The `-d` parameter (in milliseconds) compensates for the time between when audio is sent to the speaker and when it arrives at the microphone. Default is 200ms for the ReSpeaker 2-Mic HAT.

If echo cancellation seems weak:
- **Too much residual echo:** increase the delay value
- **Audio sounds choppy or cuts out:** decrease the delay value

### Filter length (`-f` flag)

The `-f` parameter controls the AEC filter length in samples. Default is 4096 (256ms at 16kHz). Longer filters handle more reverberant rooms but use more CPU. Range: 1024–8192.

## Limitations

- **16kHz sample rate only** — SpeexDSP AEC works at 16kHz. Fine for voice assistants (Whisper, Rhasspy, etc.) but not for music.
- **Mono playback** — the echo canceller accepts mono playback input through the FIFO.
- **~20-30dB echo attenuation** — good for wake word detection and STT, but not as strong as WebRTC AEC (~40dB). For better cancellation, use PipeWire or PulseAudio.
- **Requires tuning** — the delay parameter needs to match your specific setup.

## Uninstall

```bash
cd tools/echo-cancel
sudo ./install.sh --uninstall
```

## License

GPLv3 — see [LICENSE-GPL3](LICENSE-GPL3). Based on [voice-engine/ec](https://github.com/voice-engine/ec).

The PortAudio ring buffer (`pa_ringbuffer.c`, `pa_ringbuffer.h`) is licensed under a BSD-style license — see the file headers for details.
