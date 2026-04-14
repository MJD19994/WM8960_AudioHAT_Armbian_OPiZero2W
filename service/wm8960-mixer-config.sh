#!/bin/bash
#
# WM8960 Audio HAT Mixer Configuration Script (Armbian)
#
# Configures WM8960 codec mixer settings on Armbian. The DKMS driver handles
# PLL configuration internally via ASoC, so no manual PLL setup is needed.
#
# On first boot (no saved state), applies factory defaults for playback routing,
# volume levels, and capture settings. On subsequent boots, restores the user's
# saved mixer state via alsactl. Use --reset-defaults to force factory defaults.
#

set -e

# Parse command-line options
RESET_DEFAULTS=false
VERBOSE=false
PROFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --reset-defaults)
            RESET_DEFAULTS=true
            ;;
        --profile=*)
            PROFILE="${1#--profile=}"
            if [ -z "$PROFILE" ]; then
                echo "ERROR: --profile requires a non-empty name (e.g., --profile voice)" >&2
                exit 1
            fi
            ;;
        --profile)
            shift
            if [ $# -eq 0 ] || case "$1" in -*) true;; *) false;; esac; then
                echo "ERROR: --profile requires a name (e.g., --profile voice)" >&2
                exit 1
            fi
            PROFILE="$1"
            ;;
        --list-profiles)
            echo "Available mixer profiles:"
            echo ""
            echo "  voice         Boost mic gain, lower speaker volume, enable ALC"
            echo "                Best for: voice assistants, STT, wake-word detection"
            echo ""
            echo "  music         Balanced output, ALC off, 3D enhancement off"
            echo "                Best for: music playback, media, general listening"
            echo ""
            echo "  headphones    Lower volume, enable 3D stereo enhancement"
            echo "                Best for: headphone listening, immersive audio"
            echo ""
            echo "  conferencing  Aggressive ALC, noise gate on, mic boost"
            echo "                Best for: video calls, intercom, two-way audio"
            echo ""
            echo "  recording     Flat response, no processing, max dynamic range"
            echo "                Best for: high-quality recording, audio capture"
            echo ""
            echo "Usage: $(basename "$0") --profile <name>"
            echo "       $(basename "$0") --profile=<name>"
            exit 0
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --help|-h)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --profile <name>  Apply a named mixer profile (see --list-profiles)"
            echo "                    Also accepts --profile=<name>"
            echo "  --list-profiles   Show available mixer profiles and descriptions"
            echo "  --reset-defaults  Force-apply factory mixer defaults, replacing any"
            echo "                    custom settings saved with 'alsactl store'"
            echo "  --verbose, -v     Show detailed step-by-step output for troubleshooting"
            echo "  --help, -h        Show this help message"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option '$1' (use --help or --list-profiles)" >&2
            exit 1
            ;;
    esac
    shift
done

DRIVER_PATH="/sys/bus/i2c/drivers/wm8960"

# Auto-detect I2C bus from sysfs (default to bus 3 on Armbian)
if [ -z "$I2C_BUS" ]; then
    I2C_BUS=$(find /sys/bus/i2c/devices/ -maxdepth 1 -name '*-001a' 2>/dev/null \
              | head -1 | sed -n 's|.*/\([0-9]*\)-001a$|\1|p' || true)
    if [ -z "$I2C_BUS" ]; then
        I2C_BUS=3
    fi
fi

# Build device identifier (e.g., "3-001a")
if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID="${I2C_BUS}-001a"
fi

log() {
    echo "[WM8960] $1"
}

log_debug() {
    if [ "$VERBOSE" = true ]; then
        echo "[WM8960] [DEBUG] $1"
    fi
}

wait_for_device() {
    local max_wait=10
    local count=0

    log_debug "Waiting for device at $DRIVER_PATH/$DEVICE_ID"
    while [ ! -e "$DRIVER_PATH/$DEVICE_ID" ] && [ $count -lt $max_wait ]; do
        log_debug "Device not ready, waiting... (${count}/${max_wait}s)"
        sleep 1
        count=$((count + 1))
    done

    if [ ! -e "$DRIVER_PATH/$DEVICE_ID" ]; then
        log "ERROR: WM8960 device not found after ${max_wait}s"
        log "Check that the WM8960 is connected to I2C bus $I2C_BUS at address 0x1a"
        exit 1
    fi
    log_debug "Device found after ${count}s"
}

