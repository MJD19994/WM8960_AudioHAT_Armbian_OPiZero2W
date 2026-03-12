#!/bin/bash
#
# Armbian Installation Script for Orange Pi Zero 2W (H618)
#
# This script installs and configures the WM8960 audio codec support
# including device tree patching, PLL configuration service, and ALSA settings.
#

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
        echo -e "${YELLOW}[DEBUG]${NC} $1"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Map commands to their apt packages
    local -A CMD_PKG=(
        [dtc]="device-tree-compiler"
        [fdtoverlay]="device-tree-compiler"
        [fdtget]="device-tree-compiler"
        [amixer]="alsa-utils"
    )

    # Check for required commands, install missing packages
    local missing_pkgs=()
    for cmd in dtc fdtoverlay fdtget amixer systemctl; do
        if ! command -v "$cmd" &> /dev/null; then
            local pkg="${CMD_PKG[$cmd]:-}"
            if [ -n "$pkg" ]; then
                log_warn "Required command '$cmd' not found — will install '$pkg'"
                # Avoid duplicate package names
                local already=false
                for p in "${missing_pkgs[@]}"; do
                    [ "$p" = "$pkg" ] && already=true
                done
                $already || missing_pkgs+=("$pkg")
            else
                log_error "Required command '$cmd' not found and no package mapping available"
                exit 1
            fi
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_info "Installing missing packages: ${missing_pkgs[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing_pkgs[@]}" || {
            log_error "Failed to install required packages"
            exit 1
        }
    fi

    # Check kernel version
    KERNEL_VER=$(uname -r)
    log_info "Detected kernel: $KERNEL_VER"

    # Check for pending kernel update (running kernel vs installed kernel mismatch)
    # If a kernel update was installed via apt but the system hasn't rebooted,
    # DKMS would build for the old kernel. The next boot's DKMS auto-rebuild
    # would catch it, but better to warn the user early.
    local installed_ver
    installed_ver=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii.*linux-image-[0-9]/{print $2}' | sed 's/linux-image-//' | sort -V | tail -1)
    if [ -n "$installed_ver" ] && [ "$installed_ver" != "$KERNEL_VER" ]; then
        log_warn "=============================================="
        log_warn "Kernel update pending reboot"
        log_warn "=============================================="
        echo ""
        echo "  Running kernel:   $KERNEL_VER"
        echo "  Installed kernel: $installed_ver"
        echo ""
        echo "A kernel update has been installed but not yet loaded."
        echo "If you continue, DKMS will build for the OLD kernel and"
        echo "will need to rebuild after reboot (adds ~30s to boot)."
        echo ""
        echo "Recommended: reboot first, then re-run this script."
        echo ""
        if [ -t 0 ]; then
            read -rp "Continue anyway? (y/N) " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                log_info "Exiting. Please reboot and re-run: sudo ./install.sh"
                exit 1
            fi
            log_info "Continuing with running kernel $KERNEL_VER..."
        else
            log_warn "Non-interactive mode: continuing with running kernel $KERNEL_VER"
            log_warn "(Boot-time DKMS rebuild will handle the new kernel automatically)"
        fi
        echo ""
    fi
}

