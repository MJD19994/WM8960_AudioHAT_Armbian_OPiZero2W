# Troubleshooting

Common issues and solutions for the WM8960 Audio HAT on Armbian (Orange Pi Zero 2W).

---

## Quick Diagnostics

Before diving into specific issues, run the built-in diagnostic tool:

```bash
# Run full diagnostics (no audio playback, just checks)
sudo /path/to/repo/scripts/test-audio.sh --diagnostics-only

# Or run the mixer config in verbose mode to see what it's doing
sudo /usr/local/bin/wm8960-mixer-config.sh --verbose
```

---

## No Sound Card Detected

**Symptom:** `aplay -l` does not list `ahub0wm8960`.

### Step 1: Check I2C connection

The WM8960 codec sits on I2C bus 3 at address 0x1a. Verify it's visible:

```bash
sudo apt install -y i2c-tools   # if not already installed
i2cdetect -y 3
```

You should see `1a` or `UU` at row 10, column a. If that cell is empty (`--`):

- The HAT is not seated properly on the GPIO header
- The HAT is connected to the wrong pins
- The HAT is defective

### Step 2: Check DTB patch

The installer patches the device tree to enable the WM8960. Verify:

```bash
# Check if the backup exists (means the patch was applied)
ls /boot/dtb-$(uname -r)/allwinner/sun50i-h618-orangepi-zero2w.dtb.backup

# Verify the overlay nodes are present in the active DTB
sudo apt install -y device-tree-compiler
dtc -I dtb -O dts /boot/dtb-$(uname -r)/allwinner/sun50i-h618-orangepi-zero2w.dtb 2>/dev/null | grep -i wm8960
```

If the backup doesn't exist or `wm8960` doesn't appear in the DTB output, re-run the installer:

```bash
sudo ./install.sh --verbose
sudo reboot
```

### Step 3: Check kernel module

```bash
# Is the module loaded?
lsmod | grep wm8960

# Is the DKMS package installed?
dkms status wm8960-audio-hat/1.0

# Can the module be loaded manually?
sudo modprobe snd_soc_wm8960
```