wait_for_soundcard() {
    local max_wait=15
    local count=0

    log_debug "Waiting for WM8960 sound card to appear..."
    while ! aplay -l 2>/dev/null | grep -qi "wm8960" && [ $count -lt $max_wait ]; do
        log_debug "Sound card not ready, waiting... (${count}/${max_wait}s)"
        sleep 1
        count=$((count + 1))
    done

    if ! aplay -l 2>/dev/null | grep -qi "wm8960"; then
        log "ERROR: WM8960 sound card not found after ${max_wait}s"
        log "Check that the WM8960 module is loaded and device tree is patched"
        exit 1
    fi
    log_debug "Sound card found after ${count}s"
}

detect_card() {
    # Detect WM8960 card number (allow override via environment variable)
    if [ -n "$WM8960_CARD" ]; then
        echo "$WM8960_CARD"
        return 0
    fi

    local card
    card=$(aplay -l 2>/dev/null | grep -i "wm8960\|ahub0wm8960" | head -1 | sed -n 's/^card \([0-9]\+\):.*/\1/p')

    if [ -z "$card" ]; then
        log "ERROR: Could not detect WM8960 sound card. Set WM8960_CARD environment variable or check if device is present."
        return 1
    fi

    echo "$card"
}

has_saved_state() {
    # Check if alsactl has a saved state for this card.
    # alsactl keys state sections by card ID (e.g., "state.ahub0wm8960"),
    # not by card number (e.g., "state.card0").
    local card_num="$1"
    local state_file="/var/lib/alsa/asound.state"
    local card_id

    [ -f "$state_file" ] || return 1
    card_id=$(cat "/proc/asound/card${card_num}/id" 2>/dev/null) || return 1
    grep -q "state\.${card_id}[[:space:]]*{" "$state_file" 2>/dev/null
}

apply_mixer_defaults() {
    local CARD_NUM="$1"

    # Run in subshell with errexit disabled — individual mixer controls may vary
    # by driver version and a single missing control should not abort the script
    (
    set +e

    # --- Playback routing and volumes ---
    # Enable DAC -> Output Mixer -> Headphone/Speaker path
    amixer -c "$CARD_NUM" sset "Left Output Mixer PCM" on >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Right Output Mixer PCM" on >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Left Output Mixer Boost Bypass" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Right Output Mixer Boost Bypass" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Left Output Mixer LINPUT3" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Right Output Mixer RINPUT3" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Mono Output Mixer Left" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Mono Output Mixer Right" off >/dev/null 2>&1

    # Headphone volume (0-127, with zero-cross for click-free changes)
    amixer -c "$CARD_NUM" sset "Headphone" 121 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Headphone Playback ZC" on >/dev/null 2>&1

    # Speaker volume (0-127, with zero-cross for click-free changes)
    amixer -c "$CARD_NUM" sset "Speaker" 121 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Speaker Playback ZC" on >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Speaker AC" 0 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Speaker DC" 0 >/dev/null 2>&1

    # DAC playback volume (0-255)
    amixer -c "$CARD_NUM" sset "Playback" 255 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "PCM Playback -6dB" off >/dev/null 2>&1

    # DAC settings
    amixer -c "$CARD_NUM" sset "DAC Deemphasis" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "DAC Polarity" "No Inversion" >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "DAC Mono Mix" "Stereo" >/dev/null 2>&1

    # 3D Enhancement (off by default, can be enabled for stereo widening)
    amixer -c "$CARD_NUM" sset "3D" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "3D Volume" 0 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "3D Filter Upper Cut-Off" "High" >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "3D Filter Lower Cut-Off" "Low" >/dev/null 2>&1

    # --- Capture/recording settings ---
    # Enable input signal path: LINPUT1/RINPUT1 -> Boost Mixer -> Input Mixer -> ADC
    amixer -c "$CARD_NUM" sset "Left Input Mixer Boost" on >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Right Input Mixer Boost" on >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Left Boost Mixer LINPUT1" on >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Right Boost Mixer RINPUT1" on >/dev/null 2>&1

    # Capture volume (0-63) and switch
    amixer -c "$CARD_NUM" sset "Capture" on >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Capture" 45 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Capture Volume ZC" on >/dev/null 2>&1

    # ADC digital volume (0-255)
    amixer -c "$CARD_NUM" cset name='ADC PCM Capture Volume' 210,210 >/dev/null 2>&1

    # Input boost gain (0=mute, 1=+13dB, 2=+20dB, 3=+29dB)
    amixer -c "$CARD_NUM" cset name='Left Input Boost Mixer LINPUT1 Volume' 2 >/dev/null 2>&1
    amixer -c "$CARD_NUM" cset name='Right Input Boost Mixer RINPUT1 Volume' 2 >/dev/null 2>&1

    # ADC settings
    amixer -c "$CARD_NUM" sset "ADC Polarity" "No Inversion" >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ADC High Pass Filter" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ADC Data Output Select" "Left Data = Left ADC;  Right Data = Right ADC" >/dev/null 2>&1

    # --- Automatic Level Control (off by default, enable for hardware AGC) ---
    amixer -c "$CARD_NUM" sset "ALC Function" "Off" >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Max Gain" 7 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Min Gain" 0 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Target" 4 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Hold Time" 0 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Decay" 3 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Attack" 2 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Mode" "ALC" >/dev/null 2>&1

    # --- Noise Gate (off by default) ---
    amixer -c "$CARD_NUM" sset "Noise Gate" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Noise Gate Threshold" 0 >/dev/null 2>&1

    exit 0
    )
}

