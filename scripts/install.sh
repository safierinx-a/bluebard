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

# Check disk space
echo "Checking disk space..."
ROOT_SPACE=$(df -h / | awk 'NR==2 {print $4}' | sed 's/G//')
ROOT_USED=$(df -h / | awk 'NR==2 {print $3}' | sed 's/G//')

if (( $(echo "$ROOT_SPACE < 2" | bc -l) )); then
    echo -e "${RED}Warning: Low disk space on root partition (${ROOT_SPACE}GB free)${NC}"
    echo -e "Would you like to:"
    echo "1. View largest files/directories"
    echo "2. Run system cleanup"
    echo "3. Continue anyway"
    echo "4. Exit"
    read -p "Choose an option (1-4): " choice
    
    case $choice in
        1)
            echo -e "\nLargest directories in root:"
            sudo du -h --max-depth=2 / 2>/dev/null | sort -hr | head -n 10
            echo -e "\nLargest files:"
            sudo find / -type f -size +100M -exec ls -lh {} \; 2>/dev/null | sort -k5 -hr | head -n 10
            exit 1
            ;;
        2)
            echo -e "\nRunning system cleanup..."
            sudo apt clean
            sudo apt autoremove --purge -y
            sudo journalctl --vacuum-time=1d
            echo -e "Cleanup complete. New free space:"
            df -h /
            ;;
        3)
            echo -e "${RED}Continuing with low disk space...${NC}"
            ;;
        *)
            echo "Exiting."
            exit 1
            ;;
    esac
fi

# Check if system has old/unused packages
REMOVABLE_PKGS=$(sudo apt autoremove -s | grep -c "^Remv")
if [ "$REMOVABLE_PKGS" -gt 0 ]; then
    echo -e "${RED}Warning: Found $REMOVABLE_PKGS packages that could be removed${NC}"
    echo "Would you like to remove them before continuing? (y/n)"
    read -p "> " clean_choice
    if [[ $clean_choice =~ ^[Yy]$ ]]; then
        sudo apt autoremove --purge -y
    fi
fi

# Install system dependencies
echo "Installing system dependencies..."

# Update package lists
sudo apt update || {
    echo -e "${RED}Failed to update package lists${NC}"
    exit 1
}

# Install dependencies in groups
echo "→ Installing build tools..."
sudo apt install -y build-essential autoconf automake libtool pkg-config git
check_status "Build tools"

echo "→ Installing bluetooth dependencies..."
sudo apt install -y bluez bluez-tools libbluetooth-dev
check_status "Bluetooth dependencies"

echo "→ Installing audio dependencies..."
sudo apt install -y libasound2-dev libsbc-dev
check_status "Audio dependencies"

echo "→ Installing Python dependencies..."
sudo apt install -y python3-pip libdbus-1-dev
check_status "Python dependencies"

# Build and install BlueALSA
echo -e "\n${GREEN}Building BlueALSA...${NC}"
echo "This may take a few minutes on a Raspberry Pi"

# Check memory and add swap if needed
MEMORY_MB=$(free -m | awk '/^Mem:/{print $2}')
echo "→ Available memory: ${MEMORY_MB}MB"

if [ $MEMORY_MB -lt 2048 ]; then
    echo "→ Low memory detected, setting up swap..."
    sudo fallocate -l 1G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=1024
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    check_status "Swap setup"
fi

# Remove existing service if present
echo "→ Cleaning previous installation..."
sudo systemctl stop bluealsa || true
sudo rm -f /etc/systemd/system/bluealsa.service

# Clean previous build
rm -rf bluez-alsa

# Clone and build
echo "→ Cloning BlueALSA repository..."
git clone https://github.com/Arkq/bluez-alsa.git
cd bluez-alsa

# Clean any previous build attempts
git clean -fdx

echo "→ Running autotools..."
autoreconf --install || {
    echo -e "${RED}Autotools configuration failed${NC}"
    exit 1
}

mkdir -p build && cd build
echo "→ Configuring build..."
../configure --enable-aac --enable-ofono --prefix=/usr --sysconfdir=/etc || {
    echo -e "${RED}Configure failed${NC}"
    exit 1
}

# Use only 2 make jobs to avoid memory issues
echo "→ Building BlueALSA (this may take a while)..."
make -j2
echo "→ Installing BlueALSA..."
sudo make install
check_status "BlueALSA build"

# Remove swap if we added it
if [ $MEMORY_MB -lt 2048 ]; then
    echo "→ Removing temporary swap..."
    sudo swapoff /swapfile
    sudo rm -f /swapfile
    check_status "Swap cleanup"
fi

# Create systemd service
echo -e "\n${GREEN}Setting up BlueALSA service...${NC}"
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