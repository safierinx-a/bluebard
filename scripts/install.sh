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

# Create systemd user service overrides
echo "Creating systemd user service overrides..."
run_as_user mkdir -p "$USER_HOME/.config/systemd/user/pipewire.service.d"
run_as_user install -m 644 /dev/stdin "$USER_HOME/.config/systemd/user/pipewire.service.d/override.conf" << EOF
[Unit]
Description=PipeWire Multimedia Service
After=dbus.socket
Requires=dbus.socket pipewire.socket
ConditionUser=!root

[Service]
Type=simple
ExecStart=/usr/bin/pipewire
Restart=on-failure
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")
Environment=PIPEWIRE_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")/pipewire
LockPersonality=yes
MemoryDenyWriteExecute=yes
NoNewPrivileges=yes
RestrictNamespaces=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service

[Install]
Also=pipewire.socket
WantedBy=default.target
EOF

run_as_user mkdir -p "$USER_HOME/.config/systemd/user/wireplumber.service.d"
run_as_user install -m 644 /dev/stdin "$USER_HOME/.config/systemd/user/wireplumber.service.d/override.conf" << EOF
[Unit]
Description=WirePlumber Session Manager
After=dbus.socket pipewire.service
Requires=dbus.socket pipewire.service
ConditionUser=!root

[Service]
Type=simple
ExecStart=/usr/bin/wireplumber
Restart=on-failure
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")
Environment=PIPEWIRE_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")/pipewire

[Install]
WantedBy=pipewire.service
EOF

run_as_user mkdir -p "$USER_HOME/.config/systemd/user/pipewire-pulse.service.d"
run_as_user install -m 644 /dev/stdin "$USER_HOME/.config/systemd/user/pipewire-pulse.service.d/override.conf" << EOF
[Unit]
Description=PipeWire PulseAudio
After=pipewire.service wireplumber.service
Requires=pipewire.service pipewire-pulse.socket
ConditionUser=!root

[Service]
Type=simple
ExecStart=/usr/bin/pipewire-pulse
Restart=on-failure
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")
Environment=PIPEWIRE_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")/pipewire
Environment=PULSE_RUNTIME_PATH=/run/user/$(id -u "$ACTUAL_USER")/pulse

[Install]
Also=pipewire-pulse.socket
WantedBy=default.target
EOF

# Reload systemd to recognize changes
run_systemctl "daemon-reload"

# Start services in correct order with proper dependencies
echo "Starting PipeWire services..."

# First ensure D-Bus is running
if ! run_systemctl "is-active dbus.socket"; then
    echo "Starting D-Bus socket..."
    run_systemctl "start dbus.socket"
    sleep 2
fi

# Start PipeWire socket first
echo "Starting PipeWire socket..."
run_systemctl "enable pipewire.socket"
run_systemctl "start pipewire.socket"
sleep 2

# Start PipeWire service
echo "Starting PipeWire service..."
run_systemctl "enable pipewire.service"
run_systemctl "start pipewire.service"
sleep 3

# Verify PipeWire is running
if ! run_systemctl "is-active pipewire.service"; then
    echo "Error: PipeWire failed to start. Checking logs..."
    run_systemctl "status pipewire.service"
    exit 1
fi

# Start WirePlumber
echo "Starting WirePlumber..."
run_systemctl "enable wireplumber.service"
run_systemctl "start wireplumber.service"
sleep 3

# Verify WirePlumber is running
if ! run_systemctl "is-active wireplumber.service"; then
    echo "Error: WirePlumber failed to start. Checking logs..."
    run_systemctl "status wireplumber.service"
    exit 1
fi

# Start PipeWire-Pulse
echo "Starting PipeWire-PulseAudio..."
run_systemctl "enable pipewire-pulse.socket"
run_systemctl "start pipewire-pulse.socket"
sleep 2
run_systemctl "enable pipewire-pulse.service"
run_systemctl "start pipewire-pulse.service"
sleep 3

# Final verification
echo "Verifying all services..."
for service in dbus.socket pipewire.socket pipewire.service wireplumber.service pipewire-pulse.socket pipewire-pulse.service; do
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

# Check and install required packages
echo "Checking and installing required packages..."
REQUIRED_PACKAGES=(
    "pipewire"
    "pipewire-audio"
    "wireplumber"
    "pipewire-pulse"
    "pipewire-alsa"
    "pipewire-jack"
    "pipewire-v4l2"
    "pipewire-bin"
    "libspa-0.2-bluetooth"
    "libspa-0.2-jack"
    "libspa-alsa"
    "python3-dbus"
    "python3-gi"
    "dbus"
)

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
    INSTALL_CMD="apt-get install -y"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    INSTALL_CMD="pacman -S --noconfirm"
else
    echo "Error: No supported package manager found"
    exit 1
fi

# Update package lists
echo "Updating package lists..."
if [ "$PKG_MANAGER" = "apt-get" ]; then
    run_as_root apt-get update
elif [ "$PKG_MANAGER" = "dnf" ]; then
    run_as_root dnf check-update || true
elif [ "$PKG_MANAGER" = "pacman" ]; then
    run_as_root pacman -Sy
fi

# Install packages
echo "Installing required packages..."
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! run_as_root $PKG_MANAGER list installed "$pkg" >/dev/null 2>&1; then
        echo "Installing $pkg..."
        run_as_root $INSTALL_CMD "$pkg"
    fi
done

# Ensure PipeWire is not running as a system service
echo "Ensuring PipeWire is running as user service only..."
run_as_root systemctl mask pipewire.service pipewire.socket
run_as_root systemctl mask pipewire-pulse.service pipewire-pulse.socket

# Remove any system-wide PulseAudio installation
echo "Removing system-wide PulseAudio..."
if [ "$PKG_MANAGER" = "apt-get" ]; then
    run_as_root apt-get remove --purge -y pulseaudio-system-daemon || true
elif [ "$PKG_MANAGER" = "dnf" ]; then
    run_as_root dnf remove -y pulseaudio-system || true
elif [ "$PKG_MANAGER" = "pacman" ]; then
    run_as_root pacman -R --noconfirm pulseaudio-system || true
fi

# After directory setup, ensure XDG_RUNTIME_DIR exists and has correct permissions
echo "Setting up XDG runtime directory..."
run_as_root mkdir -p /run/user/$(id -u "$ACTUAL_USER")
run_as_root chown "$ACTUAL_USER:$ACTUAL_USER" /run/user/$(id -u "$ACTUAL_USER")
run_as_root chmod 700 /run/user/$(id -u "$ACTUAL_USER")

# Set environment variables
export XDG_RUNTIME_DIR="/run/user/$(id -u "$ACTUAL_USER")"
export PIPEWIRE_RUNTIME_DIR="$XDG_RUNTIME_DIR/pipewire"

# Create systemd override for PipeWire service
echo "Creating systemd override for PipeWire..."
run_as_root mkdir -p /etc/systemd/system/pipewire.service.d
run_as_root install -m 644 /dev/stdin /etc/systemd/system/pipewire.service.d/override.conf << EOF
[Service]
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")
Environment=PIPEWIRE_RUNTIME_DIR=/run/user/$(id -u "$ACTUAL_USER")/pipewire
LockPersonality=yes
MemoryDenyWriteExecute=yes
NoNewPrivileges=yes
RestrictNamespaces=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
EOF 