apply_profile_voice() {
    # Voice assistant / STT profile:
    #   - Mic gain boosted for clear voice capture
    #   - Speaker volume lowered (avoid feedback into mic)
    #   - ALC enabled to normalize speech levels
    #   - Noise gate on to suppress background noise between utterances
    local CARD_NUM="$1"
    (
    set +e

    # Start from factory defaults as baseline
    apply_mixer_defaults "$CARD_NUM"

    # Lower speaker/headphone volume to reduce mic feedback
    amixer -c "$CARD_NUM" sset "Headphone" 90 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Speaker" 90 >/dev/null 2>&1

    # Boost mic input gain (+29dB)
    amixer -c "$CARD_NUM" cset name='Left Input Boost Mixer LINPUT1 Volume' 3 >/dev/null 2>&1
    amixer -c "$CARD_NUM" cset name='Right Input Boost Mixer RINPUT1 Volume' 3 >/dev/null 2>&1

    # Raise capture volume
    amixer -c "$CARD_NUM" sset "Capture" 55 >/dev/null 2>&1
    amixer -c "$CARD_NUM" cset name='ADC PCM Capture Volume' 230,230 >/dev/null 2>&1

    # Enable ALC — auto-levels speech, handles varying distances from mic
    amixer -c "$CARD_NUM" sset "ALC Function" "Stereo" >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Max Gain" 7 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Min Gain" 0 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Target" 5 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Hold Time" 1 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Decay" 3 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Attack" 2 >/dev/null 2>&1

    # Enable noise gate to suppress background noise
    amixer -c "$CARD_NUM" sset "Noise Gate" on >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Noise Gate Threshold" 3 >/dev/null 2>&1

    exit 0
    )
}

apply_profile_music() {
    # Music playback profile:
    #   - Full output volume for clean playback
    #   - ALC off (music has its own dynamics)
    #   - 3D enhancement off (preserve original mix)
    #   - Capture left at defaults (not the focus)
    local CARD_NUM="$1"
    (
    set +e

    apply_mixer_defaults "$CARD_NUM"

    # Full output volume
    amixer -c "$CARD_NUM" sset "Headphone" 121 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Speaker" 121 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Playback" 255 >/dev/null 2>&1

    # Ensure ALC is off — preserve music dynamics
    amixer -c "$CARD_NUM" sset "ALC Function" "Off" >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Noise Gate" off >/dev/null 2>&1

    # 3D off — don't color the original mix
    amixer -c "$CARD_NUM" sset "3D" off >/dev/null 2>&1

    exit 0
    )
}

apply_profile_headphones() {
    # Headphone listening profile:
    #   - Reduced headphone volume for safe listening
    #   - Speaker output muted (not needed)
    #   - 3D stereo enhancement enabled for spatial sound
    local CARD_NUM="$1"
    (
    set +e

    apply_mixer_defaults "$CARD_NUM"

    # Safe headphone volume — 100/127 (~-5dB from max)
    amixer -c "$CARD_NUM" sset "Headphone" 100 >/dev/null 2>&1

    # Mute speaker output
    amixer -c "$CARD_NUM" sset "Speaker" 0 >/dev/null 2>&1

    # Enable 3D stereo enhancement for immersive headphone experience
    amixer -c "$CARD_NUM" sset "3D" on >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "3D Volume" 10 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "3D Filter Upper Cut-Off" "High" >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "3D Filter Lower Cut-Off" "Low" >/dev/null 2>&1

    # ALC off
    amixer -c "$CARD_NUM" sset "ALC Function" "Off" >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Noise Gate" off >/dev/null 2>&1

    exit 0
    )
}

