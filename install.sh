#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to check dependencies
check_dependencies() {
    local DEPS=(
        "cryptsetup"
        "grub-efi-amd64"
        "parted"
        "tailscale"
        "mkpasswd"
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
        echo "Install with: sudo apt install ${MISSING_DEPS[*]}"
        exit 1
    fi
}

# Function to verify ISO
verify_iso() {
    local ISO_PATH="$1"
    
    if [ ! -f "$ISO_PATH" ]; then
        echo -e "${RED}Error: ISO file not found${NC}"
        exit 1
    fi

    if ! file "$ISO_PATH" | grep -q "Ubuntu-Server 24.04"; then
        echo -e "${RED}Warning: This doesn't appear to be an Ubuntu 24.04 Server ISO${NC}"
        read -p "Continue anyway? (y/N): " confirm
        if [ "$confirm" != "y" ]; then
            exit 1
        fi
    fi
}

# Function to prepare USB device
prepare_usb() {
    local USB_DEVICE="$1"
    
    echo "Preparing USB device ${USB_DEVICE}..."
    
    # Create partitions
    parted "$USB_DEVICE" mklabel gpt
    parted "$USB_DEVICE" mkpart primary fat32 1MiB 7GiB
    parted "$USB_DEVICE" mkpart primary 7GiB 100%
    parted "$USB_DEVICE" set 1 boot on
    
    # Format partitions
    mkfs.fat -F 32 -n "UBUNTU-BOOT" "${USB_DEVICE}1"
    
    # Setup encrypted partition
    cryptsetup luksFormat --type luks2 "${USB_DEVICE}2"
    cryptsetup luksOpen "${USB_DEVICE}2" secure-config
    mkfs.ext4 -L "SECURE-CONFIG" /dev/mapper/secure-config
}

# Main installation function
main() {
    echo -e "${BLUE}Proof-of-Zero Boot Installer${NC}"
    echo "================================"

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Please run as root${NC}"
        exit 1
    fi

    # Check dependencies
    check_dependencies

    # Get ISO path
    echo -e "\n${BLUE}Enter path to Ubuntu 24.04 Server ISO:${NC}"
    read -r ISO_PATH
    verify_iso "$ISO_PATH"

    # List and select USB device
    echo -e "\n${BLUE}Available USB devices:${NC}"
    lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT | grep "disk"
    echo -e "\n${BLUE}Enter USB device (e.g., /dev/sdb):${NC}"
    read -r USB_DEVICE

    # Confirm device selection
    echo -e "${RED}WARNING: This will ERASE ALL DATA on $USB_DEVICE${NC}"
    read -p "Type 'YES' to continue: " confirm
    if [ "$confirm" != "YES" ]; then
        echo "Aborted"
        exit 1
    fi

    # Get Tailscale auth key
    echo -e "\n${BLUE}Enter Tailscale auth key:${NC}"
    read -r TAILSCALE_KEY

    # Get node password
    echo -e "\n${BLUE}Enter password for nodes:${NC}"
    read -rs NODE_PASSWORD
    echo
    ENCRYPTED_PASS=$(mkpasswd -m sha-512 "$NODE_PASSWORD")

    # Prepare USB
    prepare_usb "$USB_DEVICE"

    # Mount partitions
    mkdir -p /mnt/{usb-boot,usb-secure,iso}
    mount "${USB_DEVICE}1" /mnt/usb-boot
    mount /dev/mapper/secure-config /mnt/usb-secure
    mount -o loop "$ISO_PATH" /mnt/iso

    # Copy ISO contents
    echo "Copying Ubuntu installation files..."
    cp -r /mnt/iso/* /mnt/usb-boot/

    # Store credentials
    mkdir -p /mnt/usb-secure/credentials
    cat > /mnt/usb-secure/credentials/credentials.env << EOF
TAILSCALE_AUTHKEY='${TAILSCALE_KEY}'
ENCRYPTED_PASSWORD='${ENCRYPTED_PASS}'
HOSTNAME_PREFIX='node'
EOF
    chmod 600 /mnt/usb-secure/credentials/credentials.env

    # Setup GRUB
    mkdir -p /mnt/usb-boot/boot/grub
    cp src/configs/grub/grub.cfg /mnt/usb-boot/boot/grub/
    grub-install --target=x86_64-efi --efi-directory=/mnt/usb-boot --boot-directory=/mnt/usb-boot/boot --removable

    # Cleanup
    umount /mnt/iso
    umount /mnt/usb-boot
    umount /mnt/usb-secure
    cryptsetup luksClose secure-config
    rm -rf /mnt/{iso,usb-boot,usb-secure}

    echo -e "${GREEN}USB boot maker created successfully!${NC}"
}

main "$@"
