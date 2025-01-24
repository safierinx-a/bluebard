#!/bin/bash

# Check if script is run with sudo
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Please run with: sudo $0"
    exit 1
fi

# Get the actual user who invoked sudo
ACTUAL_USER=$SUDO_USER
if [ -z "$ACTUAL_USER" ]; then
    echo "Could not determine the actual user. Please run with sudo."
    exit 1
fi

# Get user's home directory
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
if [ -z "$USER_HOME" ]; then
    echo "Could not determine user's home directory."
    exit 1
fi

echo "Installing Bluebard Audio System..."

# Function to run a command as the actual user
run_as_user() {
    sudo -u "$ACTUAL_USER" "$@"
}

# Function to run a command as root
run_as_root() {
    "$@"
}

# Create necessary directories with proper permissions
echo "Setting up system directories..."
run_as_root mkdir -p /etc/bluebard
run_as_root chown root:root /etc/bluebard
run_as_root chmod 755 /etc/bluebard

# Backup configurations
echo "Backing up existing configurations..."
BACKUP_DIR="/etc/bluebard/backups/$(date +%Y%m%d_%H%M%S)"
run_as_root mkdir -p "$BACKUP_DIR"
[ -f /etc/pulse/default.pa ] && run_as_root cp /etc/pulse/default.pa "$BACKUP_DIR/"
[ -f /etc/asound.conf ] && run_as_root cp /etc/asound.conf "$BACKUP_DIR/"
[ -f /etc/bluetooth/main.conf ] && run_as_root cp /etc/bluetooth/main.conf "$BACKUP_DIR/"

# Stop all existing audio services
echo "Stopping audio services..."
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user stop pipewire-pulse.service 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user stop pipewire.service 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user stop wireplumber.service 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user disable pipewire-pulse.service 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user disable pipewire.service 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user disable wireplumber.service 2>/dev/null || true

run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user stop pulseaudio.service pulseaudio.socket 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user disable pulseaudio.service pulseaudio.socket 2>/dev/null || true
run_as_root systemctl stop pulseaudio.service pulseaudio.socket 2>/dev/null || true
run_as_root systemctl disable pulseaudio.service pulseaudio.socket 2>/dev/null || true
run_as_root systemctl stop bluealsa.service 2>/dev/null || true
run_as_root systemctl disable bluealsa.service 2>/dev/null || true

# Remove existing audio packages
echo "Removing existing audio packages..."
run_as_root apt-get remove --purge -y \
    pulseaudio \
    pulseaudio-* \
    libpulse* \
    bluealsa \
    bluealsa-* \
    libasound2-plugin-bluez || true

run_as_root apt-get autoremove -y

# Clean up old configurations and state
echo "Cleaning up old configurations..."
run_as_root rm -rf \
    /etc/pulse \
    /etc/asound.conf \
    /etc/bluetooth/audio.conf \
    /var/lib/pulse \
    /var/lib/bluealsa \
    /etc/systemd/system/bluealsa.service \
    /etc/systemd/system/bluealsa-aplay.service

# Clean up user-specific audio configurations
echo "Cleaning up user configurations..."
run_as_user rm -rf \
    "$USER_HOME/.config/pulse" \
    "$USER_HOME/.pulse" \
    "$USER_HOME/.pulse-cookie" \
    "$USER_HOME/.config/systemd/user/pulseaudio"*

# Update package lists
echo "Updating package lists..."
run_as_root apt-get update

# Install required packages
echo "Installing required packages..."
run_as_root apt-get install -y \
    bluez \
    bluetooth \
    bluez-tools \
    alsa-utils \
    pipewire \
    pipewire-audio \
    wireplumber \
    pipewire-pulse \
    pipewire-alsa \
    pipewire-jack \
    pipewire-v4l2 \
    pipewire-bin \
    libspa-0.2-bluetooth \
    libspa-0.2-jack \
    python3-dbus \
    python3-gi \
    python3-setuptools \
    python3-wheel

# Install Python package system-wide
echo "Installing Bluebard package..."
run_as_root pip3 install --break-system-packages -e .

# Configure Bluetooth
echo "Configuring Bluetooth..."

# Fix Bluetooth configuration directory permissions
run_as_root mkdir -p /etc/bluetooth
run_as_root chmod 555 /etc/bluetooth
run_as_root chown root:root /etc/bluetooth

# Update Bluetooth service to use correct daemon path
echo "Configuring Bluetooth service..."
BLUETOOTHD_PATH=$(command -v bluetoothd)
if [ -z "$BLUETOOTHD_PATH" ]; then
    echo "Error: bluetoothd not found. Please ensure bluez is installed correctly."
    exit 1
fi