apply_profile_conferencing() {
    # Conferencing / intercom profile:
    #   - Aggressive ALC for hands-free mic (wide dynamic range handling)
    #   - Noise gate on with higher threshold (suppress room noise)
    #   - High mic boost for distant speakers
    #   - Moderate output volume (avoid echo)
    local CARD_NUM="$1"
    (
    set +e

    apply_mixer_defaults "$CARD_NUM"

    # Moderate output to reduce echo
    amixer -c "$CARD_NUM" sset "Headphone" 100 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Speaker" 100 >/dev/null 2>&1

    # Max mic boost for distant capture (+29dB)
    amixer -c "$CARD_NUM" cset name='Left Input Boost Mixer LINPUT1 Volume' 3 >/dev/null 2>&1
    amixer -c "$CARD_NUM" cset name='Right Input Boost Mixer RINPUT1 Volume' 3 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Capture" 55 >/dev/null 2>&1
    amixer -c "$CARD_NUM" cset name='ADC PCM Capture Volume' 220,220 >/dev/null 2>&1

    # Aggressive ALC — fast attack, slow decay, wide gain range
    amixer -c "$CARD_NUM" sset "ALC Function" "Stereo" >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Max Gain" 7 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Min Gain" 0 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Target" 6 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Hold Time" 2 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Decay" 5 >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ALC Attack" 1 >/dev/null 2>&1

    # Noise gate with higher threshold — suppress room ambient
    amixer -c "$CARD_NUM" sset "Noise Gate" on >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Noise Gate Threshold" 5 >/dev/null 2>&1

    exit 0
    )
}

apply_profile_recording() {
    # High-quality recording profile:
    #   - Flat response, no processing (ALC off, noise gate off, 3D off)
    #   - Moderate mic gain (avoid clipping)
    #   - Max dynamic range for post-processing flexibility
    local CARD_NUM="$1"
    (
    set +e

    apply_mixer_defaults "$CARD_NUM"

    # Moderate mic gain — +20dB boost, avoid clipping
    amixer -c "$CARD_NUM" cset name='Left Input Boost Mixer LINPUT1 Volume' 2 >/dev/null 2>&1
    amixer -c "$CARD_NUM" cset name='Right Input Boost Mixer RINPUT1 Volume' 2 >/dev/null 2>&1

    # Moderate capture volume — leave headroom
    amixer -c "$CARD_NUM" sset "Capture" 40 >/dev/null 2>&1
    amixer -c "$CARD_NUM" cset name='ADC PCM Capture Volume' 195,195 >/dev/null 2>&1

    # Disable all processing — flat, uncolored capture
    amixer -c "$CARD_NUM" sset "ALC Function" "Off" >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "Noise Gate" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "3D" off >/dev/null 2>&1
    amixer -c "$CARD_NUM" sset "ADC High Pass Filter" off >/dev/null 2>&1

    exit 0
    )
}

apply_profile() {
    local CARD_NUM="$1"
    local profile="$2"

    case "$profile" in
        voice)
            apply_profile_voice "$CARD_NUM"
            ;;
        music)
            apply_profile_music "$CARD_NUM"
            ;;
        headphones)
            apply_profile_headphones "$CARD_NUM"
            ;;
        conferencing)
            apply_profile_conferencing "$CARD_NUM"
            ;;
        recording)
            apply_profile_recording "$CARD_NUM"
            ;;
        *)
            log "ERROR: Unknown profile '$profile'"
            log "Run '$(basename "$0") --list-profiles' to see available profiles"
            return 1
            ;;
    esac
}

