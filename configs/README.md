# Audio Configuration Files

Configuration files for ALSA, PipeWire, PulseAudio, and WirePlumber. The installer automatically detects your audio stack and installs the appropriate files.

## Files

### ALSA (always installed)

| File | Installed To | Purpose |
|------|-------------|---------|
| `asound.conf` | `/etc/asound.conf` | Sets WM8960 as the default audio device with dmix (multi-app playback) and dsnoop (multi-app recording) plugins. Handles format/rate conversion via the plug plugin. |

### PipeWire

| File | Installed To | Purpose |
|------|-------------|---------|
| `pipewire-rate.conf` | `/etc/pipewire/pipewire.conf.d/10-wm8960-rate.conf` | Locks PipeWire's internal processing to 48kHz to match the WM8960's native rate. Prevents unnecessary resampling. |
| `wireplumber-wm8960.conf` | `/etc/wireplumber/wireplumber.conf.d/51-wm8960.conf` | Sets the WM8960 as the highest-priority output and input device, so it wins over HDMI or USB audio. |

### PulseAudio

| File | Installed To | Purpose |
|------|-------------|---------|
| `pulse-daemon.conf` | `/etc/pulse/daemon.conf.d/10-wm8960.conf` | Locks PulseAudio to 48kHz sample rate and disables flat volumes. |
| `91-wm8960-pulseaudio.rules` | `/etc/udev/rules.d/` | udev rule that assigns our custom PulseAudio profile set to the WM8960 sound card (matched by card ID `ahub0wm8960`). |
| `wm8960-audiohat.conf` | `/usr/share/pulseaudio/alsa-mixer/profile-sets/` | Custom profile set that maps WM8960 mixer elements and uses `volume=merge` to prevent PulseAudio from resetting mixer levels to 0% on startup. |
| `wm8960-output.conf` | `/usr/share/pulseaudio/alsa-mixer/paths/` | Output path mapping for PulseAudio — maps headphone and speaker volume controls. |
| `wm8960-input.conf` | `/usr/share/pulseaudio/alsa-mixer/paths/` | Input path mapping for PulseAudio — maps capture volume controls. |

### Echo Cancellation (Optional)

These configs are **not** installed automatically — they are opt-in for voice assistant and conferencing use cases where the speaker and microphone are on the same board.

| File | Installed To | Purpose |
|------|-------------|---------|
| `pipewire-echo-cancel.conf` | `/etc/pipewire/pipewire.conf.d/20-echo-cancel.conf` | PipeWire: WebRTC acoustic echo cancellation. Creates virtual echo-cancelled source/sink nodes. |
| `pulse-echo-cancel.pa` | `/etc/pulse/default.pa.d/echo-cancel.pa` | PulseAudio: WebRTC acoustic echo cancellation via `module-echo-cancel`. |

For bare ALSA echo cancellation, see [`tools/echo-cancel/`](../tools/echo-cancel/) which provides a WebRTC AEC3 engine (default, requires snd-aloop) and a SpeexDSP fallback engine.

## Echo Cancellation Setup

Echo cancellation removes speaker audio from the microphone signal — essential when the speaker and mic are on the same HAT (e.g., ReSpeaker 2-Mic). Without it, voice assistants hear their own TTS output and get confused.

### PipeWire Echo Cancellation

**Prerequisites:**
```bash
sudo apt install -y pipewire pipewire-audio pipewire-alsa wireplumber \
    libspa-0.2-modules libwebrtc-audio-processing-1-3
```

**Install the config:**
```bash
sudo mkdir -p /etc/pipewire/pipewire.conf.d
sudo cp configs/pipewire-echo-cancel.conf /etc/pipewire/pipewire.conf.d/20-echo-cancel.conf
systemctl --user restart pipewire wireplumber
```

**Verify it's working:**
```bash
# Check that the echo-cancel nodes exist
pw-cli list-objects Node | grep -i "echo"
# You should see: Echo Cancellation Source, Sink, Capture, Playback
```

**Configure your voice assistant** to use "Echo Cancellation Source" as the microphone input and "Echo Cancellation Sink" as the audio output.

