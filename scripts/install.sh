#!/bin/bash

set -e  # Exit on any error

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

# Install required packages
echo "Installing required packages..."
apt-get update
apt-get install -y \
    pipewire \
    pipewire-audio-client-libraries \
    pipewire-pulse \
    wireplumber \
    libspa-0.2-bluetooth \
    libspa-0.2-jack \
    bluez \
    python3-dbus \
    python3-gi

# Remove conflicting packages
echo "Removing conflicting packages..."
apt-get remove -y pulseaudio-module-bluetooth || true
apt-get autoremove -y

# Copy ALSA configuration
echo "Configuring ALSA..."
cp -f /usr/share/doc/pipewire/examples/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/ || true

# Copy JACK configuration
echo "Configuring JACK..."
cp -f /usr/share/doc/pipewire/examples/ld.so.conf.d/pipewire-jack-*.conf /etc/ld.so.conf.d/ || true
ldconfig

# Stop and disable PulseAudio for the user
echo "Disabling PulseAudio..."
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user stop pulseaudio.service pulseaudio.socket || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user disable pulseaudio.service pulseaudio.socket || true
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user mask pulseaudio.service pulseaudio.socket || true

# Configure Bluetooth for better audio
echo "Configuring Bluetooth..."
cat > /etc/bluetooth/main.conf << EOF
[General]
Class = 0x200414
ControllerMode = dual
FastConnectable = true
Enable = Source,Sink,Media,Socket

[Policy]
AutoEnable = true
ReconnectAttempts = 5
ReconnectIntervals = 1,2,4,8,16
EOF

# Restart Bluetooth service
systemctl restart bluetooth

# Enable and start PipeWire services for the user
echo "Starting PipeWire services..."
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user --now enable pipewire.service
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user --now enable pipewire-pulse.service
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") systemctl --user --now enable wireplumber.service

# Verify installation
echo "Verifying installation..."
sleep 2

# Check PipeWire status
if ! run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") pactl info | grep -q "Server Name.*PipeWire"; then
    echo "Error: PipeWire is not running correctly"
    exit 1
fi

# Check Bluetooth status
if ! systemctl is-active --quiet bluetooth; then
    echo "Error: Bluetooth service is not running"
    exit 1
fi

echo "Installation complete!"
echo "You may need to log out and log back in for all changes to take effect."
echo "To test the setup, run: python3 -m bluebard.tools.test_audio"