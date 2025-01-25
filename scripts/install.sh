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

# Check for interfering services
echo "Checking for interfering services..."
INTERFERING_SERVICES=()

# Check system services
for service in "audio-sync@*.service" "bluealsa.service"; do
    if systemctl is-active $service &>/dev/null; then
        INTERFERING_SERVICES+=("$service (system)")
    fi
done

# Check if audio-sync service exists and warn about it
if systemctl list-unit-files "audio-sync@*.service" &>/dev/null; then
    echo "Warning: Found old audio-sync service. Please remove it with:"
    echo "  sudo systemctl stop audio-sync@*.service"
    echo "  sudo systemctl disable audio-sync@*.service"
    echo "  sudo rm /etc/systemd/system/audio-sync@*.service"
    exit 1
fi

if [ ${#INTERFERING_SERVICES[@]} -gt 0 ]; then
    echo "Warning: Found potentially interfering services:"
    printf '%s\n' "${INTERFERING_SERVICES[@]}"
    echo "Please stop and disable these services before proceeding."
    echo "You can use these commands:"
    echo "  For system services: sudo systemctl stop SERVICE"
    echo "  For user services: systemctl --user stop SERVICE"
    exit 1
fi

# Ensure PipeWire cache directory exists with correct permissions
echo "Setting up PipeWire cache directory..."
run_as_root mkdir -p /var/cache/pipewire
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /var/cache/pipewire
run_as_root chmod 700 /var/cache/pipewire

# Also ensure XDG_RUNTIME_DIR exists and has correct permissions
echo "Setting up runtime directory..."
run_as_root mkdir -p /run/user/$(id -u "$ACTUAL_USER")
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /run/user/$(id -u "$ACTUAL_USER")
run_as_root chmod 700 /run/user/$(id -u "$ACTUAL_USER")

# Mask PulseAudio services to prevent them from starting
echo "Masking PulseAudio services..."
run_as_root systemctl mask pulseaudio.service pulseaudio.socket
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user mask pulseaudio.service pulseaudio.socket

# Remove system-level PulseAudio service
echo "Removing system-level PulseAudio service..."
run_as_root rm -f /etc/systemd/system/pulseaudio.service
run_as_root systemctl daemon-reload

# Remove only conflicting packages
echo "Removing conflicting packages..."
run_as_root apt-get remove --purge -y \
    bluealsa \
    bluealsa-* \
    libasound2-plugin-bluez || true

run_as_root apt-get autoremove -y

# Clean up old configurations and state
echo "Cleaning up old configurations..."
run_as_root rm -rf \
    /etc/bluetooth/audio.conf \
    /var/lib/bluealsa \
    /etc/systemd/system/bluealsa.service \
    /etc/systemd/system/bluealsa-aplay.service

# Clean up user-specific audio configurations
echo "Cleaning up user configurations..."
run_as_user rm -rf \
    "$USER_HOME/.config/systemd/user/pulseaudio"*

# Reload systemd to recognize removed packages
run_as_root systemctl daemon-reload

# Stop all existing audio services
echo "Stopping audio services..."
# Stop PipeWire services
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user stop pipewire-pulse.service 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user stop pipewire.service 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user stop wireplumber.service 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user disable pipewire-pulse.service 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user disable pipewire.service 2>/dev/null || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user disable wireplumber.service 2>/dev/null || true

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

# Reset any failed services before starting
echo "Resetting service states..."
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user reset-failed pipewire.socket pipewire-pulse.socket pipewire.service pipewire-pulse.service wireplumber.service filter-chain.service || true

# Enable and start PipeWire for the user
echo "Setting up PipeWire services..."

# First stop everything in reverse order
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user stop pipewire-pulse.service pipewire-pulse.socket filter-chain.service wireplumber.service pipewire.service pipewire.socket || true

# Clear any remaining sockets
run_as_root rm -rf /run/user/$(id -u "$ACTUAL_USER")/pipewire-* || true
run_as_root rm -rf /run/user/$(id -u "$ACTUAL_USER")/pulse || true

# Enable services
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user enable pipewire.socket
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user enable pipewire.service
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user enable wireplumber.service
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user enable pipewire-pulse.socket
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user enable pipewire-pulse.service

# Start in correct order with proper delays
echo "Starting PipeWire services..."
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start pipewire.socket
sleep 2  # Give socket time to initialize

run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start pipewire.service
sleep 2  # Give PipeWire time to initialize

# Check if PipeWire started successfully
if ! run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user is-active pipewire.service > /dev/null 2>&1; then
    echo "Error: PipeWire failed to start. Checking logs..."
    run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") journalctl --user -u pipewire.service --no-pager -n 50
    exit 1
fi

run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start wireplumber.service
sleep 2  # Give WirePlumber time to initialize

run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start pipewire-pulse.socket
sleep 1
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start pipewire-pulse.service

# Remove filter-chain for now as it's causing issues
# run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user start filter-chain.service

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