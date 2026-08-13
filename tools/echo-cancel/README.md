# WM8960 Echo Canceller (Bare ALSA)

Acoustic echo cancellation for the WM8960 Audio HAT without PipeWire or PulseAudio. Two engines available:

| Engine | Attenuation | Double-talk | Requirements | Best for |
|--------|-------------|-------------|-------------|----------|
| **WebRTC AEC3** (default) | ~30dB+ | Excellent | snd-aloop module | Voice assistants, conferencing |
| **SpeexDSP** | ~15dB | Fair | None | Wake-word detection, simple setups |

For PipeWire or PulseAudio users, use the WebRTC AEC configs in [`configs/`](../../configs/README.md#echo-cancellation-setup) instead.

## Install

```bash
cd tools/echo-cancel

# WebRTC AEC3 (recommended — best quality)
sudo ./install.sh

# Or SpeexDSP (simpler, no snd-aloop needed)
sudo ./install.sh speex
```

The installer handles all dependencies, builds from source, installs the binary, and creates a systemd service.

## How It Works

### WebRTC AEC3 (default)

The EC binary acts as the audio router between applications and hardware:

```text
App plays to hw:Loopback,0,0
  → (snd-aloop) → EC reads from hw:Loopback,1,0
  → EC feeds reference to WebRTC AEC3
  → EC writes to WM8960 speaker
  → EC reads from WM8960 mic (dsnoop)
  → WebRTC AEC3 removes echo
  → EC writes to hw:Loopback,0,1
  → (snd-aloop) → App records from hw:Loopback,1,1 (clean audio)
```

No FIFOs in the audio path. Single-threaded loop ensures the reference signal is perfectly aligned with the microphone capture.

### SpeexDSP (legacy)

Based on [voice-engine/ec](https://github.com/voice-engine/ec). Uses named pipes (`/tmp/ec.input`, `/tmp/ec.output`) for audio I/O with SpeexDSP for echo cancellation.

## Usage

### WebRTC

> **Important:** When the WebRTC echo canceller is running, it has exclusive access to the WM8960 speaker. All audio playback and recording **must** go through the loopback devices, not `default` or `hw:ahub0wm8960`.

```bash
# Play audio (goes through EC → speaker)
aplay -D hw:Loopback,0,0 music.wav

# Record echo-cancelled audio
arecord -D hw:Loopback,1,1 -r 48000 -c 1 -f S16_LE -d 5 recording.wav

# Play back a recording (also through loopback)
aplay -D hw:Loopback,0,0 recording.wav
```

Configure your voice assistant to use:
- **Playback device:** `hw:Loopback,0,0`
- **Capture device:** `hw:Loopback,1,1`
- **Format:** 48000 Hz, mono, S16_LE (most assistants negotiate automatically)

### SpeexDSP

```bash
# Record echo-cancelled audio
timeout 5 sox -t raw -r 48000 -c 1 -b 16 -e signed /tmp/ec.output -t wav recording.wav

# Play audio through the echo canceller (raw 48kHz mono S16_LE)
sox input.wav -r 48000 -c 1 -b 16 -e signed -t raw - > /tmp/ec.input
```

### WebRTC Tuning Flags

```text
-n level  Noise suppression: 0=off 1=low 2=mod 3=high 4=vhigh (default: 1)
-g        Enable automatic gain control
-M        Mobile mode (AECM — lighter CPU, less cancellation)
-H        Disable high-pass filter
-d ms     Stream delay hint in ms (default: 0)
-r rate   Sample rate: 16000, 32000, or 48000 (default: 48000)
```

### SpeexDSP Tuning Flags

```text
-r rate   Sample rate (binary default: 16000, service uses 48000)
-c ch     Recording channels (binary default: 2, service uses 1)
-d delay  Delay compensation in frames (default: 0)
-f length AEC filter length in samples (default: 4096, range: 1024-8192)
-b size   Ring buffer size (default: 16384)
-s        Save debug audio to /tmp/*.raw
-D        Daemonize
```

The installed systemd service runs with `-r 48000 -c 1` to match the WM8960 hardware. The most useful tuning parameter is `-f` (filter length). Larger values handle more reverberant rooms but use more CPU. Default 4096 = 85ms at 48kHz.

### Service Management

```bash
systemctl status wm8960-echo-cancel
systemctl restart wm8960-echo-cancel
journalctl -u wm8960-echo-cancel -f
```

## Limitations

- **WebRTC AEC3 performs best with broadband signals** (speech, music, noise). Pure tones (beeps, single-frequency alerts) may not be fully cancelled due to AEC3's transparent mode detection.
- **WebRTC requires snd-aloop** kernel module, built automatically via DKMS by the installer.
- **WebRTC takes exclusive access** to the WM8960 speaker while running. All playback must go through the loopback device.
- **SpeexDSP provides ~15dB attenuation** — adequate for wake-word detection but noticeable echo remains.
- **SpeexDSP may attenuate speech** along with echo during simultaneous playback.

## Uninstall

```bash
sudo ./install.sh --uninstall
```

## License

GPLv3 — see [LICENSE-GPL3](LICENSE-GPL3). SpeexDSP engine based on [voice-engine/ec](https://github.com/voice-engine/ec); WebRTC engine is GPLv3 by our choice for consistency within this directory.

The PortAudio ring buffer (`pa_ringbuffer.c`, `pa_ringbuffer.h`, `pa_memorybarrier.h`) is vendored from [PortAudio](http://www.portaudio.com) under a BSD-style license — see the file headers for details. These files are kept close to upstream to preserve compatibility.

For the authoritative per-component breakdown and compatibility notes across the whole repo (MIT for repo glue, GPL-2.0-only for the DKMS kernel module, GPLv3 here), see [../../docs/LICENSING.md](../../docs/LICENSING.md).
