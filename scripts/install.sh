#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

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

# Check for required tools
if ! command -v pkg-config &> /dev/null; then
    echo -e "${RED}pkg-config not found. Installation will fail.${NC}"
    exit 1
fi

# Install system dependencies
echo "Installing system dependencies..."
sudo apt update
sudo apt install -y build-essential autoconf automake libtool pkg-config \
    libbluetooth-dev libasound2-dev bluez bluez-tools python3-pip git \
    libsbc-dev libdbus-1-dev
check_status "System dependencies"

# Build and install BlueALSA
echo "Building BlueALSA..."

# Remove existing service if present
sudo systemctl stop bluealsa || true
sudo rm -f /etc/systemd/system/bluealsa.service

# Clean previous build
rm -rf bluez-alsa

# Clone and build
git clone https://github.com/Arkq/bluez-alsa.git
cd bluez-alsa

# Clean any previous build attempts
git clean -fdx

autoreconf --install
mkdir -p build && cd build
../configure --enable-aac --enable-ofono --prefix=/usr --sysconfdir=/etc
make
sudo make install
check_status "BlueALSA build"

# Create systemd service
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
check_status "Service file creation"

# Enable and start services
echo "Starting services..."
sudo systemctl daemon-reload
sudo systemctl enable bluetooth bluealsa
sudo systemctl start bluetooth bluealsa
check_status "Services"

# Add user to bluetooth group
sudo usermod -G bluetooth -a $USER
check_status "User permissions"

# Install Python package
cd "$(dirname "$0")/.."
pip install -e .
check_status "Python package"

echo -e "${GREEN}Installation complete!${NC}"
echo "Please log out and log back in for bluetooth permissions to take effect." 