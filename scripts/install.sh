#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Installing Bluebard Audio System...${NC}"

# Function to check if a command succeeded
check_status() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ $1${NC}"
    else
        echo -e "${RED}✗ $1 failed${NC}"
        exit 1
    fi
}

# Function to check if a package is installed
check_package() {
    if dpkg -l "$1" &> /dev/null; then
        echo -e "${GREEN}✓ $1 is installed${NC}"
        return 0
    else
        echo -e "${YELLOW}! $1 needs to be installed${NC}"
        return 1
    fi
}

# Function to backup a file
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        echo "Backing up $file..."
        sudo cp "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
    fi
}

# Check if running in user session
if [ -z "${XDG_RUNTIME_DIR}" ]; then
    echo -e "${RED}Error: This script must be run in a user session.${NC}"
    echo "Please log in to a terminal session (not via SSH) and try again."
    exit 1
fi

# Check Python version
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python 3 is required but not installed.${NC}"
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(sys.version_info[1])')
if [ "$PYTHON_VERSION" -lt 7 ]; then
    echo -e "${RED}Error: Python 3.7 or higher is required.${NC}"
    exit 1
fi

# Parse command line arguments
INSTALL_MODE="standalone"
while [[ $# -gt 0 ]]; do
    case $1 in
        --multi-room)
            INSTALL_MODE="multi-room"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Required packages based on codebase analysis
REQUIRED_PACKAGES=(
    # Bluetooth core
    "bluez"                    # Base Bluetooth stack
    "bluetooth"                # Bluetooth utilities
    "bluez-tools"             # Includes bt-agent
    
    # Audio core
    "pipewire"                # Modern audio server
    "pipewire-pulse"          # PulseAudio replacement
    "wireplumber"             # Session manager for PipeWire
    "pipewire-audio-client-libraries" # Audio client libraries
    "pipewire-alsa"           # ALSA compatibility
    "wireplumber-cli"         # For wpctl command
    
    # Python dependencies
    "python3-pip"             # Python package manager
    "python3-dbus"            # D-Bus Python bindings
    "python3-psutil"          # System utilities for Python
    "libdbus-1-dev"           # D-Bus development files
)

# Remove multi-room mode as we're focusing on standalone
if [ "$INSTALL_MODE" = "multi-room" ]; then
    echo -e "${YELLOW}Note: Multi-room mode is not yet supported${NC}"
    exit 1
fi

# Check system requirements
echo "Checking system requirements..."

# Verify we're on a Raspberry Pi
if ! grep -q "Raspberry Pi" /proc/cpuinfo; then
    echo -e "${YELLOW}Warning: This system may not be a Raspberry Pi${NC}"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check disk space
echo "Checking disk space..."
ROOT_SPACE=$(df -h / | awk 'NR==2 {print $4}' | sed 's/G//')
if (( $(echo "$ROOT_SPACE < 2" | bc -l) )); then
    echo -e "${RED}Error: Insufficient disk space. Need at least 2GB free.${NC}"
    exit 1
fi

# Backup existing configurations
echo "Backing up existing configurations..."
backup_file "/etc/pulse/default.pa"
backup_file "/etc/asound.conf"
backup_file "/etc/bluetooth/main.conf"

# Remove existing audio packages and configurations for clean install
echo -e "\nRemoving existing audio packages..."

# Stop all audio services
systemctl --user stop pipewire pipewire-pulse wireplumber 2>/dev/null || true
systemctl stop pulseaudio pulseaudio.socket 2>/dev/null || true

# Remove PulseAudio completely
apt-get remove --purge -y pulseaudio pulseaudio-* libpulse0 2>/dev/null || true
apt-get remove --purge -y bluealsa bluez-alsa-utils 2>/dev/null || true
apt-get autoremove -y

# Clean up old configuration files
echo "Cleaning up old configurations..."
rm -rf /etc/pulse
rm -f /etc/asound.conf
rm -f ~/.config/pulse
rm -f ~/.pulse*
rm -f /etc/systemd/system/bluealsa.service
rm -f /etc/systemd/system/bluealsa-aplay.service

# Update package lists
echo -e "\nUpdating package lists..."
apt-get update || {
    echo -e "${RED}Failed to update package lists${NC}"
    echo "Trying alternative mirrors..."
    rm -rf /var/lib/apt/lists/*
    apt-get clean
    sed -i 's/deb.debian.org/archive.raspberrypi.org/g' /etc/apt/sources.list
    apt-get update || {
        echo -e "${RED}Package update failed. Please check your internet connection.${NC}"
        exit 1
    }
}

# Install required packages one by one
echo -e "\nInstalling required packages..."
for package in "${REQUIRED_PACKAGES[@]}"; do
    echo "Installing $package..."
    if ! apt-get install -y "$package"; then
        echo -e "${RED}Failed to install $package${NC}"
        echo "Please check the error message above and try again."
        exit 1
    fi
done
check_status "Package installation"

# Configure Bluetooth daemon
echo -e "\nConfiguring Bluetooth daemon..."
mkdir -p /etc/systemd/system/bluetooth.service.d
tee /etc/systemd/system/bluetooth.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/bluetoothd --experimental
EOF
check_status "Bluetooth daemon configuration"

# Enable PipeWire for the current user
echo "Setting up PipeWire..."
if ! systemctl --user enable pipewire pipewire-pulse wireplumber; then
    echo -e "${RED}Failed to enable PipeWire services${NC}"
    echo "Please ensure you're running in a proper user session."
    exit 1
fi

if ! systemctl --user start pipewire pipewire-pulse wireplumber; then
    echo -e "${RED}Failed to start PipeWire services${NC}"
    echo "Please check the logs with: journalctl --user -u pipewire"
    exit 1
fi
check_status "PipeWire service configuration"

# Add user to required groups
echo "Setting up user permissions..."
usermod -a -G bluetooth,audio $USER
check_status "User permissions"

# Configure Bluetooth for better audio
echo "Configuring Bluetooth..."
tee /etc/bluetooth/main.conf << EOF
[General]
Class = 0x200414  # Audio device
Name = Bluebard Audio
Discoverable = true
DiscoverableTimeout = 0

[Policy]
AutoEnable=true

[Policy]
ReconnectAttempts=3
ReconnectIntervals=1,2,4
EOF

# Verify services with timeout
echo -e "\nVerifying services..."
for service in bluetooth pipewire pipewire-pulse wireplumber; do
    echo -n "Waiting for $service to start..."
    for i in {1..30}; do
        if systemctl --user is-active --quiet "$service" 2>/dev/null; then
            echo -e "\n${GREEN}✓ $service is running${NC}"
            break
        fi
        if [ $i -eq 30 ]; then
            echo -e "\n${RED}Service $service failed to start${NC}"
            echo "Last 50 lines of logs:"
            journalctl --user -u "$service" -n 50
            exit 1
        fi
        echo -n "."
        sleep 1
    done
done

# Test audio setup
echo -e "\nTesting audio setup..."
if command -v wpctl &> /dev/null; then
    echo "Audio devices found:"
    wpctl status | grep -A 5 "Audio" || echo "No audio devices found"
else
    echo -e "${YELLOW}Warning: wpctl not found. Audio device listing not available${NC}"
fi

echo -e "\n${GREEN}Installation complete!${NC}"
echo "You may need to log out and back in for group changes to take effect."
echo "Try running 'python3 -m house_audio.tools.test_audio' to test the setup."

# Add performance notes
echo -e "\n${YELLOW}Performance Notes:${NC}"
echo "1. The built-in WiFi/BT combo chip may have issues when both are used heavily"
echo "2. For best results, consider using a separate USB Bluetooth dongle"
echo "3. If audio drops out, check 'journalctl --user -u pipewire' for issues"

# Final checks
echo -e "\n${YELLOW}Post-installation Checks:${NC}"
echo "1. Checking PipeWire status..."
systemctl --user status pipewire | grep "Active:"
echo "2. Checking Bluetooth status..."
systemctl status bluetooth | grep "Active:"
echo "3. Checking audio devices..."
wpctl status | grep -A 5 "Audio" || echo "No audio devices found" 