install_dkms_module() {
    # Skip if our DKMS module is already installed for the running kernel
    local kver
    kver=$(uname -r)
    if dkms status wm8960-audio-hat/1.0 -k "$kver" 2>/dev/null | grep -q installed; then
        log_info "WM8960 DKMS module already installed for ${kver} — skipping"
        return 0
    fi

    log_info "Installing WM8960 kernel module via DKMS..."

    # Install DKMS if not present
    if ! command -v dkms &>/dev/null; then
        log_info "Installing dkms package..."
        apt-get update -qq
        apt-get install -y -qq dkms
    fi

    # Ensure kernel headers are available
    if [ ! -d "/lib/modules/${kver}/build" ]; then
        # Armbian: install from apt
        log_info "Installing kernel headers from apt..."
        apt-get update -qq
        local headers_pkg=""
        if apt-cache show linux-headers-current-sunxi64 >/dev/null 2>&1; then
            headers_pkg="linux-headers-current-sunxi64"
        elif apt-cache show "linux-headers-${kver}" >/dev/null 2>&1; then
            headers_pkg="linux-headers-${kver}"
        fi
        if [ -n "$headers_pkg" ]; then
            apt-get install -y -qq "$headers_pkg"
        else
            log_error "Cannot find kernel headers package for ${kver}"
            log_error "Install headers manually: apt install linux-headers-..."
            exit 1
        fi
    fi
    log_debug "Kernel headers: /lib/modules/${kver}/build"

    # Install build tools if missing
    if ! command -v make &>/dev/null || ! command -v gcc &>/dev/null; then
        log_info "Installing build tools..."
        apt-get update -qq
        apt-get install -y -qq make gcc
    fi

    # Copy DKMS source tree
    local dkms_src="/usr/src/wm8960-audio-hat-1.0"
    rm -rf "$dkms_src"
    mkdir -p "$dkms_src"
    cp "$SCRIPT_DIR/dkms/wm8960.c" "$dkms_src/"
    cp "$SCRIPT_DIR/dkms/wm8960.h" "$dkms_src/"
    cp "$SCRIPT_DIR/dkms/Makefile" "$dkms_src/"
    cp "$SCRIPT_DIR/dkms/dkms.conf" "$dkms_src/"

    # Remove any previous DKMS registration
    if dkms status wm8960-audio-hat/1.0 2>/dev/null | grep -q .; then
        log_debug "Removing previous DKMS registration..."
        dkms remove wm8960-audio-hat/1.0 --all 2>/dev/null || true
    fi

    # Add, build, install
    log_info "Building WM8960 module with DKMS..."
    dkms add wm8960-audio-hat/1.0 || { log_error "DKMS add failed"; exit 1; }
    dkms build wm8960-audio-hat/1.0 || { log_error "DKMS build failed"; exit 1; }
    dkms install wm8960-audio-hat/1.0 || { log_error "DKMS install failed"; exit 1; }

    log_info "WM8960 kernel module installed via DKMS"
}

patch_dtb() {
    log_info "Patching device tree for WM8960 audio support..."

    # Find the DTB directory — prefer /boot/dtb (symlink the bootloader actually uses)
    # to avoid patching a stale tree when multiple DTB directories exist
    if [ -L /boot/dtb ] || [ -d /boot/dtb ]; then
        DTB_BASE=$(readlink -f /boot/dtb)
        DTB_DIR=$(find "$DTB_BASE" -type d -name "allwinner" 2>/dev/null | head -1)
    fi
    if [ -z "$DTB_DIR" ]; then
        DTB_DIR=$(find /boot -type d -name "allwinner" -path "*/dtb*" 2>/dev/null | head -1)
    fi
    if [ -z "$DTB_DIR" ]; then
        log_error "Could not find allwinner DTB directory under /boot"
        exit 1
    fi
    log_info "Found DTB directory: $DTB_DIR"

    # Find the board's base DTB
    BASE_DTB=$(find "$DTB_DIR" -maxdepth 1 -name "sun50i-h61*-orangepi-zero2w.dtb" ! -name "*wm8960*" ! -name "*.backup" 2>/dev/null | head -1)
    if [ -z "$BASE_DTB" ]; then
        # DTB may already be a symlink to the wm8960 variant from a previous install
        BASE_DTB=$(find "$DTB_DIR" -maxdepth 1 -name "sun50i-h61*-orangepi-zero2w.dtb" 2>/dev/null | head -1)
    fi

    if [ -z "$BASE_DTB" ]; then
        log_error "Could not find Orange Pi Zero 2W device tree"
        exit 1
    fi
    log_info "Found base DTB: $BASE_DTB"

    # Resolve symlink to get the real file
    REAL_DTB=$(readlink -f "$BASE_DTB")
    DTB_BASENAME=$(basename "$BASE_DTB" .dtb)
    log_debug "BASE_DTB=$BASE_DTB"
    log_debug "REAL_DTB=$REAL_DTB"
    log_debug "DTB_BASENAME=$DTB_BASENAME"
    log_debug "Is symlink: $([ -L "$BASE_DTB" ] && echo yes || echo no)"

    # Check if WM8960 is already patched
    if fdtget "$REAL_DTB" /soc/i2c@5002400/wm8960@1a compatible >/dev/null 2>&1; then
        log_info "Device tree already has WM8960 support — skipping patch"
        return 0
    fi

    # Create backup of original DTB (only if not already backed up)
    if [ ! -f "${BASE_DTB}.backup" ]; then
        log_info "Backing up original DTB..."
        cp "$REAL_DTB" "${BASE_DTB}.backup"
    fi

    # Validate backup is unpatched — if a previous install left a patched backup,
    # using it as input would double-patch the device tree
    INPUT_DTB="${BASE_DTB}.backup"
    if fdtget "$INPUT_DTB" /soc/i2c@5002400/wm8960@1a compatible >/dev/null 2>&1; then
        log_error "DTB backup is already patched — cannot determine clean base DTB"
        log_error "Restore an original DTB from your OS image and try again"
        exit 1
    fi

    # Select Armbian overlay
    DTS_SOURCE="$SCRIPT_DIR/overlays/sun50i-h618-wm8960-armbian.dts"
    if [ ! -f "$DTS_SOURCE" ]; then
        log_error "Overlay not found: $DTS_SOURCE"
        log_error "Available overlays:"
        find "$SCRIPT_DIR/overlays/" -name '*.dts' 2>/dev/null | while read -r f; do
            log_error "  $(basename "$f")"
        done
        exit 1
    fi

    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT

    log_debug "Overlay source: $DTS_SOURCE"
    log_debug "Work directory: $WORK_DIR"
    log_info "Compiling WM8960 overlay..."
    dtc -@ -I dts -O dtb -o "$WORK_DIR/wm8960.dtbo" "$DTS_SOURCE" || {
        log_error "Failed to compile WM8960 overlay"
        exit 1
    }

    # Apply overlay to base DTB using fdtoverlay
    PATCHED_DTB="$DTB_DIR/${DTB_BASENAME}-wm8960.dtb"

    log_debug "Input DTB: $INPUT_DTB"
    log_debug "Output DTB: $PATCHED_DTB"
    log_info "Applying WM8960 overlay to device tree..."
    fdtoverlay -i "$INPUT_DTB" -o "$PATCHED_DTB" "$WORK_DIR/wm8960.dtbo" || {
        log_error "Failed to apply overlay to device tree"
        rm -f "$PATCHED_DTB"
        exit 1
    }

    # Replace original DTB with symlink to patched version
    ln -sf "$(basename "$PATCHED_DTB")" "$BASE_DTB"
    log_info "Device tree patched: $(basename "$BASE_DTB") -> $(basename "$PATCHED_DTB")"

    # Verify the patch
    if fdtget "$PATCHED_DTB" /soc/i2c@5002400/wm8960@1a compatible >/dev/null 2>&1; then
        log_info "WM8960 node verified in patched device tree"
    else
        log_error "Verification failed — WM8960 node not found in patched DTB"
        log_error "Restoring backup..."
        rm -f "$PATCHED_DTB"
        rm -f "$BASE_DTB"
        cp "${BASE_DTB}.backup" "$BASE_DTB"
        exit 1
    fi
}

