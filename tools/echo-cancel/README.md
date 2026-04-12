# WM8960 Echo Canceller (Bare ALSA) — Experimental

Standalone acoustic echo cancellation for the WM8960 Audio HAT, using SpeexDSP. Works directly with ALSA — no PipeWire or PulseAudio required.

Based on [voice-engine/ec](https://github.com/voice-engine/ec) (GPLv3), maintained as part of the WM8960 Audio HAT project.

> **Note:** This provides ~15dB of echo attenuation — enough to help with wake-word detection but not full echo removal. For better results (~40dB), use the PipeWire or PulseAudio WebRTC AEC configs in [`configs/`](../../configs/README.md#echo-cancellation-setup).

## When to Use This

Use this if you're running **bare ALSA** (no PipeWire or PulseAudio) and need basic echo reduction — e.g., classic Rhasspy wake-word detection, or as a starting point for custom voice pipelines.

If you have PipeWire or PulseAudio, use the WebRTC AEC configs instead — they provide significantly better echo cancellation with no background daemon.

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

The output pipe `/tmp/ec.output` delivers raw S16_LE PCM at 48kHz mono. Use `sox` or `ffmpeg` to convert it to WAV (or any other format):

```bash
# Using sox — reads raw PCM from the pipe and writes WAV
timeout 5 sox -t raw -r 48000 -c 1 -b 16 -e signed /tmp/ec.output -t wav recording.wav

# Or using ffmpeg
timeout 5 ffmpeg -f s16le -ar 48000 -ac 1 -i /tmp/ec.output -t 5 recording.wav

# Or just dump raw and convert later
dd if=/tmp/ec.output of=recording.raw bs=96000 count=5
sox -t raw -r 48000 -c 1 -b 16 -e signed recording.raw recording.wav
```

### Play audio through the echo canceller

```bash
# Play a WAV file (must be converted to raw 48kHz mono S16_LE PCM first)
sox input.wav -r 48000 -c 1 -b 16 -e signed -t raw - > /tmp/ec.input

# Or use ffmpeg
ffmpeg -i input.wav -ar 48000 -ac 1 -f s16le - > /tmp/ec.input
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

- **~15dB echo attenuation** — reduces echo enough to help wake-word engines, but the played audio is still audible in recordings. For near-complete echo removal, use PipeWire or PulseAudio WebRTC AEC (~40dB).
- **Mono capture and playback** — the echo canceller operates in mono for both directions.
- **48kHz sample rate** — matches the WM8960 hardware rate. Runs through the ALSA `default` device (dmix/dsnoop).
- **May attenuate speech** — the SpeexDSP filter can reduce voice volume along with echo, especially at similar levels. This is a known limitation of the algorithm.

## Uninstall

```bash
cd tools/echo-cancel
sudo ./install.sh --uninstall
```

## License

GPLv3 — see [LICENSE-GPL3](LICENSE-GPL3). Based on [voice-engine/ec](https://github.com/voice-engine/ec).

The PortAudio ring buffer (`pa_ringbuffer.c`, `pa_ringbuffer.h`, `pa_memorybarrier.h`) is vendored from [PortAudio](http://www.portaudio.com) under a BSD-style license — see the file headers for details. These files are kept unmodified to preserve upstream compatibility.