run_as_root mkdir -p /etc/systemd/system/bluetooth.service.d
run_as_root install -m 644 /dev/stdin /etc/systemd/system/bluetooth.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=$BLUETOOTHD_PATH --experimental
Environment=PULSE_RUNTIME_PATH=/run/user/$(id -u "$ACTUAL_USER")/pulse
EOF

run_as_root install -m 644 /dev/stdin /etc/bluetooth/main.conf << EOF
[General]
Class = 0x200414  # Audio device
Name = Bluebard Audio
DiscoverableTimeout = 0
Discoverable = true
Enable=Source,Sink,Media,Socket,Gateway
FastConnectable=true
Experimental = true

[Policy]
AutoEnable=true
ReconnectAttempts=7
ReconnectIntervals=1,2,4,8,16,32,64

[GATT]
KeySize=16
ExchangeMTU=517
EOF

# Configure PipeWire
echo "Configuring PipeWire..."
run_as_root mkdir -p /etc/pipewire/pipewire.conf.d
run_as_root install -m 644 /dev/stdin /etc/pipewire/pipewire.conf.d/99-bluebard.conf << EOF
{
    "context.properties": {
        "default.clock.rate": 48000,
        "default.clock.quantum": 1024,
        "default.clock.min-quantum": 32,
        "default.clock.max-quantum": 8192,
        "support.dbus": true,
        "log.level": 2
    },
    "context.modules": [
        {
            "name": "libpipewire-module-protocol-native"
        },
        {
            "name": "libpipewire-module-client-node"
        },
        {
            "name": "libpipewire-module-adapter"
        },
        {
            "name": "libpipewire-module-metadata"
        },
        {
            "name": "libpipewire-module-session-manager"
        }
    ],
    "pulse.properties": {
        "server.address": [ "unix:/run/user/$(id -u "$ACTUAL_USER")/pulse/native" ]
    },
    "pulse.properties.rules": [
        {
            "matches": [ { "device.name": "~bluez_*" } ],
            "actions": {
                "update-props": {
                    "bluez5.autoswitch-profile": true,
                    "bluez5.profile": "a2dp-sink",
                    "bluez5.roles": [ "sink" ],
                    "bluez5.reconnect-profiles": [ "a2dp_sink", "headset_head_unit" ],
                    "bluez5.codecs": [ "aac", "sbc_xq", "sbc" ],
                    "api.alsa.period-size": 1024,
                    "api.alsa.headroom": 8192
                }
            }
        }
    ]
}
EOF

# Set up WirePlumber configuration
echo "Setting up WirePlumber configuration..."
run_as_root mkdir -p /etc/wireplumber/main.lua.d
run_as_root install -m 644 /dev/stdin /etc/wireplumber/main.lua.d/51-bluebard.lua << EOF
bluez_monitor.properties = {
  ["bluez5.enable-sbc-xq"] = true,
  ["bluez5.enable-msbc"] = true,
  ["bluez5.enable-hw-volume"] = true,
  ["bluez5.headset-roles"] = "[ sink, source ]",
  ["bluez5.hfphsp-backend"] = "native"
}

stream.properties = {
  ["resample.quality"] = 7,
  ["resample.disable"] = false,
  ["channelmix.normalize"] = true,
  ["channelmix.mix-lfe"] = false,
  ["dither.noise"] = -90
}
EOF

# Enable and start PipeWire for the user
echo "Setting up PipeWire services..."
# First enable all services
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user enable pipewire.socket pipewire-pulse.socket
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user enable pipewire.service pipewire-pulse.service wireplumber.service filter-chain.service

# Then start them in the correct order
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start pipewire.socket
sleep 1
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start pipewire.service
sleep 1
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start wireplumber.service
sleep 1
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start filter-chain.service
sleep 1
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start pipewire-pulse.socket pipewire-pulse.service

# Add user to required groups
echo "Adding user to required groups..."
run_as_root usermod -a -G bluetooth,audio "$ACTUAL_USER"

# Verify installation
echo "Verifying installation..."
sleep 2  # Give services time to start

if ! run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") pactl info > /dev/null 2>&1; then
    echo "Warning: PipeWire audio server is not running properly"
    echo "Try running: systemctl --user restart pipewire pipewire-pulse"
else
    echo "PipeWire audio server is running"
fi

if ! run_as_user bluetoothctl show > /dev/null 2>&1; then
    echo "Warning: Bluetooth service is not running properly"
    echo "Try running: sudo systemctl restart bluetooth"
else
    echo "Bluetooth service is running"
fi

echo "Installation complete!"
echo "NOTE: You may need to log out and log back in for group changes to take effect."
echo "To test the setup, run: python3 -m bluebard.tools.test_audio" 