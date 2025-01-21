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

# Required packages based on codebase analysis
REQUIRED_PACKAGES=(
    "bluez"              # Base Bluetooth stack
    "bluez-alsa-utils"   # BlueALSA utilities
    "python3-pip"        # Python package manager
    "libdbus-1-dev"      # D-Bus development files
    "alsa-utils"         # ALSA utilities
    "snapclient"         # Snapcast client for multi-room audio
)

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

# Set up ALSA config if it doesn't exist
if [ ! -f /etc/asound.conf ]; then
    echo "Creating ALSA configuration..."
    sudo tee /etc/asound.conf << EOF
defaults.bluealsa.interface "hci0"
defaults.bluealsa.profile "a2dp"
defaults.bluealsa.delay 10000
EOF
    check_status "ALSA configuration"
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
for service in bluetooth bluealsa snapclient; do
    sudo systemctl enable $service
    sudo systemctl restart $service
    check_status "Service $service"
done

# Set up user permissions
echo "Setting up permissions..."
sudo usermod -a -G bluetooth,audio $USER
check_status "User permissions"

# Install Python package
echo "Installing Python package..."
cd "$(dirname "$0")/.."
pip install -e .
check_status "Python package installation"

echo -e "\n${GREEN}Installation complete!${NC}"
echo -e "\nNext steps:"
echo "1. Log out and log back in for permissions to take effect"
echo "2. Run './scripts/check_setup.py' to verify installation"
echo "3. Test audio with './scripts/test_audio.py'" 