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
    "bluez"              # Base Bluetooth stack
    "bluez-alsa-utils"   # BlueALSA utilities
    "bluez-tools"        # Includes bt-agent
    "bluez-hid2hci"      # HID to HCI conversion tool
    "libasound2-dev"     # ALSA development files
    "libbluetooth-dev"   # Bluetooth development files
    "libasound2-plugins" # ALSA plugins including BlueALSA
    "python3-pip"        # Python package manager
    "libdbus-1-dev"      # D-Bus development files
    "python3-dbus"       # D-Bus Python bindings
    "python3-psutil"     # System utilities for Python
    "alsa-utils"         # ALSA utilities
)

# Add multi-room packages if needed
if [ "$INSTALL_MODE" = "multi-room" ]; then
    REQUIRED_PACKAGES+=(
        "snapclient"     # Snapcast client for multi-room audio
    )
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

# Check existing packages
echo -e "\nChecking existing packages..."
PACKAGES_TO_INSTALL=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! check_package "$pkg"; then
        PACKAGES_TO_INSTALL+=("$pkg")
    fi
done

# Update package lists if needed
if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
    echo -e "\nUpdating package lists..."
    sudo apt update || {
        echo -e "${RED}Failed to update package lists${NC}"
        echo "Trying alternative mirrors..."
        sudo rm -rf /var/lib/apt/lists/*
        sudo apt clean
        sudo sed -i 's/deb.debian.org/archive.raspberrypi.org/g' /etc/apt/sources.list
        sudo apt update || {
            echo -e "${RED}Package update failed. Please check your internet connection.${NC}"
            exit 1
        }
    }

    # Install missing packages
    echo -e "\nInstalling required packages..."
    sudo apt install -y "${PACKAGES_TO_INSTALL[@]}"
    check_status "Package installation"
fi

# Configure audio
echo -e "\nConfiguring audio system..."

# Detect primary audio output
if aplay -l | grep -q "USB Audio"; then
    DEFAULT_CARD="2"  # USB Audio
    DEFAULT_DEVICE="USB Audio"
elif aplay -l | grep -q "Headphones"; then
    DEFAULT_CARD="1"  # Headphones
    DEFAULT_DEVICE="Headphones"
else
    DEFAULT_CARD="0"  # HDMI
    DEFAULT_DEVICE="HDMI"
fi
echo "→ Using $DEFAULT_DEVICE as primary output"

# Set up ALSA config if it doesn't exist
if [ ! -f /etc/asound.conf ]; then
    echo "Creating ALSA configuration..."
    sudo tee /etc/asound.conf << EOF
# Software volume control
pcm.softvol {
    type softvol
    slave.pcm "merged"
    control {
        name "Master"
        card ${DEFAULT_CARD}
    }
}

# Merge all outputs
pcm.merged {
    type asym
    playback.pcm {
        type plug
        slave.pcm "dmix"
    }
    capture.pcm {
        type plug
        slave.pcm "dsnoop"
    }
}

# Hardware mixing
pcm.dmix {
    type dmix
    ipc_key 1024
    slave {
        pcm "hw:${DEFAULT_CARD},0"
        period_time 0
        period_size 1024
        buffer_size 4096
        rate 44100
        format S32_LE  # Better quality
    }
}

# Default PCM device (BlueALSA)
pcm.!default {
    type plug
    slave.pcm "softvol"
}

# BlueALSA configuration
pcm.bluealsa {
    type bluealsa
    interface "hci0"
    profile "a2dp"
    delay 10000  # Standard delay value
    volume_method "linear"
    soft_volume on
}

# Hardware devices with individual volume
pcm.headphones {
    type plug
    slave.pcm {
        type softvol
        slave.pcm "hw:1,0"
        control {
            name "Headphones"
            card 1
        }
        min_dB -51.0
        max_dB 0.0
        resolution 256
    }
    hint {
        show on
        description "Headphones Output"
    }
}

pcm.usb {
    type plug
    slave.pcm {
        type softvol
        slave.pcm "hw:2,0"
        control {
            name "USB"
            card 2
        }
        min_dB -51.0
        max_dB 0.0
    }
}

ctl.!default {
    type hw
    card ${DEFAULT_CARD}
}
EOF
    check_status "ALSA configuration"

    # Add Snapcast configuration if needed
    if [ "$INSTALL_MODE" = "multi-room" ]; then
        sudo tee -a /etc/asound.conf << EOF
# Snapcast support
pcm.snapcast {
    type plug
    slave.pcm "bluealsa"
}
EOF
    fi
fi

# Set up BlueALSA service
echo "Setting up BlueALSA service..."
sudo tee /etc/systemd/system/bluealsa.service << EOF
[Unit]
Description=BluezALSA proxy
Requires=bluetooth.service
After=bluetooth.service
Before=bluealsa-aplay.service
PartOf=bluetooth.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/bluealsa -p a2dp-sink -p a2dp-source
ExecStartPre=/bin/sleep 3
Restart=on-failure
RestartSec=5
TimeoutStartSec=10

[Install]
WantedBy=multi-user.target
Also=bluealsa-aplay.service
EOF

# Set up BlueALSA player service
sudo tee /etc/systemd/system/bluealsa-aplay.service << EOF
[Unit]
Description=BlueALSA aplay service
Requires=bluealsa.service
After=bluealsa.service
PartOf=bluetooth.service

[Service]
Type=simple
User=root
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/bluealsa-aplay --pcm-buffer-time=250000 00:00:00:00:00:00
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services in correct order
echo "Starting services..."
sudo systemctl daemon-reload

# Stop all services first
sudo systemctl stop bluealsa-aplay bluetooth bluealsa bt-agent

# Start services with proper delays
sudo systemctl enable bluetooth
sudo systemctl restart bluetooth
sleep 2
sudo systemctl enable bt-agent
sudo systemctl restart bt-agent
sleep 2
sudo systemctl enable bluealsa
sudo systemctl restart bluealsa
sleep 2
sudo systemctl enable bluealsa-aplay
sudo systemctl restart bluealsa-aplay

# Verify services
for service in bluetooth bt-agent bluealsa bluealsa-aplay; do
    if ! systemctl is-active --quiet $service; then
        echo -e "${RED}Service $service failed to start${NC}"
        echo "Checking logs..."
        journalctl -u $service -n 50
        exit 1
    fi
done

# Configure Bluetooth
echo "Configuring Bluetooth..."

# Set up Bluetooth agent
sudo tee /etc/bluetooth/main.conf << EOF
[General]
DiscoverableTimeout=0
Class=0x200414  # Audio device
Name=House Audio
Discoverable=true
ControllerMode=dual
FastConnectable=true

[LE]
MinConnectionInterval=7.5
MaxConnectionInterval=15
ConnectionLatency=0

[Policy]
AutoEnable=true
ReconnectAttempts=3
ReconnectIntervals=1,2,4
EOF

# Configure authentication agent
sudo tee /etc/systemd/system/bt-agent.service << EOF
[Unit]
Description=Bluetooth Auth Agent
After=bluetooth.service
Requires=bluetooth.service
Before=bluealsa.service
PartOf=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/bt-agent -c NoInputNoOutput --capability=NoInputNoOutput
ExecStartPre=/bin/sleep 2
Environment=DISPLAY=:0
Restart=on-failure
RestartSec=5
StartLimitInterval=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start agent
sudo systemctl enable bt-agent
sudo systemctl start bt-agent

# Configure BlueALSA
sudo systemctl restart bluetooth
check_status "Bluetooth configuration"

# Test Bluetooth audio
echo "Testing Bluetooth audio setup..."
if ! timeout 5 bluealsa-aplay -L; then
    echo -e "${YELLOW}Warning: BlueALSA playback test failed${NC}"
fi

# Set up user permissions
echo "Setting up permissions..."
sudo usermod -a -G bluetooth,audio $USER
check_status "User permissions"

# Install Python package system-wide
echo "Installing Python package system-wide..."
cd "$(dirname "$0")/.."
# Install dependencies first
sudo pip3 install --break-system-packages wheel setuptools

# Try installing with pip directly first
if ! sudo pip3 install --break-system-packages -e .; then
    echo "Pip install failed, trying alternative installation..."
    # Try installing with python directly
    sudo python3 setup.py install --force
fi
check_status "Python package installation"

# Enable experimental features
# Find bluetoothd path
BLUETOOTHD_PATH=$(which bluetoothd)
if [ -z "$BLUETOOTHD_PATH" ]; then
    echo "Checking alternative locations..."
    for path in "/usr/sbin/bluetoothd" "/usr/lib/bluetooth/bluetoothd" "/usr/libexec/bluetooth/bluetoothd"; do
        if [ -x "$path" ]; then
            BLUETOOTHD_PATH="$path"
            break
        fi
    done
fi

if [ -z "$BLUETOOTHD_PATH" ]; then
    echo -e "${RED}Error: bluetoothd not found${NC}"
    echo "Checking package installation..."
    dpkg -l | grep bluez
    echo "Trying to reinstall bluez..."
    sudo apt-get install --reinstall bluez
    BLUETOOTHD_PATH=$(which bluetoothd)
    if [ -z "$BLUETOOTHD_PATH" ]; then
        echo -e "${RED}Failed to locate bluetoothd after reinstall${NC}"
        exit 1
    fi
fi

echo "Found bluetoothd at: ${BLUETOOTHD_PATH}"

# Stop all services first
echo "Stopping services..."
sudo systemctl stop bluealsa-aplay bluetooth bluealsa bt-agent

# Clean up any existing configuration
sudo rm -f /etc/systemd/system/bluetooth.service.d/experimental.conf
sudo rm -f /etc/systemd/system/bluetooth.service.d/override.conf

# Clean up bluetooth directory
sudo rm -rf /etc/bluetooth
sudo mkdir -p /etc/bluetooth
sudo chmod 755 /etc/bluetooth
sudo chown -R root:root /etc/bluetooth

sudo mkdir -p /etc/systemd/system/bluetooth.service.d
sudo tee /etc/systemd/system/bluetooth.service.d/experimental.conf << EOF
[Service]
ExecStart=
ExecStart=${BLUETOOTHD_PATH} --experimental
Environment=LIBASOUND_THREAD_SAFE=0
EOF

# Reload systemd and restart bluetooth
sudo systemctl daemon-reload
sudo systemctl reset-failed bluetooth
sudo systemctl stop bluetooth
sleep 2
sudo systemctl enable bluetooth
sleep 1
sudo systemctl restart bluetooth
sleep 2  # Give it time to start

# Verify bluetooth service
if ! systemctl is-active --quiet bluetooth; then
    echo -e "${RED}Bluetooth service failed to start${NC}"
    echo "Checking logs..."
    journalctl -u bluetooth -n 50
    echo "Bluetoothd path: ${BLUETOOTHD_PATH}"
    echo "Current status:"
    systemctl status bluetooth
    echo "Checking service file:"
    systemctl cat bluetooth
    exit 1
fi

# Start other services in order
echo "Starting services..."
sudo systemctl restart bt-agent
sleep 2
sudo systemctl restart bluealsa
sleep 2
sudo systemctl restart bluealsa-aplay
sleep 2

# Final verification
for service in bluetooth bt-agent bluealsa bluealsa-aplay; do
    if ! systemctl is-active --quiet $service; then
        echo -e "${RED}Service $service failed to start${NC}"
        echo "Checking logs..."
        journalctl -u $service -n 50
        exit 1
    fi
    echo -e "${GREEN}✓ $service started${NC}"
done

echo -e "\n${GREEN}Installation complete!${NC}"
echo -e "\nNext steps:"
echo "1. Log out and log back in for permissions to take effect"
echo "2. Test audio with: python3 -m house_audio.tools.test_audio" 