install_service() {
    log_info "Installing mixer configuration service..."

    # Remove legacy PLL script if present (from previous installs)
    rm -f /usr/local/bin/wm8960-pll-config.sh

    # Install script
    cp "$SCRIPT_DIR/service/wm8960-mixer-config.sh" /usr/local/bin/ || {
        log_error "Failed to copy configuration script"
        exit 1
    }
    chmod +x /usr/local/bin/wm8960-mixer-config.sh

    # Install service file
    cp "$SCRIPT_DIR/service/wm8960-audio.service" /etc/systemd/system/ || {
        log_error "Failed to copy service file"
        exit 1
    }

    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable wm8960-audio.service || {
        log_error "Failed to enable service"
        exit 1
    }

    log_info "Service installed and enabled"
}

install_alsa_config() {
    log_info "Installing ALSA configuration..."

    # Install ALSA config (back up existing config on first install)
    if [ -f "$SCRIPT_DIR/configs/asound.conf" ]; then
        if [ -f /etc/asound.conf ] && [ ! -f /etc/asound.conf.wm8960-backup ]; then
            cp /etc/asound.conf /etc/asound.conf.wm8960-backup
            log_info "Backed up existing /etc/asound.conf"
        fi
        cp "$SCRIPT_DIR/configs/asound.conf" /etc/asound.conf || log_warn "Failed to install asound.conf"
    fi

    log_info "ALSA configuration installed"
}

# Detect audio server: PipeWire, PulseAudio, or bare ALSA
# Uses package detection (works headless, no running server needed).
# Checks pipewire-pulse (not just pipewire) because some distros install
# the pipewire library as a dependency without using it as the audio server.
# pipewire-pulse means PipeWire is actively replacing PulseAudio.
AUDIO_STACK="alsa"
detect_audio_stack() {
    if dpkg-query -W -f='${Status}' pipewire-pulse 2>/dev/null | grep -q "install ok installed"; then
        AUDIO_STACK="pipewire"
        log_info "Detected audio stack: PipeWire"
    elif dpkg-query -W -f='${Status}' pulseaudio 2>/dev/null | grep -q "install ok installed"; then
        AUDIO_STACK="pulseaudio"
        log_info "Detected audio stack: PulseAudio"
    else
        AUDIO_STACK="alsa"
        log_info "Detected audio stack: bare ALSA"
    fi
    log_debug "AUDIO_STACK=$AUDIO_STACK"
}

