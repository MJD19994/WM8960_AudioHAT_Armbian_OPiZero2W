#!/bin/bash
#
# WM8960 Audio HAT Uninstallation Script (Armbian)
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERBOSE=false

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=true ;;
        --help|-h)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v  Show detailed step-by-step output for troubleshooting"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg (use --help for usage)"
            exit 1
            ;;
    esac
done

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

log_info "Uninstalling WM8960 Audio HAT support..."

# Stop and disable service
if systemctl is-active --quiet wm8960-audio.service; then
    log_info "Stopping service..."
    systemctl stop wm8960-audio.service
else
    log_debug "Service not active"
fi

if systemctl is-enabled --quiet wm8960-audio.service; then
    log_info "Disabling service..."
    systemctl disable wm8960-audio.service
else
    log_debug "Service not enabled"
fi

# Remove service files
log_debug "Removing /etc/systemd/system/wm8960-audio.service"
rm -f /etc/systemd/system/wm8960-audio.service
log_debug "Removing mixer config script"
rm -f /usr/local/bin/wm8960-mixer-config.sh
rm -f /usr/local/bin/wm8960-pll-config.sh  # legacy name from previous installs
systemctl daemon-reload

# Remove ALSA config and restore the user's pre-install asound.conf if we
# backed one up during install. The backup file (.wm8960-backup) is created
# by install.sh on first install when /etc/asound.conf already exists.
if [ -f /etc/asound.conf ]; then
    if [ -f /etc/asound.conf.wm8960-backup ]; then
        log_info "Restoring original /etc/asound.conf from backup"
        mv /etc/asound.conf.wm8960-backup /etc/asound.conf
    else
        log_info "Removing /etc/asound.conf (no pre-install backup found)"
        rm -f /etc/asound.conf
    fi
else
    log_debug "/etc/asound.conf not found — nothing to remove"
fi

rm -f /etc/wm8960.state

# Remove audio server configs based on install manifest
INSTALLED_STACK="alsa"
if [ -f /etc/wm8960-audio-stack.conf ]; then
    # shellcheck source=/dev/null
    . /etc/wm8960-audio-stack.conf
    INSTALLED_STACK="${AUDIO_STACK:-alsa}"
    log_debug "Install manifest: AUDIO_STACK=$INSTALLED_STACK"
fi

if [ "$INSTALLED_STACK" = "pipewire" ]; then
    log_info "Removing PipeWire/WirePlumber configuration..."
    rm -f /etc/pipewire/pipewire.conf.d/10-wm8960-rate.conf
    rm -f /etc/wireplumber/wireplumber.conf.d/51-wm8960.conf
    log_debug "Removed PipeWire rate config and WirePlumber priority rules"
elif [ "$INSTALLED_STACK" = "pulseaudio" ]; then
    log_info "Removing PulseAudio configuration..."
    rm -f /etc/pulse/daemon.conf.d/10-wm8960.conf
    rm -f /etc/udev/rules.d/91-wm8960-pulseaudio.rules
    rm -f /usr/share/pulseaudio/alsa-mixer/profile-sets/wm8960-audiohat.conf
    rm -f /usr/share/pulseaudio/alsa-mixer/paths/wm8960-output.conf
    rm -f /usr/share/pulseaudio/alsa-mixer/paths/wm8960-input.conf
    log_debug "Removed PulseAudio daemon config, udev rule, profile set, and mixer paths"
else
    log_debug "No audio server configs to remove (bare ALSA)"
fi

rm -f /etc/wm8960-audio-stack.conf

# Remove DKMS module if installed
if command -v dkms &>/dev/null && dkms status wm8960-audio-hat/1.0 2>/dev/null | grep -q .; then
    log_info "Removing DKMS module..."
    dkms remove wm8960-audio-hat/1.0 --all 2>/dev/null || log_warn "DKMS remove failed"
    rm -rf /usr/src/wm8960-audio-hat-1.0
    log_debug "DKMS module and source removed"
fi

# Remove WM8960 module if it was built from source (legacy, pre-DKMS).
# Skip removal if the file is owned by a dpkg package — that means a future
# Armbian kernel ships the module itself and we must not delete distro files.
log_debug "Checking for built-from-source WM8960 module"
WM8960_MODULE_BASE="/lib/modules/$(uname -r)/kernel/sound/soc/codecs/snd-soc-wm8960"
for ext in .ko .ko.xz .ko.zst; do
    if [ -f "${WM8960_MODULE_BASE}${ext}" ]; then
        if command -v dpkg &>/dev/null && dpkg -S "${WM8960_MODULE_BASE}${ext}" &>/dev/null; then
            log_debug "Skipping ${WM8960_MODULE_BASE}${ext} — owned by a dpkg package"
        else
            log_info "Removing WM8960 kernel module (built from source)..."
            log_debug "Removing ${WM8960_MODULE_BASE}${ext}"
            rm -f "${WM8960_MODULE_BASE}${ext}"
            depmod -a
        fi
        break
    fi
done

# Restore original device tree
# Prefer /boot/dtb (symlink the bootloader actually uses) to avoid
# restoring the wrong tree when multiple DTB directories exist
if [ -L /boot/dtb ] || [ -d /boot/dtb ]; then
    DTB_BASE_DIR=$(readlink -f /boot/dtb)
    DTB_DIR=$(find "$DTB_BASE_DIR" -type d -name "allwinner" 2>/dev/null | head -1)
fi
if [ -z "$DTB_DIR" ]; then
    DTB_DIR=$(find /boot -type d -name "allwinner" -path "*/dtb*" 2>/dev/null | head -1)
fi
log_debug "DTB_DIR=$DTB_DIR"
if [ -n "$DTB_DIR" ]; then
    BASE_DTB=$(find "$DTB_DIR" -maxdepth 1 -name "sun50i-h61*-orangepi-zero2w.dtb" 2>/dev/null | head -1)
    log_debug "BASE_DTB=$BASE_DTB"
    log_debug "Is symlink: $([ -L "$BASE_DTB" ] && echo yes || echo no)"
    log_debug "Backup exists: $([ -f "${BASE_DTB}.backup" ] && echo yes || echo no)"
    if [ -n "$BASE_DTB" ] && [ -L "$BASE_DTB" ]; then
        # DTB is a symlink to patched version — restore from backup
        log_debug "Symlink target: $(readlink "$BASE_DTB")"
        if [ -f "${BASE_DTB}.backup" ]; then
            log_info "Restoring original device tree..."
            rm -f "$BASE_DTB"
            cp "${BASE_DTB}.backup" "$BASE_DTB"
            log_info "Original DTB restored"
            # Remove patched DTB
            PATCHED_DTB="$DTB_DIR/$(basename "$BASE_DTB" .dtb)-wm8960.dtb"
            log_debug "Removing patched DTB: $PATCHED_DTB"
            rm -f "$PATCHED_DTB"
        else
            log_warn "DTB backup not found — cannot restore original device tree"
            log_warn "System may be left in an inconsistent state"
        fi
    else
        log_info "Device tree does not appear to be patched"
    fi
else
    log_info "DTB directory not found — skipping DTB restoration"
fi

log_info "Uninstallation complete!"
log_info "Reboot recommended"
