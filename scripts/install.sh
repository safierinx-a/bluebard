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

# Function to run a command as the actual user with proper D-Bus session
run_as_user() {
    # Get user's runtime directory
    USER_RUNTIME_DIR="/run/user/$(id -u "$ACTUAL_USER")"
    USER_HOME="/home/$ACTUAL_USER"
    
    # Ensure runtime directory exists and has correct permissions
    mkdir -p "$USER_RUNTIME_DIR"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$USER_RUNTIME_DIR"
    chmod 700 "$USER_RUNTIME_DIR"

    # Ensure config directories exist
    mkdir -p "$USER_HOME/.config/systemd/user"
    mkdir -p "$USER_HOME/.config/pipewire"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/.config"

    # Run the command with proper environment
    sudo -u "$ACTUAL_USER" \
        HOME="$USER_HOME" \
        XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" \
        XDG_CONFIG_HOME="$USER_HOME/.config" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_RUNTIME_DIR/bus" \
        "$@"
}

# Install required packages
echo "Installing required packages..."
apt-get update

# Install D-Bus and utilities first
apt-get install -y dbus pulseaudio-utils

# Start D-Bus system daemon if not running
if ! systemctl is-active --quiet dbus; then
    systemctl start dbus
fi

# First, try to install pipewire-media-session as it might be needed
apt-get install -y pipewire-media-session || true

# Install core packages
apt-get install -y \
    pipewire \
    pipewire-bin \
    pipewire-audio-client-libraries \
    pipewire-pulse \
    wireplumber \
    libspa-0.2-bluetooth \
    libspa-0.2-jack \
    libspa-0.2-modules \
    gstreamer1.0-pipewire \
    bluez \
    python3-dbus \
    python3-gi

# Remove conflicting packages
echo "Removing conflicting packages..."
apt-get remove -y pulseaudio pulseaudio-module-bluetooth || true
apt-get autoremove -y

# Kill any existing PipeWire processes
echo "Cleaning up existing processes..."
pkill -u "$ACTUAL_USER" -9 pipewire || true
pkill -u "$ACTUAL_USER" -9 wireplumber || true
sleep 1

# Ensure D-Bus session is running for the user
echo "Setting up D-Bus session..."
if ! run_as_user dbus-launch --sh-syntax > /dev/null; then
    echo "Warning: Could not start D-Bus session"
fi

# Stop and disable PulseAudio for the user
echo "Disabling PulseAudio..."
run_as_user systemctl --user stop pulseaudio.service pulseaudio.socket || true
run_as_user systemctl --user disable pulseaudio.service pulseaudio.socket || true
run_as_user systemctl --user mask pulseaudio.service pulseaudio.socket || true

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

# Configure PipeWire
echo "Configuring PipeWire..."
cat > "/home/$ACTUAL_USER/.config/pipewire/pipewire.conf" << EOF
context.properties = {
    link.max-buffers = 16
    core.daemon = true
    core.name = pipewire-0
    vm.overrides = { default.clock.min-quantum = 1024 }
}

context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    api.alsa.* = alsa/libspa-alsa
    api.v4l2.* = v4l2/libspa-v4l2
    api.bluez5.* = bluez5/libspa-bluez5
}

context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-session-manager }
]
EOF

chown -R "$ACTUAL_USER:$ACTUAL_USER" "/home/$ACTUAL_USER/.config/pipewire"

# Restart Bluetooth service
systemctl restart bluetooth

# Clean up any existing PipeWire configuration that might cause conflicts
echo "Cleaning up existing PipeWire configuration..."
rm -rf "/home/$ACTUAL_USER/.config/systemd/user/pipewire*" || true
rm -rf "/home/$ACTUAL_USER/.config/systemd/user/wireplumber*" || true
rm -f "/run/user/$(id -u "$ACTUAL_USER")/pipewire-*" || true

# Reload systemd user daemon
run_as_user systemctl --user daemon-reload

# Start D-Bus user session if not running
run_as_user systemctl --user start dbus.socket || true
run_as_user systemctl --user start dbus.service || true

# Enable and start PipeWire services for the user
echo "Starting PipeWire services..."
run_as_user systemctl --user --now enable pipewire.socket
sleep 2
run_as_user systemctl --user --now enable pipewire.service
sleep 2
run_as_user systemctl --user --now enable wireplumber.service
sleep 2
run_as_user systemctl --user --now enable pipewire-pulse.socket
sleep 2
run_as_user systemctl --user --now enable pipewire-pulse.service
sleep 2

# Verify installation
echo "Verifying installation..."
sleep 2

# Check PipeWire status with more detailed error reporting
if ! run_as_user pw-cli info 2>/dev/null | grep -q "PipeWire"; then
    echo "Error: PipeWire is not running correctly"
    echo "Checking service status..."
    run_as_user systemctl --user status pipewire.service
    run_as_user systemctl --user status wireplumber.service
    run_as_user systemctl --user status pipewire-pulse.service
    exit 1
fi

# Check Bluetooth status
if ! systemctl is-active --quiet bluetooth; then
    echo "Error: Bluetooth service is not running"
    systemctl status bluetooth
    exit 1
fi

echo "Installation complete!"
echo "You may need to log out and log back in for all changes to take effect."
echo "To test the setup, run: python3 -m bluebard.tools.test_audio"