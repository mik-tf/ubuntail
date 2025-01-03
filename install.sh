#!/bin/bash
# install.sh - Main installer script with improved error handling, logging, and Ubuntu 24.04 support

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Error handling
set -euo pipefail
trap 'echo -e "${RED}Error on line $LINENO${NC}"' ERR

# Configuration
REQUIRED_SPACE_GB=16
UBUNTU_VERSION="24.04"
TAILSCALE_RETRY_ATTEMPTS=3
TAILSCALE_RETRY_DELAY=30
LOG_FILE="/var/log/ubuntu-tailscale-installer.log"

# Redirect all output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Function to check dependencies
check_dependencies() {
    local DEPS=(
        "cryptsetup"
        "grub-efi-amd64"
        "parted"
        "tailscale"
        "mkpasswd"
        "whois"
        "curl"
    )

    echo "Checking dependencies..."
    local MISSING_DEPS=()
    for dep in "${DEPS[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            MISSING_DEPS+=("$dep")
        fi
    done

    if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
        echo -e "${RED}Missing dependencies: ${MISSING_DEPS[*]}${NC}"
        echo "Installing missing dependencies..."
        sudo apt-get update
        sudo apt-get install -y "${MISSING_DEPS[@]}"
    fi
}

# Function to verify ISO
verify_iso() {
    local ISO_PATH="$1"
    
    if [ ! -f "$ISO_PATH" ]; then
        echo -e "${RED}Error: ISO file not found${NC}"
        exit 1
    fi

    if ! file "$ISO_PATH" | grep -q "Ubuntu-Server.*${UBUNTU_VERSION}"; then
        echo -e "${YELLOW}Warning: This doesn't appear to be an Ubuntu ${UBUNTU_VERSION} Server ISO${NC}"
        read -p "Continue anyway? (y/N): " confirm
        if [ "$confirm" != "y" ]; then
            exit 1
        fi
    fi

    # Verify ISO checksum if available
    if [ -f "${ISO_PATH}.sha256" ]; then
        echo "Verifying ISO checksum..."
        if ! sha256sum -c "${ISO_PATH}.sha256"; then
            echo -e "${RED}Error: ISO checksum verification failed${NC}"
            exit 1
        fi
    fi
}

# Function to prepare USB device
prepare_usb() {
    local USB_DEVICE="$1"
    local DEVICE_SIZE
    
    echo "Preparing USB device ${USB_DEVICE}..."
    
    # Check device size
    DEVICE_SIZE=$(blockdev --getsize64 "$USB_DEVICE" | awk '{print $1/1024/1024/1024}')
    if [ "${DEVICE_SIZE%.*}" -lt "$REQUIRED_SPACE_GB" ]; then
        echo -e "${RED}Error: USB device too small. Need at least ${REQUIRED_SPACE_GB}GB${NC}"
        exit 1
    fi
    
    # Confirm device selection with details
    echo -e "${YELLOW}Selected USB device:${NC}"
    lsblk "$USB_DEVICE" -o NAME,SIZE,MODEL,SERIAL
    read -p "Is this the correct device? (y/N): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted"
        exit 1
    fi
    
    # Unmount any existing partitions
    umount "${USB_DEVICE}"* 2>/dev/null || true
    
    # Create partitions
    parted "$USB_DEVICE" mklabel gpt
    parted "$USB_DEVICE" mkpart "EFI" fat32 1MiB 512MiB
    parted "$USB_DEVICE" mkpart "UBUNTU-BOOT" fat32 512MiB 7GiB
    parted "$USB_DEVICE" mkpart "SECURE-CONFIG" 7GiB 100%
    parted "$USB_DEVICE" set 1 esp on
    parted "$USB_DEVICE" set 2 boot on
    
    # Format partitions
    mkfs.fat -F 32 -n "EFI" "${USB_DEVICE}1"
    mkfs.fat -F 32 -n "UBUNTU-BOOT" "${USB_DEVICE}2"
    
    # Setup encrypted partition with better security
    cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${USB_DEVICE}3"
    cryptsetup luksOpen "${USB_DEVICE}3" secure-config
    mkfs.ext4 -L "SECURE-CONFIG" /dev/mapper/secure-config
}

# Function to install Tailscale with retry logic
install_tailscale() {
    local attempt=1
    while [ $attempt -le $TAILSCALE_RETRY_ATTEMPTS ]; do
        echo "Installing Tailscale (attempt $attempt)..."
        if curl -fsSL https://tailscale.com/install.sh | bash; then
            return 0
        fi
        echo "Tailscale installation failed. Retrying in $TAILSCALE_RETRY_DELAY seconds..."
        sleep $TAILSCALE_RETRY_DELAY
        attempt=$((attempt + 1))
    done
    echo -e "${RED}Failed to install Tailscale after $TAILSCALE_RETRY_ATTEMPTS attempts${NC}"
    return 1
}

# Function to validate Tailscale auth key
validate_tailscale_key() {
    local KEY="$1"
    if [[ ! $KEY =~ ^ts[a-zA-Z0-9]{21}$ ]]; then
        echo -e "${RED}Error: Invalid Tailscale auth key format${NC}"
        return 1
    fi
    return 0
}

