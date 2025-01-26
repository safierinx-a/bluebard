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

# Function to run systemctl with proper environment
run_systemctl() {
    # If DBUS_SESSION_BUS_ADDRESS is not set, try to find it
    if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
        # Try the default path first
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$ACTUAL_USER")/bus"
        # If that doesn't work, try to start a new session
        if ! run_as_user dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
            DBUS_LAUNCH_OUTPUT=$(run_as_user dbus-launch --sh-syntax)
            if [ $? -eq 0 ]; then
                eval "$DBUS_LAUNCH_OUTPUT"
            fi
        fi
    fi
    
    # Run the systemctl command with the environment set
    run_as_user bash -c "export XDG_RUNTIME_DIR=/run/user/\$(id -u) DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS' && systemctl --user $1"
}

# Function to manage PipeWire services
manage_pipewire_services() {
    local action=$1
    local services=(
        "pipewire.socket"
        "pipewire-pulse.socket"
        "pipewire.service"
        "pipewire-pulse.service"
        "wireplumber.service"
    )
    
    for service in "${services[@]}"; do
        run_systemctl "$action $service"
    done
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

# Create PipeWire specific directories
run_as_root mkdir -p /run/user/$(id -u "$ACTUAL_USER")/pipewire
run_as_root mkdir -p /run/user/$(id -u "$ACTUAL_USER")/pulse
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /run/user/$(id -u "$ACTUAL_USER")/pipewire
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /run/user/$(id -u "$ACTUAL_USER")/pulse
run_as_root chmod 700 /run/user/$(id -u "$ACTUAL_USER")/pipewire
run_as_root chmod 700 /run/user/$(id -u "$ACTUAL_USER")/pulse

# Set up cache directories
run_as_root mkdir -p /var/cache/pipewire
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /var/cache/pipewire
run_as_root chmod 700 /var/cache/pipewire

# Set up user config and cache directories
run_as_user mkdir -p "$USER_HOME/.cache/pipewire"
run_as_user mkdir -p "$USER_HOME/.local/state/pipewire"
run_as_user mkdir -p "$USER_HOME/.local/share/pipewire"
run_as_user mkdir -p "$USER_HOME/.config/pipewire"
run_as_user mkdir -p "$USER_HOME/.config/systemd/user"

# Ensure all PipeWire directories have correct permissions
run_as_user chmod 700 "$USER_HOME/.cache/pipewire"
run_as_user chmod 700 "$USER_HOME/.local/state/pipewire"
run_as_user chmod 700 "$USER_HOME/.local/share/pipewire"

# Create necessary subdirectories
run_as_user mkdir -p "$USER_HOME/.local/state/pipewire/media-session.d"
run_as_user mkdir -p "$USER_HOME/.config/pipewire/media-session.d"
run_as_user mkdir -p "$USER_HOME/.config/pipewire/client.conf.d"
run_as_user mkdir -p "$USER_HOME/.config/pipewire/client-rt.conf.d"

# Set up systemd runtime directory
run_as_root mkdir -p /run/user/$(id -u "$ACTUAL_USER")/systemd
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /run/user/$(id -u "$ACTUAL_USER")/systemd
run_as_root chmod 700 /run/user/$(id -u "$ACTUAL_USER")/systemd

# Set up D-Bus session
echo "Setting up D-Bus session..."

# Try to get existing D-Bus session
if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
    echo "Using existing D-Bus session: $DBUS_SESSION_BUS_ADDRESS"
else
    # Check if we can connect to an existing session
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$ACTUAL_USER")/bus"
    if run_as_user dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
        echo "Connected to existing D-Bus session"
        export DBUS_SESSION_BUS_ADDRESS
    else
        echo "Starting new D-Bus session..."
        # Only create a new session if we can't connect to an existing one
        DBUS_LAUNCH_OUTPUT=$(run_as_user dbus-launch --sh-syntax)
        if [ $? -eq 0 ]; then
            eval "$DBUS_LAUNCH_OUTPUT"
            echo "D-Bus session started successfully"
        else
            echo "Error: Failed to start D-Bus session"
            exit 1
        fi
    fi
fi

# Verify D-Bus session
echo "Verifying D-Bus session..."
if ! run_as_user bash -c "export DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS' && dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames" >/dev/null 2>&1; then
    echo "Error: D-Bus session verification failed"
    exit 1
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
export XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")

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

# Stop all services and clean up
echo "Stopping all services and cleaning up..."
manage_pipewire_services "stop"
manage_pipewire_services "disable"
run_systemctl "reset-failed"

# Kill any remaining processes and clean up thoroughly
echo "Ensuring no PipeWire processes are running..."
run_as_user pkill -9 pipewire 2>/dev/null || true
run_as_user pkill -9 wireplumber 2>/dev/null || true
run_as_user pkill -9 pipewire-pulse 2>/dev/null || true
sleep 2

# Clean up ALL runtime files and sockets
echo "Cleaning up runtime files..."
run_as_root rm -rf /run/user/$(id -u "$ACTUAL_USER")/pipewire
run_as_root rm -rf /run/user/$(id -u "$ACTUAL_USER")/pulse
run_as_root rm -rf /run/user/$(id -u "$ACTUAL_USER")/pipewire-*
run_as_root rm -rf /run/user/$(id -u "$ACTUAL_USER")/systemd/pipewire*
run_as_user rm -rf "$USER_HOME/.local/state/pipewire/"*
run_as_user rm -rf "$USER_HOME/.cache/pipewire/"*
run_as_user rm -rf "$USER_HOME/.config/pipewire/"*
run_as_root rm -rf /var/cache/pipewire/*

# Clean up any stale socket files
run_as_root find /run/user/$(id -u "$ACTUAL_USER") -type s -name "pipewire-*" -delete
run_as_root find /run/user/$(id -u "$ACTUAL_USER") -type s -name "pulse-*" -delete

# Recreate directories with proper permissions
echo "Setting up clean PipeWire directories..."
run_as_root mkdir -p /run/user/$(id -u "$ACTUAL_USER")/pipewire
run_as_root mkdir -p /run/user/$(id -u "$ACTUAL_USER")/pulse
run_as_root mkdir -p /var/cache/pipewire
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /run/user/$(id -u "$ACTUAL_USER")/pipewire
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /run/user/$(id -u "$ACTUAL_USER")/pulse
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /var/cache/pipewire
run_as_root chmod 700 /run/user/$(id -u "$ACTUAL_USER")/pipewire
run_as_root chmod 700 /run/user/$(id -u "$ACTUAL_USER")/pulse
run_as_root chmod 700 /var/cache/pipewire

# Update PipeWire configuration to prevent module loading issues
echo "Updating PipeWire configuration..."
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
        "core.daemon": false,
        "module.allow-duplicate": false
    },
    "context.modules": [
        {
            "name": "libpipewire-module-protocol-native",
            "flags": [ "nofail" ],
            "args": {
                "socket.listen.path": "${PIPEWIRE_RUNTIME_DIR}/pipewire-0"
            }
        },
        { 
            "name": "libpipewire-module-client-node",
            "flags": [ "nofail" ]
        },
        { 
            "name": "libpipewire-module-adapter",
            "flags": [ "nofail" ]
        },
        { 
            "name": "libpipewire-module-metadata",
            "flags": [ "nofail" ]
        }
    ],
    "stream.properties": {
        "resample.quality": 7
    }
}
EOF

# Ensure systemd user instance is clean
run_systemctl "daemon-reload"
run_systemctl "reset-failed"

# Start services with proper delays
echo "Starting PipeWire services..."
run_systemctl "start pipewire.socket"
sleep 2
run_systemctl "start pipewire.service"
sleep 3

# Check PipeWire status before continuing
if ! run_systemctl "is-active pipewire.service"; then
    echo "Error: PipeWire failed to start. Checking logs..."
    run_systemctl "status pipewire.service"
    exit 1
fi

# Verify PipeWire is working
echo "Testing PipeWire functionality..."
if ! run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") pw-cli info > /dev/null 2>&1; then
    echo "Warning: PipeWire is not responding to commands"
    echo "Try running: systemctl --user restart pipewire pipewire-pulse"
else
    echo "PipeWire is responding to commands"
fi

# Verify PulseAudio compatibility
if ! run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") pactl info > /dev/null 2>&1; then
    echo "Warning: PipeWire-PulseAudio is not responding"
    echo "Try running: systemctl --user restart pipewire-pulse"
else
    echo "PipeWire-PulseAudio is working"
fi

# Verify Bluetooth
if ! run_as_user bluetoothctl show > /dev/null 2>&1; then
    echo "Warning: Bluetooth service is not running properly"
    echo "Try running: sudo systemctl restart bluetooth"
else
    echo "Bluetooth service is running"
fi

echo "Installation complete!"
echo "NOTE: You may need to log out and log back in for group changes to take effect."
echo "To test the setup, run: python3 -m bluebard.tools.test_audio"

# Configure WirePlumber
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

bluez_monitor.rules = {
    {
        matches = {
            {
                { "device.name", "matches", "bluez_card.*" },
            },
        },
        apply_properties = {
            ["bluez5.reconnect-profiles"] = { "a2dp_sink", "hfp_hf" },
            ["bluez5.headset-roles"] = { "hfp_hf", "hsp_hs" },
            ["bluez5.auto-connect"] = true,
            ["bluez5.hw-volume"] = true
        }
    }
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
  ["alsa.support-audio-fallback"] = true,
  ["alsa.midi-driver"] = "none"
}

alsa_monitor.rules = {
    {
        matches = {
            {
                { "node.name", "matches", "alsa_output.*" },
            },
        },
        apply_properties = {
            ["audio.format"] = "S32LE",
            ["audio.rate"] = 48000,
            ["audio.channels"] = 2,
            ["audio.position"] = "FL,FR",
            ["api.alsa.period-size"] = 1024,
            ["api.alsa.headroom"] = 8192
        }
    }
}

return {
  ["bluez_monitor"] = bluez_monitor,
  ["stream"] = stream,
  ["alsa_monitor"] = alsa_monitor
}
EOF

# Reload systemd to recognize all changes
run_systemctl "daemon-reload"

# Start services in strict order
echo "Starting PipeWire services..."

# Start socket first and wait
echo "Starting PipeWire socket..."
run_systemctl "enable pipewire.socket"
run_systemctl "start pipewire.socket"
sleep 5

# Start PipeWire service
echo "Starting PipeWire service..."
run_systemctl "enable pipewire.service"
run_systemctl "start pipewire.service"
sleep 5

# Check if PipeWire started successfully
if ! run_systemctl "is-active pipewire.service"; then
    echo "Error: PipeWire failed to start. Checking logs..."
    run_systemctl "status pipewire.service"
    exit 1
fi

# Start WirePlumber
echo "Starting WirePlumber..."
run_systemctl "enable wireplumber.service"
run_systemctl "start wireplumber.service"
sleep 5

# Finally start PipeWire-Pulse service
echo "Starting PipeWire-PulseAudio service..."
run_systemctl "enable pipewire-pulse.service"
run_systemctl "start pipewire-pulse.service"
sleep 3
run_systemctl "enable pipewire-pulse.service"
run_systemctl "start pipewire-pulse.service"
sleep 5

# Final verification with detailed status
echo "Verifying services..."
for service in pipewire.socket pipewire-pulse.socket pipewire.service wireplumber.service pipewire-pulse.service; do
    echo "Checking $service..."
    if ! run_systemctl "is-active $service"; then
        echo "Warning: $service failed to start"
        run_systemctl "status $service"
    else
        echo "$service is running"
    fi
done

# Verify PipeWire is working
echo "Testing PipeWire functionality..."
if ! run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") pw-cli info > /dev/null 2>&1; then
    echo "Warning: PipeWire is not responding to commands"
    echo "Try running: systemctl --user restart pipewire pipewire-pulse"
else
    echo "PipeWire is responding to commands"
fi

# Verify PulseAudio compatibility
if ! run_as_user XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER") pactl info > /dev/null 2>&1; then
    echo "Warning: PipeWire-PulseAudio is not responding"
    echo "Try running: systemctl --user restart pipewire-pulse"
else
    echo "PipeWire-PulseAudio is working"
fi

# Verify Bluetooth
if ! run_as_user bluetoothctl show > /dev/null 2>&1; then
    echo "Warning: Bluetooth service is not running properly"
    echo "Try running: sudo systemctl restart bluetooth"
else
    echo "Bluetooth service is running"
fi

echo "Installation complete!"
echo "NOTE: You may need to log out and log back in for group changes to take effect."
echo "To test the setup, run: python3 -m bluebard.tools.test_audio" 