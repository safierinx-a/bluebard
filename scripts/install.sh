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
    delay 20000  # Increased for better sync
    volume_method "linear"
    soft_volume on
    volume_max 100
    hint {
        show on
        description "Bluetooth Audio"
    }
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

[Service]
Type=simple
User=root
ExecStart=/usr/bin/bluealsa -p a2dp-sink
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
check_status "Service configuration"

# Enable and start services
echo "Starting services..."
sudo systemctl daemon-reload
SERVICES=("bluetooth" "bluealsa")
if [ "$INSTALL_MODE" = "multi-room" ]; then
    SERVICES+=("snapclient")
fi
for service in "${SERVICES[@]}"; do
    sudo systemctl enable $service
    sudo systemctl restart $service
    check_status "Service $service"
done

# Configure Bluetooth
echo "Configuring Bluetooth..."

# Set up Bluetooth agent
sudo tee /etc/bluetooth/main.conf << EOF
[General]
DiscoverableTimeout = 0
Discoverable = true
Name = House Audio
# Enable SSP (Secure Simple Pairing)
SSPCapability = true

[Policy]
AutoEnable = true
ReconnectAttempts = 3
ReconnectIntervals = 1,2,4
EOF

# Configure authentication agent
sudo tee /etc/systemd/system/bt-agent.service << EOF
[Unit]
Description=Bluetooth Auth Agent
After=bluetooth.service

[Service]
Type=simple
# Use DisplayOnly agent for PIN code display
ExecStart=/usr/bin/bt-agent -c DisplayOnly
Environment=DISPLAY=:0

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

echo -e "\n${GREEN}Installation complete!${NC}"
echo -e "\nNext steps:"
echo "1. Log out and log back in for permissions to take effect"
echo "2. Test audio with: python3 -m house_audio.tools.test_audio" 