# Function to check internet connectivity
check_internet() {
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        echo -e "${RED}Error: No internet connectivity${NC}"
        exit 1
    fi
}

# Main installation function
main() {
    echo -e "${BLUE}Ubuntu ${UBUNTU_VERSION} and Tailscale Boot Maker${NC}"
    echo "============================================="

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Please run as root${NC}"
        exit 1
    fi

    # Check internet connectivity
    check_internet

    # Check dependencies
    check_dependencies

    # Get ISO path
    if [ "$#" -ge 1 ]; then
        ISO_PATH="$1"
    else
        echo -e "\n${BLUE}Enter path to Ubuntu ${UBUNTU_VERSION} Server ISO:${NC}"
        read -r ISO_PATH
    fi
    verify_iso "$ISO_PATH"

    # List and select USB device
    if [ "$#" -ge 2 ]; then
        USB_DEVICE="$2"
    else
        echo -e "\n${BLUE}Available USB devices:${NC}"
        lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT | grep "disk"
        echo -e "\n${BLUE}Enter USB device (e.g., /dev/sdb):${NC}"
        read -r USB_DEVICE
    fi

    # Confirm device selection with details
    echo -e "${YELLOW}Selected USB device:${NC}"
    lsblk "$USB_DEVICE" -o NAME,SIZE,MODEL,SERIAL
    read -p "Is this the correct device? (y/N): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted"
        exit 1
    fi

    # Get Tailscale auth key with validation
    if [ "$#" -ge 3 ]; then
        TAILSCALE_KEY="$3"
    else
        while true; do
            echo -e "\n${BLUE}Enter Tailscale auth key:${NC}"
            read -r TAILSCALE_KEY
            if validate_tailscale_key "$TAILSCALE_KEY"; then
                break
            fi
        done
    fi

    # Get node password with confirmation
    if [ "$#" -ge 4 ]; then
        NODE_PASSWORD="$4"
    else
        while true; do
            echo -e "\n${BLUE}Enter password for nodes:${NC}"
            read -rs NODE_PASSWORD
            echo
            echo -e "${BLUE}Confirm password:${NC}"
            read -rs NODE_PASSWORD_CONFIRM
            echo
            if [ "$NODE_PASSWORD" = "$NODE_PASSWORD_CONFIRM" ]; then
                break
            fi
            echo -e "${RED}Passwords do not match. Please try again.${NC}"
        done
    fi

    ENCRYPTED_PASS=$(mkpasswd -m sha-512 "$NODE_PASSWORD")

    # Prepare USB
    prepare_usb "$USB_DEVICE"

    # Mount partitions
    mkdir -p /mnt/{efi,usb-boot,usb-secure,iso}
    mount "${USB_DEVICE}1" /mnt/efi
    mount "${USB_DEVICE}2" /mnt/usb-boot
    mount /dev/mapper/secure-config /mnt/usb-secure
    mount -o loop "$ISO_PATH" /mnt/iso

    # Copy ISO contents
    echo "Copying Ubuntu installation files..."
    rsync -ah --progress /mnt/iso/ /mnt/usb-boot/

    # Store credentials securely
    mkdir -p /mnt/usb-secure/credentials
    cat > /mnt/usb-secure/credentials/credentials.env << EOF
TAILSCALE_AUTHKEY='${TAILSCALE_KEY}'
ENCRYPTED_PASSWORD='${ENCRYPTED_PASS}'
HOSTNAME_PREFIX='node'
EOF
    chmod 600 /mnt/usb-secure/credentials/credentials.env

    # Setup GRUB with improved configuration
    mkdir -p /mnt/usb-boot/boot/grub
    cp src/configs/grub/grub.cfg /mnt/usb-boot/boot/grub/
    
    # Install GRUB with proper EFI support
    grub-install --target=x86_64-efi --efi-directory=/mnt/efi \
                --boot-directory=/mnt/usb-boot/boot --removable \
                --recheck

    # Copy additional scripts and configurations
    mkdir -p /mnt/usb-boot/scripts
    cp -r src/scripts/* /mnt/usb-boot/scripts/
    chmod +x /mnt/usb-boot/scripts/**/*.sh

    # Update cloud-init configurations
    mkdir -p /mnt/usb-boot/nocloud/
    cp src/configs/cloud-init/{meta-data,user-data} /mnt/usb-boot/nocloud/
    cp src/configs/system/network-config /mnt/usb-boot/nocloud/

    # Cleanup
    sync
    umount /mnt/iso
    umount /mnt/efi
    umount /mnt/usb-boot
    umount /mnt/usb-secure
    cryptsetup luksClose secure-config
    rm -rf /mnt/{iso,efi,usb-boot,usb-secure}

    echo -e "${GREEN}USB boot maker created successfully!${NC}"
    echo -e "\nNext steps:"
    echo "1. Insert the USB drive into the target system"
    echo "2. Configure BIOS/UEFI settings (disable Secure Boot, enable UEFI)"
    echo "3. Boot from the USB drive"
    echo "4. Select 'Fresh Installation' from the GRUB menu"
    echo "5. Wait for the automated installation to complete"
    echo -e "\nThe system should appear in your Tailscale admin console within 10-15 minutes."
}

# Unattended mode support
if [ "$#" -eq 4 ]; then
    main "$1" "$2" "$3" "$4"
else
    main
fi