If `dkms status` shows nothing or `modprobe` fails, see [DKMS Build Fails](#dkms-build-fails) below.

---

## No Sound After Kernel Upgrade

**Symptom:** Audio was working, then stopped after an `apt upgrade` that updated the kernel.

**Why this happens:** The WM8960 kernel module is built via DKMS for a specific kernel version. When the kernel upgrades, the module needs to be rebuilt for the new version. The boot service (`wm8960-audio.service`) does this automatically, but it can fail if kernel headers are missing for the new kernel.

### Fix

```bash
# 1. Install headers for the running kernel
sudo apt update
sudo apt install linux-headers-current-sunxi64

# 2. Rebuild the DKMS module
sudo dkms install wm8960-audio-hat/1.0 -k $(uname -r)

# 3. Load the module and verify
sudo modprobe snd_soc_wm8960
aplay -l | grep -i wm8960
```

If `aplay -l` shows the card, you're good. The boot service will handle this automatically on future reboots.

---

## DKMS Build Fails

**Symptom:** `dkms install` or the boot-time rebuild reports build errors.

### Check that kernel headers match the running kernel

```bash
# What kernel are you running?
uname -r

# Are headers installed for it?
ls /lib/modules/$(uname -r)/build
```

If `/lib/modules/<version>/build` is missing or is a broken symlink, install the headers:

```bash
sudo apt install linux-headers-current-sunxi64
```

**Important:** Use `linux-headers-current-sunxi64` from the Armbian apt repository, not headers from kernel.org. The Armbian headers match the Armbian kernel config.

### Check the build log

If headers are present but the build still fails:

```bash
cat /var/lib/dkms/wm8960-audio-hat/1.0/build/make.log
```

This log shows the exact compiler errors. Common issues:
- Kernel API changes in a major version bump (the driver has compatibility guards for 6.6+ and 6.8+, but future kernels may need new ones)
- Missing build tools: `sudo apt install build-essential`

---

## Mixer at 0% After Reboot (PulseAudio)

**Symptom:** Volume is at 0% every time PulseAudio starts, even though you set it higher.

**Why this happens:** PulseAudio resets hardware mixer levels to its own defaults on startup. Without custom path files that tell PulseAudio to use `volume = merge` (respect existing ALSA levels), it sets everything to 0%.

### Fix

Check if the custom PulseAudio path files are installed:

```bash
ls -la /usr/share/pulseaudio/alsa-mixer/paths/wm8960-output.conf
ls -la /usr/share/pulseaudio/alsa-mixer/paths/wm8960-input.conf
ls -la /usr/share/pulseaudio/alsa-mixer/profile-sets/wm8960-audiohat.conf
ls -la /etc/udev/rules.d/91-wm8960-pulseaudio.rules
```

If any are missing, re-run the installer (it auto-detects PulseAudio and installs the files):

```bash
sudo ./install.sh --verbose
```

Or manually copy them — see `configs/README.md` for the file locations and installation instructions.

---

## Only 48kHz Playback Works

**Symptom:** Playing audio at rates other than 48kHz on `hw:X,0` sounds wrong, too fast, or fails with "Sample rate not available."

**Why this happens:** The AHUB audio subsystem on the H618 SoC clocks its I2S bus at 48kHz. When you use the `hw:` device directly, ALSA talks to the hardware with no conversion — so non-48kHz audio gets played at the wrong speed.

### Fix

Use `default` or `plughw` instead of `hw`:

```bash
# These all handle sample rate conversion automatically:
aplay -D default file.wav
aplay -D plughw:ahub0wm8960,0 file.wav
speaker-test -D default -c 2 -t wav
```

The `plughw` plugin adds automatic format/rate conversion. The `default` device (configured in `/etc/asound.conf`) uses `dmix` at 48kHz with software resampling.

**For programmatic use:** Always open the `default` or `plughw` device in your code, never `hw` directly.

---

## Boot Pinctrl Warning

**Symptom:** `dmesg` shows a warning like:

```
sun50i-h618-pinctrl 300b000.pinctrl: Error applying setting, reverse things back
```

**This is benign.** It occurs because the device tree overlay adds I2C1 pin configuration to a pin group that the base device tree already references. The pin controller logs a warning but the driver still initializes correctly.

### Verify

```bash
# Check that the WM8960 is working despite the warning
aplay -l | grep -i wm8960
i2cdetect -y 3 | grep "1a"
```

If both show the device, everything is fine. No action needed.

---

## Service Not Starting

**Symptom:** Sound card isn't configured after boot, or `systemctl status wm8960-audio.service` shows a failure.

### Check service status

```bash
systemctl status wm8960-audio.service
journalctl -u wm8960-audio.service -b --no-pager
```

### Common causes and fixes

**Service not enabled:**
```bash
sudo systemctl enable wm8960-audio.service
sudo systemctl start wm8960-audio.service
```

**Service file missing** (e.g., after a failed install):
```bash
sudo ./install.sh --verbose
```

**DKMS build failed during boot** (service timed out waiting for sound card):
See [DKMS Build Fails](#dkms-build-fails) above. Once the module builds, restart the service:
```bash
sudo systemctl restart wm8960-audio.service
```

---

## Mixer Profiles Not Taking Effect

**Symptom:** Running `--profile <name>` doesn't seem to change the sound.

### Verify the profile was applied

```bash
sudo /usr/local/bin/wm8960-mixer-config.sh --profile voice --verbose
```

Check the mixer state to confirm the values changed:

```bash
# Show all mixer controls and their current values
amixer -c ahub0wm8960 contents
```

For the `voice` profile, you should see things like:
- `ALC Function` = `Stereo` (not `Off`)
- `Left/Right Input Boost Mixer LINPUT1/RINPUT1 Volume` = `3` (not `2`)
- `Noise Gate` = `on` (not `off`)

### Audio server may be overriding ALSA levels

PulseAudio and PipeWire can override ALSA mixer settings. After applying a profile, restart the audio server to pick up the new levels:

```bash
# PulseAudio
pulseaudio -k

# PipeWire
systemctl --user restart pipewire pipewire-pulse
```

### Profile didn't persist after reboot

Profiles are saved via `alsactl store` when applied. Check that the state file exists:

```bash
grep -c "ahub0wm8960" /var/lib/alsa/asound.state
```

If 0, the state wasn't saved. Re-apply the profile:

```bash
sudo /usr/local/bin/wm8960-mixer-config.sh --profile voice
```

---

## Useful Diagnostic Commands

Quick reference for debugging:

```bash
# List all sound cards
aplay -l

# Show all mixer controls with current values
amixer -c ahub0wm8960 contents

# Check if the WM8960 I2C device is present
i2cdetect -y 3

# Check DKMS module status
dkms status wm8960-audio-hat/1.0

# Check kernel module
lsmod | grep wm8960
modinfo snd_soc_wm8960

# Check service status and logs
systemctl status wm8960-audio.service
journalctl -u wm8960-audio.service -b --no-pager

# Check kernel messages for audio/WM8960
dmesg | grep -iE "wm8960|ahub|i2s|codec"

# Check installed audio server
dpkg -l | grep -E "pipewire|pulseaudio" | head -5

# List available mixer profiles
/usr/local/bin/wm8960-mixer-config.sh --list-profiles
```

---

## Getting More Help

- Run the built-in diagnostics: `sudo scripts/test-audio.sh --diagnostics-only`
- Run verbose mode: `sudo /usr/local/bin/wm8960-mixer-config.sh --verbose`
- [Open an issue on GitHub](https://github.com/MJD19994/WM8960_AudioHAT_Armbian_OPiZero2W/issues)
