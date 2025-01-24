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
run_as_user systemctl --user stop pulseaudio.service pulseaudio.socket 2>/dev/null || true
run_as_user systemctl --user disable pulseaudio.service pulseaudio.socket 2>/dev/null || true
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
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
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
    python3 \
    python3-pip \
    python3-dbus \
    python3-gi \
    python3-setuptools \
    python3-wheel

# Install Python package for the user
echo "Installing Bluebard package..."
run_as_user pip3 install --user -e .

# Configure Bluetooth
echo "Configuring Bluetooth..."
run_as_root install -m 644 /dev/stdin /etc/bluetooth/main.conf << EOF
[General]
Class = 0x200414
Name = Bluebard Audio
DiscoverableTimeout = 0
Discoverable = true

[Policy]
AutoEnable = true
ReconnectAttempts = 3
ReconnectIntervals = 1,2,4
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
        "default.clock.max-quantum": 8192
    }
}
EOF

# Set up user PipeWire configuration
echo "Setting up user PipeWire configuration..."
run_as_user mkdir -p ~/.config/pipewire/pipewire.conf.d
run_as_user install -m 644 /dev/stdin ~/.config/pipewire/pipewire.conf.d/99-bluebard.conf << EOF
{
    "context.properties": {
        "default.clock.rate": 48000,
        "default.clock.quantum": 1024,
        "default.clock.min-quantum": 32,
        "default.clock.max-quantum": 8192
    }
}
EOF

# Restart Bluetooth service
echo "Restarting Bluetooth service..."
run_as_root systemctl restart bluetooth.service

# Enable and start PipeWire for the user
echo "Setting up PipeWire services..."
run_as_user systemctl --user enable pipewire.service pipewire-pulse.service
run_as_user systemctl --user start pipewire.service pipewire-pulse.service

# Add user to required groups
echo "Adding user to required groups..."
run_as_root usermod -a -G bluetooth,audio "$ACTUAL_USER"

# Verify installation
echo "Verifying installation..."
sleep 2  # Give services time to start

if ! run_as_user pactl info > /dev/null 2>&1; then
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