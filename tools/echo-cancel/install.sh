#!/bin/bash
#
# WM8960 Echo Canceller — Install Script
#
# Builds the SpeexDSP-based echo canceller from source, installs the binary,
# and sets up a systemd service for automatic operation.
#
# Usage: sudo ./install.sh [--uninstall]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="wm8960-echo-cancel"
INSTALL_BIN="/usr/local/bin/wm8960-ec"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Default device — auto-detect WM8960 card name
WM8960_CARD="plughw:ahub0wm8960,0"

log() { echo "[EC] $1"; }
log_error() { echo "[EC] ERROR: $1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (sudo)"
    exit 1
fi

# --- Uninstall ---
if [ "${1}" = "--uninstall" ]; then
    log "Uninstalling echo canceller..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    rm -f "${INSTALL_BIN}"
    rm -f /tmp/ec.input /tmp/ec.output
    systemctl daemon-reload
    log "Echo canceller uninstalled"
    exit 0
fi

# --- Install dependencies ---
log "Installing build dependencies..."
apt-get update -qq
apt-get install -y -qq libasound2-dev libspeexdsp-dev build-essential pkg-config >/dev/null

# --- Build ---
log "Building echo canceller..."
cd "${SCRIPT_DIR}"
make clean >/dev/null 2>&1 || true
make

# --- Install binary ---
log "Installing binary to ${INSTALL_BIN}..."
make install

# --- Create systemd service ---
log "Creating systemd service..."
cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=WM8960 Acoustic Echo Cancellation (SpeexDSP)
After=sound.target wm8960-audio.service
Requires=wm8960-audio.service

[Service]
Type=simple
ExecStartPre=/bin/rm -f /tmp/ec.input /tmp/ec.output
ExecStart=${INSTALL_BIN} -i ${WM8960_CARD} -o ${WM8960_CARD} -r 16000 -c 2 -d 200 -f 4096
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

log "Echo canceller installed and running!"
log ""
log "Usage:"
log "  Record echo-cancelled audio:"
log "    arecord -D wm8960_ec -r 16000 -c 2 -f S16_LE -d 5 recording.wav"
log ""
log "  Play audio through the echo canceller:"
log "    cat audio.raw > /tmp/ec.input"
log ""
log "  Check status:"
log "    systemctl status ${SERVICE_NAME}"
log ""
log "  Uninstall:"
log "    sudo ./install.sh --uninstall"