configure_mixer() {
    log "Configuring mixer settings..."

    local CARD_NUM
    CARD_NUM=$(detect_card) || return 1

    if [ -n "$WM8960_CARD" ]; then
        log "Using WM8960_CARD from environment: $CARD_NUM"
    else
        log "Detected WM8960 card: $CARD_NUM"
    fi

    log_debug "Card number: $CARD_NUM"
    log_debug "RESET_DEFAULTS=$RESET_DEFAULTS"
    log_debug "State file check: $([ -f /var/lib/alsa/asound.state ] && echo 'exists' || echo 'missing')"

    # Check for --profile flag (takes priority over other options)
    if [ -n "$PROFILE" ]; then
        log "Applying mixer profile: $PROFILE"
        if apply_profile "$CARD_NUM" "$PROFILE"; then
            if alsactl store "$CARD_NUM" >/dev/null 2>&1; then
                log "Profile '$PROFILE' applied and saved!"
            else
                log "WARNING: Profile '$PROFILE' applied, but failed to save mixer state"
            fi
        else
            log "ERROR: Failed to apply profile '$PROFILE'"
            return 1
        fi
    # Check for --reset-defaults flag
    elif [ "$RESET_DEFAULTS" = true ]; then
        log "Resetting mixer to factory defaults (--reset-defaults)..."
        apply_mixer_defaults "$CARD_NUM"
        if alsactl store "$CARD_NUM" >/dev/null 2>&1; then
            log "Factory defaults applied and saved!"
        else
            log "WARNING: Factory defaults applied, but failed to save mixer state"
        fi
    elif has_saved_state "$CARD_NUM"; then
        log "Restoring saved mixer state..."
        if alsactl restore "$CARD_NUM" >/dev/null 2>&1; then
            log "Mixer restored from saved state!"
        else
            log "WARNING: Failed to restore saved state, applying defaults..."
            apply_mixer_defaults "$CARD_NUM"
            if alsactl store "$CARD_NUM" >/dev/null 2>&1; then
                log "Defaults saved!"
            else
                log "WARNING: Defaults applied, but failed to save mixer state"
            fi
        fi
    else
        log "No saved state found — applying defaults..."
        apply_mixer_defaults "$CARD_NUM"

        # Save initial defaults so future boots know state exists
        if alsactl store "$CARD_NUM" >/dev/null 2>&1; then
            log "Mixer defaults applied and saved!"
        else
            log "WARNING: Mixer defaults applied, but failed to save mixer state"
        fi
    fi
}

ensure_dkms_module() {
    local module_name="wm8960-audio-hat"
    local module_version="1.0"
    local kver
    kver=$(uname -r)

    # Check if the module is available from the installed kernel (distro-provided)
    if modprobe -n snd_soc_wm8960 >/dev/null 2>&1; then
        log_debug "WM8960 module available from installed kernel package"
        modprobe snd_soc_wm8960 2>/dev/null || true
        return 0
    fi

    # Check if our DKMS module is already installed for this kernel
    if dkms status "${module_name}/${module_version}" -k "$kver" 2>/dev/null | grep -q installed; then
        log_debug "WM8960 DKMS module already installed for kernel $kver"
        modprobe snd_soc_wm8960 2>/dev/null || true
        return 0
    fi

    log "WM8960 module not found for kernel $kver — attempting DKMS rebuild..."

    # Verify DKMS is installed and module source exists
    if ! command -v dkms >/dev/null 2>&1; then
        log "ERROR: dkms not installed, cannot rebuild module"
        return 1
    fi

    if [ ! -d "/usr/src/${module_name}-${module_version}" ]; then
        log "ERROR: DKMS source not found at /usr/src/${module_name}-${module_version}"
        return 1
    fi

    # Check kernel headers are available
    if [ ! -d "/lib/modules/${kver}/build" ]; then
        log "ERROR: Kernel headers not found for ${kver}"
        log "Install headers and re-run, or reboot into the previous kernel"
        return 1
    fi

    # Ensure module is registered with DKMS
    if ! dkms status "${module_name}/${module_version}" 2>/dev/null | grep -q .; then
        log "Registering DKMS module..."
        dkms add "${module_name}/${module_version}" || { log "ERROR: dkms add failed"; return 1; }
    fi

    # Build and install for running kernel
    log "Building module for kernel ${kver}..."
    if dkms install "${module_name}/${module_version}" -k "${kver}" 2>&1; then
        log "DKMS rebuild successful!"
        # Load the freshly built module
        modprobe snd_soc_wm8960 2>/dev/null || true
    else
        log "ERROR: DKMS build failed for kernel ${kver}"
        return 1
    fi
}

# Main execution
log "Starting WM8960 audio configuration..."

# Ensure DKMS module is built for the running kernel (handles kernel upgrades).
# Exit early on failure — without the module the device/sound card waits below
# would just time out (~25s) and report a misleading "device not found" error.
if ! ensure_dkms_module; then
    log "ERROR: DKMS module check failed — cannot configure audio"
    log "Run 'dkms status wm8960-audio-hat' and check 'journalctl -u wm8960-audio.service' for details"
    exit 1
fi

# Wait for I2C device to be available
wait_for_device

# Wait for sound card to appear
wait_for_soundcard

# Configure mixer
configure_mixer

log "WM8960 audio configuration complete! Audio is ready."
exit 0