install_pipewire_config() {
    log_info "Installing PipeWire/WirePlumber configuration..."

    # PipeWire rate lock
    mkdir -p /etc/pipewire/pipewire.conf.d
    if [ ! -f /etc/pipewire/pipewire.conf.d/10-wm8960-rate.conf ]; then
        cp "$SCRIPT_DIR/configs/pipewire-rate.conf" /etc/pipewire/pipewire.conf.d/10-wm8960-rate.conf
        log_info "Installed PipeWire rate config"
    else
        log_info "PipeWire rate config already exists — skipping"
    fi

    # WirePlumber priority rules
    mkdir -p /etc/wireplumber/wireplumber.conf.d
    if [ ! -f /etc/wireplumber/wireplumber.conf.d/51-wm8960.conf ]; then
        cp "$SCRIPT_DIR/configs/wireplumber-wm8960.conf" /etc/wireplumber/wireplumber.conf.d/51-wm8960.conf
        log_info "Installed WirePlumber priority rules"
    else
        log_info "WirePlumber config already exists — skipping"
    fi
}

install_pulseaudio_config() {
    log_info "Installing PulseAudio configuration..."

    # Daemon config drop-in (locks sample rate to 48kHz, flat volumes)
    mkdir -p /etc/pulse/daemon.conf.d
    if [ ! -f /etc/pulse/daemon.conf.d/10-wm8960.conf ]; then
        cp "$SCRIPT_DIR/configs/pulse-daemon.conf" /etc/pulse/daemon.conf.d/10-wm8960.conf
        log_info "Installed PulseAudio daemon config"
    else
        log_info "PulseAudio daemon config already exists — skipping"
    fi

    # udev rule assigns our custom PA profile set for the WM8960 card
    cp "$SCRIPT_DIR/configs/91-wm8960-pulseaudio.rules" /etc/udev/rules.d/
    log_info "Installed PulseAudio udev rule"

    # Custom profile set and path files — maps WM8960's mixer elements
    # so PA provides hardware volume control without resetting mixer levels
    cp "$SCRIPT_DIR/configs/wm8960-audiohat.conf" /usr/share/pulseaudio/alsa-mixer/profile-sets/
    cp "$SCRIPT_DIR/configs/wm8960-output.conf" /usr/share/pulseaudio/alsa-mixer/paths/
    cp "$SCRIPT_DIR/configs/wm8960-input.conf" /usr/share/pulseaudio/alsa-mixer/paths/
    log_info "Installed PulseAudio profile set and mixer paths"
}

record_installed_stack() {
    echo "AUDIO_STACK=$AUDIO_STACK" > /etc/wm8960-audio-stack.conf
    log_debug "Recorded AUDIO_STACK=$AUDIO_STACK to /etc/wm8960-audio-stack.conf"
}

print_next_steps() {
    echo ""
    log_info "Installation complete!"
    echo ""
    echo "Next steps:"
    echo "1. Reboot: sudo reboot"
    echo "2. After reboot, test audio with:"
    case "$AUDIO_STACK" in
        pipewire)
            echo "   wpctl status                    # verify WM8960 is default"
            echo "   speaker-test -c 2 -r 48000 -t sine -f 1000 -l 1"
            ;;
        pulseaudio)
            echo "   pactl info | grep 'Default Sink'  # verify WM8960 is default"
            echo "   speaker-test -c 2 -r 48000 -t sine -f 1000 -l 1"
            ;;
        *)
            echo "   speaker-test -D default -c 2 -r 48000 -t sine -f 1000 -l 1"
            ;;
    esac
    echo ""
    echo "Notes:"
    echo "- Sound card name: ahub0wm8960"
    echo "- Audio stack: $AUDIO_STACK"
    echo "- Both headphones and speaker will work simultaneously"
    echo "- Service status: systemctl status wm8960-audio.service"
    echo "- Logs: journalctl -u wm8960-audio.service"
    echo ""
}

# Main installation
log_info "WM8960 Audio HAT Installation for Armbian (Orange Pi Zero 2W)"
echo ""

check_root
check_prerequisites
install_dkms_module
patch_dtb
install_service
install_alsa_config
detect_audio_stack
case "$AUDIO_STACK" in
    pipewire)   install_pipewire_config ;;
    pulseaudio) install_pulseaudio_config ;;
    alsa)       log_debug "Bare ALSA — no audio server config needed" ;;
esac
record_installed_stack
print_next_steps

exit 0
