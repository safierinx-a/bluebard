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

# Set up PipeWire directories and permissions
echo "Setting up PipeWire directories..."

# Create and set permissions for runtime directories first
run_as_root mkdir -p /run/user/$(id -u "$ACTUAL_USER")
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /run/user/$(id -u "$ACTUAL_USER")
run_as_root chmod 700 /run/user/$(id -u "$ACTUAL_USER")

# Set up D-Bus session
echo "Setting up D-Bus session..."

# Check if D-Bus session is already running
DBUS_SESSION_BUS_PID=$(run_as_user pgrep -f "dbus-daemon.*--session" || true)
if [ -n "$DBUS_SESSION_BUS_PID" ]; then
    echo "Found existing D-Bus session (PID: $DBUS_SESSION_BUS_PID)"
    # Get the existing D-Bus address
    export DBUS_SESSION_BUS_ADDRESS=$(run_as_user grep -z DBUS_SESSION_BUS_ADDRESS /proc/$DBUS_SESSION_BUS_PID/environ | cut -d= -f2-)
else
    echo "Starting new D-Bus session..."
    # Kill any existing dbus-daemon processes for this user
    run_as_user pkill -f "dbus-daemon.*--session" || true
    sleep 1
    
    # Clean up existing socket
    run_as_root rm -f /run/user/$(id -u "$ACTUAL_USER")/bus || true
    
    # Start new D-Bus session
    eval $(run_as_user dbus-launch --sh-syntax)
    sleep 2
fi

# Verify D-Bus session
if ! run_as_user dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
    echo "Error: D-Bus session is not working properly"
    exit 1
else
    echo "D-Bus session is working properly"
fi

# Export the D-Bus session address for systemd user services
run_as_user mkdir -p "$USER_HOME/.config/environment.d"
cat << EOF > /tmp/dbus.conf.tmp
DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}
EOF

run_as_root install -m 644 /tmp/dbus.conf.tmp "$USER_HOME/.config/environment.d/dbus.conf"
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/.config/environment.d/dbus.conf"
rm -f /tmp/dbus.conf.tmp

# Export for current session
export DBUS_SESSION_BUS_ADDRESS

# Set up user config directories
run_as_user mkdir -p "$USER_HOME/.local/state/pipewire"
run_as_user mkdir -p "$USER_HOME/.local/share/pipewire"
run_as_user mkdir -p "$USER_HOME/.config/pipewire"
run_as_user mkdir -p "$USER_HOME/.config/systemd/user"

# Export required environment variables
export XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")

# Start D-Bus session if not running
echo "Starting D-Bus session..."
if ! run_as_user dbus-daemon --session --address="unix:path=/run/user/$(id -u "$ACTUAL_USER")/bus" --nofork --nopidfile --syslog-only & then
    echo "Warning: Failed to start D-Bus session"
fi
sleep 2

# Configure systemd user service environment
echo "Configuring systemd user environment..."
run_as_user mkdir -p "$USER_HOME/.config/environment.d"
cat << EOF > /tmp/pipewire.conf.tmp
PIPEWIRE_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")/pipewire
PULSE_RUNTIME_PATH=/run/user/$(id -u "$ACTUAL_USER")/pulse
XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$ACTUAL_USER")/bus
EOF

run_as_root install -m 644 /tmp/pipewire.conf.tmp "$USER_HOME/.config/environment.d/pipewire.conf"
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/.config/environment.d/pipewire.conf"
rm -f /tmp/pipewire.conf.tmp

# Reset systemd state
echo "Resetting systemd state..."
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$ACTUAL_USER")/bus systemctl --user daemon-reload
run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$ACTUAL_USER")/bus systemctl --user reset-failed