**Node names:** The config assumes PipeWire names the WM8960 devices as `alsa_input.platform-soc_ahub0_mach.stereo-fallback` and `alsa_output.platform-soc_ahub0_mach.stereo-fallback`. If your names differ, check with `pw-cli list-objects Node | grep node.name` and update the `node.target` values in the config file.

### PulseAudio Echo Cancellation

**Prerequisites:**
```bash
sudo apt install -y pulseaudio pulseaudio-utils libwebrtc-audio-processing-1-3
```

**Install the config:**
```bash
sudo mkdir -p /etc/pulse/default.pa.d
sudo cp configs/pulse-echo-cancel.pa /etc/pulse/default.pa.d/echo-cancel.pa
pulseaudio -k   # auto-restarts with new config
```

**Verify it's working:**
```bash
# Check that the echo-cancel module loaded
pactl list sources short | grep echo_cancelled
pactl list sinks short | grep echo_cancelled
```

**Configure your voice assistant** to use `echo_cancelled_input` as the microphone source and `echo_cancelled_output` as the audio sink.

**Device names:** The config assumes PulseAudio names the WM8960 devices as `alsa_input.platform-soc_ahub0_mach.stereo-fallback` and `alsa_output.platform-soc_ahub0_mach.stereo-fallback`. If your names differ, check with `pactl list sources short` and `pactl list sinks short`, then update the `source_master`/`sink_master` values.

### Bare ALSA Echo Cancellation

For systems without PipeWire or PulseAudio (e.g., classic Rhasspy), see the [`tools/echo-cancel/`](../tools/echo-cancel/) directory which provides a standalone SpeexDSP-based echo canceller that works directly with ALSA.

## Manual Audio Server Setup

The installer handles audio server configuration automatically when PipeWire or PulseAudio is detected at install time. If you install an audio server **after** running the driver installer, follow the steps below.

### Installing PipeWire After the Driver

```bash
# Copy the PipeWire rate lock config
sudo mkdir -p /etc/pipewire/pipewire.conf.d
sudo cp configs/pipewire-rate.conf /etc/pipewire/pipewire.conf.d/10-wm8960-rate.conf

# Copy the WirePlumber priority rules
sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
sudo cp configs/wireplumber-wm8960.conf /etc/wireplumber/wireplumber.conf.d/51-wm8960.conf

# Restart PipeWire to apply changes
systemctl --user restart pipewire pipewire-pulse wireplumber
```

### Installing PulseAudio After the Driver

```bash
# Copy daemon config
sudo mkdir -p /etc/pulse/daemon.conf.d
sudo cp configs/pulse-daemon.conf /etc/pulse/daemon.conf.d/10-wm8960.conf

# Copy udev rule
sudo cp configs/91-wm8960-pulseaudio.rules /etc/udev/rules.d/

# Copy profile set and path files
sudo cp configs/wm8960-audiohat.conf /usr/share/pulseaudio/alsa-mixer/profile-sets/
sudo cp configs/wm8960-output.conf /usr/share/pulseaudio/alsa-mixer/paths/
sudo cp configs/wm8960-input.conf /usr/share/pulseaudio/alsa-mixer/paths/

# Reload udev rules and restart PulseAudio
sudo udevadm control --reload-rules
sudo udevadm trigger
pulseaudio -k  # PulseAudio will auto-restart
```

### Removing Audio Server Config

If you switch audio servers or want to remove the configuration:

```bash
# PipeWire
sudo rm -f /etc/pipewire/pipewire.conf.d/10-wm8960-rate.conf
sudo rm -f /etc/wireplumber/wireplumber.conf.d/51-wm8960.conf

# PulseAudio
sudo rm -f /etc/pulse/daemon.conf.d/10-wm8960.conf
sudo rm -f /etc/udev/rules.d/91-wm8960-pulseaudio.rules
sudo rm -f /usr/share/pulseaudio/alsa-mixer/profile-sets/wm8960-audiohat.conf
sudo rm -f /usr/share/pulseaudio/alsa-mixer/paths/wm8960-output.conf
sudo rm -f /usr/share/pulseaudio/alsa-mixer/paths/wm8960-input.conf
```

Or simply run `uninstall.sh` which handles all of this automatically.
