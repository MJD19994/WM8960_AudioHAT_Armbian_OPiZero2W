# WM8960 Audio HAT Drivers for Armbian (Orange Pi Zero 2W)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/MJD19994/WM8960_AudioHAT_Armbian_OPiZero2W)](https://github.com/MJD19994/WM8960_AudioHAT_Armbian_OPiZero2W/releases)
[![CI](https://github.com/MJD19994/WM8960_AudioHAT_Armbian_OPiZero2W/actions/workflows/ci.yml/badge.svg)](https://github.com/MJD19994/WM8960_AudioHAT_Armbian_OPiZero2W/actions/workflows/ci.yml)
![Orange Pi Zero 2W](https://img.shields.io/badge/Orange%20Pi%20Zero%202W-supported-success?style=flat-square)
![Kernel 6.12](https://img.shields.io/badge/kernel-6.12%20validated-2ea44f?style=flat-square)
![Kernel 6.18](https://img.shields.io/badge/kernel-6.18%20validated-2ea44f?style=flat-square)
![DKMS](https://img.shields.io/badge/DKMS-supported-yellow?style=flat-square)
![ALSA](https://img.shields.io/badge/ALSA-integrated-blue?style=flat-square)
![PulseAudio](https://img.shields.io/badge/PulseAudio-supported-blue?style=flat-square)
![PipeWire](https://img.shields.io/badge/PipeWire-supported-blue?style=flat-square)
![ReSpeaker](https://img.shields.io/badge/ReSpeaker%202--Mic-compatible-1f6feb?style=flat-square)
![Waveshare](https://img.shields.io/badge/Waveshare%20WM8960-compatible-1f6feb?style=flat-square)
![Seeed Studio](https://img.shields.io/badge/Seeed%20Studio-compatible-1f6feb?style=flat-square)

Complete audio support for WM8960-based audio HATs (including ReSpeaker 2-Mic HAT) on the Orange Pi Zero 2W running Armbian.

## Features

- Full WM8960 codec support via DKMS (auto-builds for your kernel)
- Stereo audio playback through headphones and/or speaker
- Stereo audio recording from onboard microphones
- Simultaneous headphone and speaker output
- Automatic DKMS module rebuild on kernel upgrades
- Complete mixer configuration (all WM8960 controls set to known defaults)
- Named mixer profiles: voice, music, headphones, conferencing, recording
- Multi-application audio support (dmix/dsnoop)
- ALSA device aliases: `wm8960_voice`, `wm8960_music`, `wm8960_record`
- PulseAudio and PipeWire integration (auto-detected)
- Echo cancellation support (WebRTC AEC3 ~30dB+, SpeexDSP ~15dB)
- Hardware ALC, Noise Gate, and 3D Enhancement controls exposed

## Hardware Compatibility

**Tested on:**
- Orange Pi Zero 2W (Allwinner H618)
- ReSpeaker 2-Mic Pi HAT (Seeed Studio / Keyestudio)
- Waveshare WM8960 Audio HAT

**Supported OS:**
- [Armbian Trixie (kernel 6.12–6.18+, current-sunxi64)](https://www.armbian.com/orangepi-zero2w/)

**Requirements:**
- All prerequisites (I2C tools, device-tree-compiler, ALSA utils, DKMS, kernel headers, build tools) are installed automatically by the installer

## Quick Start

### Update Your System

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git    # Armbian may not include git by default
```

### Installation

```bash
git clone https://github.com/MJD19994/WM8960_AudioHAT_Armbian_OPiZero2W
cd WM8960_AudioHAT_Armbian_OPiZero2W
sudo ./install.sh
sudo reboot
```

The installer:
- Installs kernel headers from apt, then builds the WM8960 module via DKMS
- Patches the device tree with the WM8960 overlay
- Installs the mixer configuration service and ALSA config
- Auto-detects and configures PulseAudio or PipeWire if installed

### Testing Audio

After reboot, run the interactive test script:

```bash
# Full interactive test (diagnostics + playback + recording tests)
cd WM8960_AudioHAT_Armbian_OPiZero2W
sudo ./scripts/test-audio.sh
```

```bash
# Diagnostics only (no interactive prompts — useful for debugging)
sudo ./scripts/test-audio.sh --diagnostics-only
```

Or test manually:

```bash
# List audio devices (find the card number for ahub0wm8960)
aplay -l

# Test with speaker-test (using card name)
speaker-test -D plughw:ahub0wm8960,0 -c 2 -r 48000 -t sine -f 1000 -l 2

# Or use the default device (configured in asound.conf)
speaker-test -c 2 -r 48000 -t sine -f 1000 -l 2

# Test recording (5 seconds)
arecord -D plughw:ahub0wm8960,0 -r 48000 -c 2 -f S16_LE -t wav -d 5 test.wav

# Playback recording
aplay -D plughw:ahub0wm8960,0 test.wav
```

**Note:** The WM8960 appears as **ahub0wm8960** sound card (typically card 0 on Armbian). Use the card name or `-D default` for portability.

## How It Works

### The Problem

The Armbian kernel does not include a WM8960 codec driver. Without it, the codec is detected on I2C but produces no audio.

### The Solution

This package provides:

1. **Device Tree Patching** (`overlays/`)
   - Compiled and applied to the base DTB at install time using `fdtoverlay`
   - Configures I2S0 pins (BCLK, LRCK, DOUT, DIN)
   - Sets up AHUB audio subsystem
   - Enables I2C1 and declares WM8960 codec at address 0x1a
   - Enables AHUB DAM register space and I2C pin muxing (required on Armbian)

2. **DKMS Kernel Module** (`dkms/`)
   - Patched WM8960 codec driver built via DKMS against your running kernel
   - Automatically rebuilds on kernel upgrades
   - Includes PLL fixes for proper clock generation from onboard 24MHz crystal
   - Automatic CCU PLL workaround for kernel 6.13+ (detects and corrects a PLL lock regression in the Allwinner clock driver)

3. **Mixer Configuration Service** (`service/wm8960-mixer-config.sh`)
   - Runs at boot via systemd
   - Configures all WM8960 mixer controls to known defaults (playback routing, capture path, DAC/ADC settings, ALC, Noise Gate, 3D Enhancement, zero-cross detection)
   - Restores saved mixer state on subsequent boots (via `alsactl`)

4. **ALSA Configuration** (`configs/asound.conf`)
   - Sets WM8960 as default audio device
   - dmix plugin for multi-application playback
   - dsnoop plugin for multi-application recording
   - Automatic format/rate conversion via plug plugin

## Uninstalling

```bash
sudo ./uninstall.sh
sudo reboot
```

This removes the DKMS module, restores the original device tree, removes the systemd service and ALSA config. Your existing ALSA configuration is backed up before removal. Audio server configuration (PulseAudio/PipeWire) is also cleaned up.

## Project Structure

```text
WM8960_AudioHAT_Armbian_OPiZero2W/
├── README.md                           # This file
├── LICENSE                             # License
├── install.sh                          # Installation script
├── uninstall.sh                        # Uninstallation script
├── dkms/                               # DKMS kernel module source
│   ├── wm8960.c                       # Patched WM8960 codec driver
│   ├── wm8960.h                       # WM8960 register definitions
│   ├── Makefile                       # DKMS build file
│   ├── dkms.conf                      # DKMS configuration
│   └── README.md                      # Driver patch documentation
├── overlays/                           # Device tree overlay source
│   ├── sun50i-h618-wm8960-armbian.dts # H618 overlay for Armbian
│   └── README.md                      # Overlay documentation
├── service/                            # System services
│   ├── wm8960-mixer-config.sh         # Mixer configuration script
│   └── wm8960-audio.service           # Systemd service
├── configs/                            # Audio configuration
│   ├── README.md                      # Config documentation + manual setup
│   ├── asound.conf                    # ALSA config (sets default device)
│   ├── pipewire-rate.conf             # PipeWire rate lock (48kHz)
│   ├── wireplumber-wm8960.conf        # WirePlumber priority rules
│   ├── pulse-daemon.conf              # PulseAudio daemon config
│   ├── 91-wm8960-pulseaudio.rules     # PulseAudio udev rule
│   ├── wm8960-audiohat.conf           # PulseAudio profile set
│   ├── wm8960-output.conf             # PulseAudio output path
│   ├── wm8960-input.conf              # PulseAudio input path
│   ├── pipewire-echo-cancel.conf      # PipeWire echo cancellation config
│   ├── pulse-echo-cancel.pa           # PulseAudio echo cancellation config
│   └── alsa-aec.conf                  # ALSA loopback AEC virtual device
├── tools/                              # Optional tools
│   └── echo-cancel/                   # Acoustic echo cancellation (GPLv3)
│       ├── install.sh                 # Installer (WebRTC or SpeexDSP)
│       ├── LICENSE-GPL3               # GPLv3 license for this directory
│       ├── src/ec_webrtc.cpp          # WebRTC AEC3 engine (~30dB+)
│       ├── src/ec.c                   # SpeexDSP engine (~15dB)
│       └── README.md                  # Echo canceller documentation
│   └── snd-aloop/                     # ALSA loopback module (for WebRTC AEC)
│       ├── aloop.c                    # Kernel module source
│       └── dkms.conf                  # DKMS configuration
├── scripts/                            # Utility scripts
│   └── test-audio.sh                  # Diagnostics and interactive audio tests
└── TROUBLESHOOTING.md                  # Common issues and solutions
```

## Audio Configuration

### Mixer Controls

Use `alsamixer` for an interactive mixer GUI:

```bash
alsamixer -c ahub0wm8960
```

Or use `amixer` for command-line control:

**Playback controls:**

```bash
# Set headphone volume (0-127, default: 121)
amixer -c ahub0wm8960 sset 'Headphone' 121

# Set speaker volume (0-127, default: 121)
amixer -c ahub0wm8960 sset 'Speaker' 121

# Set DAC playback volume (0-255, default: 255)
amixer -c ahub0wm8960 sset 'Playback' 255

# Enable PCM output routing (required for audio output)
amixer -c ahub0wm8960 sset 'Left Output Mixer PCM' on
amixer -c ahub0wm8960 sset 'Right Output Mixer PCM' on
```

**Capture/recording controls:**

```bash
# Enable capture input routing (required for recording)
amixer -c ahub0wm8960 sset 'Left Input Mixer Boost' on
amixer -c ahub0wm8960 sset 'Right Input Mixer Boost' on
amixer -c ahub0wm8960 sset 'Left Boost Mixer LINPUT1' on
amixer -c ahub0wm8960 sset 'Right Boost Mixer RINPUT1' on

# Enable capture and set volume (0-63, default: 45)
amixer -c ahub0wm8960 sset 'Capture' on
amixer -c ahub0wm8960 sset 'Capture' 45
```

**Saving custom mixer settings:**

```bash
# Save current mixer state to disk
sudo alsactl store ahub0wm8960
```

On first boot, the service applies defaults and saves them. On subsequent boots, it restores your saved settings instead. To reset back to factory defaults:

```bash
sudo /usr/local/bin/wm8960-mixer-config.sh --reset-defaults
```

### Sample Rates

The WM8960 hardware runs natively at **48kHz**. Other sample rates (16kHz, 8kHz, 44.1kHz, etc.) are transparently resampled by ALSA in software when using the `default` audio device.

**Important:** Always use the `default` ALSA device — never open `hw:N,0` directly at non-48kHz rates, as this bypasses resampling and produces garbled audio.

```bash
# Playback at any sample rate (ALSA resamples to 48kHz automatically)
aplay -D default my_audio.wav

# Recording at 16kHz for voice/STT pipelines
arecord -D default -r 16000 -c 1 -f S16_LE -d 5 voice_recording.wav
```

### Service Management

```bash
# Check service status
sudo systemctl status wm8960-audio.service

# View logs
sudo journalctl -u wm8960-audio.service

# Manually run configuration
sudo /usr/local/bin/wm8960-mixer-config.sh

# Run with debug output
sudo /usr/local/bin/wm8960-mixer-config.sh --verbose
```

## Troubleshooting

### Common Issues

**"H616 PLL_AUDIO not locked, applying fallback" in dmesg:**
- This message is **expected** on Armbian kernel 6.13+ and means the automatic fix is working. The Allwinner CCU clock driver has a PLL regression that prevents the audio PLL from locking. The WM8960 DKMS driver detects this and applies known-good clock values as a fallback. You should see `H616 PLL_AUDIO locked after fallback` shortly after, confirming audio clocks are configured correctly.

**No audio output:**
1. Check service status: `systemctl status wm8960-audio.service`
2. Check dmesg: `dmesg | grep wm8960`
3. Verify card detected: `aplay -l` (look for "ahub0wm8960")
4. Check mixer: `amixer -c ahub0wm8960`

**Audio too quiet:**
- Increase mixer volumes: `amixer -c ahub0wm8960 sset 'Headphone' 127`
- Check playback volume: `amixer -c ahub0wm8960 sset 'Playback' 255`

**Recording not working:**
1. Verify the capture signal path is enabled:
   ```bash
   amixer -c ahub0wm8960 sset 'Left Input Mixer Boost' on
   amixer -c ahub0wm8960 sset 'Right Input Mixer Boost' on
   amixer -c ahub0wm8960 sset 'Left Boost Mixer LINPUT1' on
   amixer -c ahub0wm8960 sset 'Right Boost Mixer RINPUT1' on
   amixer -c ahub0wm8960 sset 'Capture' on
   ```
2. Check capture volume: `amixer -c ahub0wm8960 sset 'Capture' 45`
3. Try re-running: `sudo /usr/local/bin/wm8960-mixer-config.sh`

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test on Orange Pi Zero 2W with Armbian
4. Submit a pull request

## License

This repository contains code under three licenses, reflecting the origin of each component. The split is permitted under the GPL's aggregation clause because the components are separate binaries that never combine into a single program.

| Component | License | Why |
|-----------|---------|-----|
| Scripts, configs, overlays, service files, docs, and all files at the repo root | **MIT** — see [LICENSE](LICENSE) | Original work, kept permissive for maximum reuse |
| [`dkms/`](dkms/) — kernel module source | **GPL-2.0-only** | Derived from the mainline Linux kernel `wm8960.c` codec driver (Copyright 2007–2011 Wolfson Microelectronics); kernel modules inherit the kernel's license |
| [`tools/echo-cancel/`](tools/echo-cancel/) — optional echo canceller | **GPLv3** — see [tools/echo-cancel/LICENSE-GPL3](tools/echo-cancel/LICENSE-GPL3) | SpeexDSP engine inherits GPLv3 from [voice-engine/ec](https://github.com/voice-engine/ec); WebRTC engine is GPLv3 by our choice for consistency. The vendored PortAudio ring buffer (`pa_ringbuffer.*`, `pa_memorybarrier.h`) retains its original BSD-style license — see file headers. |

If you only use the audio driver, you're working with MIT + GPL-2.0-only (standard kernel-module licensing). If you additionally install the echo canceller, GPLv3 applies to that binary only.

For per-file details, compatibility notes, and downstream-user guidance, see [docs/LICENSING.md](docs/LICENSING.md).

## Related Projects

- [WM8960 Audio HAT for Orange Pi (Multi-OS)](https://github.com/MJD19994/WM8960_AudioHAT_OrangePiZero_Drivers) - Supports both Orange Pi OS and Armbian
- [WM8960 Driver for Raspberry Pi](https://github.com/MJD19994/WM8960_AudioHAT_Drivers) - Raspberry Pi implementation

## Support

- **Issues**: [GitHub Issues](https://github.com/MJD19994/WM8960_AudioHAT_Armbian_OPiZero2W/issues)
- **Discussions**: [GitHub Discussions](https://github.com/MJD19994/WM8960_AudioHAT_Armbian_OPiZero2W/discussions)

---

**Status**: Working on Orange Pi Zero 2W (H618) with Armbian Trixie (kernel 6.12–6.18+)