# Clear any remaining sockets
echo "Cleaning up existing sockets..."
run_as_root rm -f /run/user/$(id -u "$ACTUAL_USER")/pipewire-* || true
run_as_root rm -f /run/user/$(id -u "$ACTUAL_USER")/pulse/* || true

# Start services in correct order
echo "Starting PipeWire services..."

# Function to run systemctl with proper environment
run_systemctl() {
    run_as_user bash -c "export XDG_RUNTIME_DIR=/run/user/\$(id -u) DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS' && systemctl --user $1"
}

# Reset failed units first
run_systemctl "reset-failed"

# Stop any running services
run_systemctl "stop pipewire pipewire-pulse wireplumber"

# Start services in order
echo "Starting PipeWire socket..."
run_systemctl "enable --now pipewire.socket"
sleep 2

echo "Starting PipeWire service..."
run_systemctl "enable --now pipewire.service"
sleep 2

# Check if PipeWire started successfully
if ! run_systemctl "is-active pipewire.service"; then
    echo "Error: PipeWire failed to start. Checking logs..."
    run_systemctl "status pipewire.service"
    exit 1
fi

echo "Starting WirePlumber..."
run_systemctl "enable --now wireplumber.service"
sleep 2

echo "Starting PipeWire-PulseAudio services..."
run_systemctl "enable --now pipewire-pulse.socket"
sleep 1
run_systemctl "enable --now pipewire-pulse.service"
sleep 2

# Verify all services
echo "Verifying services..."
for service in pipewire.service wireplumber.service pipewire-pulse.service; do
    if ! run_systemctl "is-active $service"; then
        echo "Warning: $service failed to start"
        run_systemctl "status $service"
    fi
done

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
        "log.level": 2,
        "mem.allow-mlock": true,
        "core.daemon": true,
        "core.name": "pipewire-0"
    },
    "context.spa-libs": {
        "audio.convert.*": "audioconvert/libspa-audioconvert",
        "support.*": "support/libspa-support"
    },
    "context.modules": [
        {
            "name": "libpipewire-module-rt",
            "args": {
                "nice.level": -11,
                "rt.prio": 88,
                "rt.time.soft": 200000,
                "rt.time.hard": 200000
            },
            "flags": [ "ifexists", "nofail" ]
        },
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
                    "api.alsa.headroom": 8192,
                    "api.alsa.disable-mmap": true,
                    "session.suspend-timeout-seconds": 0
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
local bluez_monitor = {}

bluez_monitor.properties = {
  ["bluez5.enable-sbc-xq"] = true,
  ["bluez5.enable-msbc"] = true,
  ["bluez5.enable-hw-volume"] = true,
  ["bluez5.headset-roles"] = "[ sink, source ]",
  ["bluez5.hfphsp-backend"] = "native",
  ["bluez5.a2dp.ldac.quality"] = "auto",
  ["bluez5.a2dp.aac.bitratemode"] = 0,
  ["bluez5.a2dp.aac.quality"] = 5
}

local stream = {}

stream.properties = {
  ["resample.quality"] = 7,
  ["resample.disable"] = false,
  ["channelmix.normalize"] = true,
  ["channelmix.mix-lfe"] = false,
  ["dither.noise"] = -90,
  ["clock.quantum-limit"] = 8192
}

local alsa_monitor = {}

alsa_monitor.properties = {
  ["alsa.jack-device"] = false,
  ["alsa.reserve"] = true,
  ["alsa.support-audio-fallback"] = true
}

return {
  ["bluez_monitor"] = bluez_monitor,
  ["stream"] = stream,
  ["alsa_monitor"] = alsa_monitor
}
EOF

# Ensure cache directories exist with correct permissions
echo "Setting up PipeWire cache directories..."
run_as_root mkdir -p /var/cache/pipewire
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /var/cache/pipewire
run_as_root chmod 700 /var/cache/pipewire

run_as_user mkdir -p "$USER_HOME/.cache/pipewire"
run_as_user mkdir -p "$USER_HOME/.local/state/pipewire"

# Verify service status
echo "Verifying service status..."
for service in pipewire.service wireplumber.service pipewire-pulse.service; do
    if ! run_as_user systemctl --user is-active $service >/dev/null 2>&1; then
        echo "Warning: $service is not running"
        run_as_user systemctl --user status $service
    else
        echo "$service is running"
    fi
done

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