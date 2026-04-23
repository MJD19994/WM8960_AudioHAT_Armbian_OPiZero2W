# Usage & Testing Guide

Practical command reference for verifying the WM8960 HAT is working and for day-to-day playback/recording. If something isn't working, see [TROUBLESHOOTING.md](../TROUBLESHOOTING.md).

All commands below assume you're logged in on the Orange Pi. The sound card is `ahub0wm8960` and the I²S bus is 3 (these names come from the device tree overlay installed by `install.sh`).

## Checking Devices

Confirm the HAT is detected and enumerate available PCM devices:

```bash
# Sound cards
aplay -l
arecord -l

# Full card list with indexes
cat /proc/asound/cards
```

You should see `ahub0wm8960` in the output. If `snd-aloop` is loaded (automatic with the WebRTC echo canceller), you'll also see a `Loopback` card.

Check the loaded kernel module and verify the I²C codec address:

```bash
lsmod | grep -E 'wm8960|snd_aloop'
# i2cdetect needs root; the codec lives at 0x1a on bus 3
sudo i2cdetect -y 3
```

## Playback

The installed `asound.conf` makes the WM8960 the `default` device, so most tools just work with no `-D` flag.

### Sine-tone test

```bash
# Tone for 10 seconds (shorter tests on this hardware are not reliably audible)
timeout 10 speaker-test -D default -c 2 -r 48000 -t sine -f 1000 -l 1
```

If you hear a clean 1 kHz tone in both channels, playback is good.

### Play a WAV file

```bash
aplay music.wav                        # default device
aplay -D plughw:ahub0wm8960,0 file.wav # bypass default, auto-convert rate/channels
aplay -D hw:ahub0wm8960,0 file.wav     # raw hardware, requires native 48 kHz S16_LE stereo
```

### Volume control

```bash
# Read current state
amixer -c ahub0wm8960 sget Speaker
amixer -c ahub0wm8960 sget Headphone

# Quick volume set (0–127 for these controls)
amixer -c ahub0wm8960 sset Speaker 110
amixer -c ahub0wm8960 sset Headphone 110

# Interactive full mixer (recommended when exploring)
alsamixer -c ahub0wm8960
```

Mixer state is persisted at shutdown by the `wm8960-audio.service` unit, so changes survive reboots. To reset to defaults:

```bash
sudo /usr/local/bin/wm8960-mixer-config.sh --reset-defaults
```

## Recording

```bash
# 5-second stereo recording at 48 kHz
arecord -D default -r 48000 -c 2 -f S16_LE -d 5 /tmp/rec.wav

# Mono recording — useful for voice-assistant pipelines
arecord -D default -r 48000 -c 1 -f S16_LE -d 5 /tmp/voice.wav

# With sample rate / format conversion (plughw handles adaptation)
arecord -D plughw:ahub0wm8960,0 -r 16000 -c 1 -f S16_LE -d 5 /tmp/16k.wav
```

## Record + Playback Round-Trip

Quick sanity check that capture and playback both work:

```bash
arecord -D default -r 48000 -c 2 -f S16_LE -d 5 /tmp/rec.wav
aplay /tmp/rec.wav
```

Speak into the mic during the `arecord` window, then listen on playback.

## Sample Rate Behavior

The WM8960 runs natively at **48 kHz**. You can feed it other rates through `plughw` or the `default` device (both do automatic rate conversion), but the hardware endpoint `hw:ahub0wm8960,0` only accepts native 48 kHz S16_LE stereo. If you see `Broken configuration for this PCM`, you're probably hitting `hw:...` with a non-native parameter — use `plughw:...` instead.

## Echo Canceller Verification

If you installed the optional echo canceller (see [tools/echo-cancel/](../tools/echo-cancel/)):

```bash
# Service status + recent logs
systemctl status wm8960-echo-cancel
journalctl -u wm8960-echo-cancel -n 50

# Quick WebRTC EC smoke test — speak during pink noise playback
# (the EC service must be running)
arecord -D plughw:Loopback,1,1 -r 48000 -c 1 -f S16_LE -d 10 /tmp/ec-test.wav &
sox -n -r 48000 -c 1 -b 16 -t wav - synth 9 pinknoise vol 0.3 | \
    aplay -D plughw:Loopback,0,0 -q
wait

# Stats — speech-dominated cancellation typically lands around -20 dB RMS
sox /tmp/ec-test.wav -n stats 2>&1 | grep -E 'Pk lev|RMS lev'

# Listen to the processed output (through EC → speaker)
aplay -D plughw:Loopback,0,0 /tmp/ec-test.wav
```

When the EC service is running it holds the WM8960 speaker exclusively — **all playback/capture must go through the loopback devices** (`hw:Loopback,0,0` / `hw:Loopback,1,1`), not `default` or `hw:ahub0wm8960`.

## Audio Server Checks

If you're using PulseAudio or PipeWire, they wrap ALSA and add their own device layer. Use these commands to confirm the card and any AEC nodes are registered:

```bash
# PipeWire
pw-cli list-objects Node | grep -E 'node.name|node.description'
pw-cli list-objects Node | grep -i wm8960

# PulseAudio
pactl list sources short
pactl list sinks short
```

For the bundled AEC drop-in configs, see [configs/README.md](../configs/README.md).

## Shortcuts

The installer registers named aliases so you don't have to remember card/device numbers:

```bash
aplay -D wm8960_music music.wav           # optimized for playback
arecord -D wm8960_voice -d 5 voice.wav    # optimized for voice capture
arecord -D wm8960_record -d 5 stereo.wav  # high-quality stereo recording
```

See `/etc/asound.conf` for the full list of aliases the installer added.
