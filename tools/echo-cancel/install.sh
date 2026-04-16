#!/bin/bash
#
# WM8960 Echo Canceller — Install Script
#
# Two echo cancellation engines available:
#   webrtc (default) — WebRTC AEC3, ~30dB+ attenuation, requires snd-aloop
#   speex            — SpeexDSP, ~15dB attenuation, FIFO-based, no snd-aloop needed
#
# Usage: sudo ./install.sh [webrtc|speex] [--uninstall]

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="wm8960-echo-cancel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ALOOP_DKMS_SRC="${SCRIPT_DIR}/../../dkms/snd-aloop"

log() { echo "[EC] $1"; }
log_error() { echo "[EC] ERROR: $1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (sudo)"
    exit 1
fi

# Parse arguments
UNINSTALL=0
ENGINE="webrtc"
for arg in "$@"; do
    case "$arg" in
        --uninstall) UNINSTALL=1 ;;
        webrtc|speex) ENGINE="$arg" ;;
        *) log_error "Unknown argument: $arg"; echo "Usage: sudo ./install.sh [webrtc|speex] [--uninstall]" >&2; exit 1 ;;
    esac
done

# --- Uninstall ---
if [ "$UNINSTALL" -eq 1 ]; then
    log "Uninstalling echo canceller..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    rm -f /usr/local/bin/wm8960-ec
    rm -f /usr/local/bin/wm8960-ec-webrtc
    rm -f /tmp/ec.input /tmp/ec.output
    rm -f /etc/alsa/conf.d/50-aec.conf
    rm -f /etc/modules-load.d/snd-aloop.conf
    systemctl daemon-reload
    log "Echo canceller uninstalled"
    exit 0
fi


log "Installing $ENGINE echo canceller..."

# --- Install dependencies ---
log "Installing dependencies..."
apt-get update -qq
if [ "$ENGINE" = "webrtc" ]; then
    apt-get install -y -qq libasound2-dev libspeexdsp-dev libwebrtc-audio-processing-dev build-essential pkg-config sox dkms >/dev/null
else
    apt-get install -y -qq libasound2-dev libspeexdsp-dev build-essential pkg-config sox >/dev/null
fi

# --- Build snd-aloop for WebRTC ---
if [ "$ENGINE" = "webrtc" ]; then
    if ! lsmod | grep -q snd_aloop; then
        if [ -d "$ALOOP_DKMS_SRC" ]; then
            log "Building snd-aloop kernel module via DKMS..."
            rm -rf /usr/src/snd-aloop-1.0
            cp -r "$ALOOP_DKMS_SRC" /usr/src/snd-aloop-1.0
            dkms remove snd-aloop/1.0 --all 2>/dev/null || true
            dkms add snd-aloop/1.0
            dkms install snd-aloop/1.0
        else
            log "Warning: DKMS source not found at '$ALOOP_DKMS_SRC', trying system module..."
        fi
        modprobe snd-aloop || {
            log_error "Failed to load snd-aloop module"
            exit 1
        }
    fi
    # Persist module across reboots
    if ! grep -qE "^snd[-_]aloop" /etc/modules-load.d/*.conf 2>/dev/null && ! grep -qE "^snd[-_]aloop" /etc/modules 2>/dev/null; then
        echo "snd-aloop" > /etc/modules-load.d/snd-aloop.conf
    fi
    log "snd-aloop loaded"

    # Install ALSA AEC config
    if [ -f "${SCRIPT_DIR}/../../configs/alsa-aec.conf" ]; then
        mkdir -p /etc/alsa/conf.d
        cp "${SCRIPT_DIR}/../../configs/alsa-aec.conf" /etc/alsa/conf.d/50-aec.conf
        log "ALSA AEC config installed"
    fi
fi

# --- Build ---
log "Building..."
cd "${SCRIPT_DIR}"
make clean >/dev/null 2>&1 || true
if [ "$ENGINE" = "webrtc" ]; then
    make webrtc
else
    make speex
fi

# --- Install binary ---
log "Installing binary..."
if [ "$ENGINE" = "webrtc" ]; then
    install -D -m 755 wm8960-ec-webrtc /usr/local/bin/wm8960-ec-webrtc
else
    install -D -m 755 wm8960-ec /usr/local/bin/wm8960-ec
fi

# --- Create systemd service ---
log "Creating systemd service..."
if [ "$ENGINE" = "webrtc" ]; then
    cat > "${SERVICE_FILE}" << 'SVCEOF'
[Unit]
Description=WM8960 Echo Cancellation (WebRTC AEC3)
After=sound.target wm8960-audio.service
Requires=wm8960-audio.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wm8960-ec-webrtc -i hw:Loopback,1,0 -o hw:Loopback,0,1 -m dsnooper -p plughw:ahub0wm8960,0 -r 48000 -n 1
Restart=always
RestartSec=3
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
SVCEOF
else
    cat > "${SERVICE_FILE}" << 'SVCEOF'
[Unit]
Description=WM8960 Echo Cancellation (SpeexDSP)
After=sound.target wm8960-audio.service
Requires=wm8960-audio.service

[Service]
Type=simple
ExecStartPre=/bin/rm -f /tmp/ec.input /tmp/ec.output
ExecStart=/usr/local/bin/wm8960-ec -i default -o default -r 48000 -c 1 -d 0 -f 4096
Restart=always
RestartSec=3
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
SVCEOF
fi

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

log ""
log "Echo canceller ($ENGINE) installed and running!"
log ""
if [ "$ENGINE" = "webrtc" ]; then
    log "Usage:"
    log "  Play audio:   aplay -D hw:Loopback,0,0 audio.wav"
    log "  Record clean: arecord -D hw:Loopback,1,1 -r 48000 -c 1 -f S16_LE recording.wav"
    log ""
    log "  Or use the 'aec' ALSA device (if alsa-aec.conf is installed):"
    log "  Play audio:   aplay -D aec audio.wav"
    log "  Record clean: arecord -D aec -r 48000 -c 1 -f S16_LE recording.wav"
else
    log "Usage:"
    log "  Record echo-cancelled audio:"
    log "    timeout 5 dd if=/tmp/ec.output of=recording.raw bs=96000"
    log "    sox -t raw -r 48000 -c 1 -b 16 -e signed recording.raw recording.wav"
    log ""
    log "  Play audio through the echo canceller:"
    log "    cat audio.raw > /tmp/ec.input"
fi
log ""
log "  Check status:  systemctl status ${SERVICE_NAME}"
log "  Uninstall:     sudo ./install.sh --uninstall"
