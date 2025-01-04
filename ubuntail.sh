#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
PURPLE='\033[0;35m'
ORANGE='\033[38;5;208m'
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

# Function to setup logging
setup_logging() {
    # Create log file with proper permissions
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    # Setup logging
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# Only check for root and setup logging when not showing help
if [ "${1:-}" != "help" ]; then
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Please run with sudo privileges${NC}"
        echo -e "Usage: sudo $0 [command]"
        exit 1
    fi
    setup_logging
fi

# Setup logging
exec > >(tee -a "$LOG_FILE") 2>&1

# Function to install ubuntail
install() {
    echo
    echo -e "${GREEN}Installing Ubuntail...${NC}"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Please run with sudo privileges${NC}"
        exit 1
    fi

    INSTALL_DIR="/usr/local/bin"
    if [ ! -d "$INSTALL_DIR" ]; then
        mkdir -p "$INSTALL_DIR"
    fi

    # Copy script to installation directory
    if cp "$0" "$INSTALL_DIR/ubuntail"; then
        # Set ownership and permissions
        chown root:root "$INSTALL_DIR/ubuntail"
        chmod 755 "$INSTALL_DIR/ubuntail"

        echo
        echo -e "${PURPLE}Ubuntail has been installed successfully.${NC}"
        echo -e "Installation location: ${GREEN}$INSTALL_DIR/ubuntail${NC}"
        echo
        echo -e "Use ${BLUE}ubuntail help${NC} to see the available commands."
        echo
    else
        echo -e "${RED}Error: Failed to copy script to $INSTALL_DIR${NC}"
        exit 1
    fi

    # Verify installation
    if command -v ubuntail >/dev/null 2>&1; then
        echo -e "${GREEN}Installation verified successfully.${NC}"
    else
        echo -e "${RED}Warning: Installation completed but 'ubuntail' command not found in PATH.${NC}"
        echo -e "You may need to add $INSTALL_DIR to your PATH or restart your terminal."
    fi
}

# Function to uninstall ubuntail
uninstall() {
    echo
    echo -e "${GREEN}Uninstalling Ubuntail...${NC}"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Please run with sudo privileges${NC}"
        exit 1
    fi

    INSTALL_PATH="/usr/local/bin/ubuntail"

    if [ ! -f "$INSTALL_PATH" ]; then
        echo -e "${RED}Error: Ubuntail is not installed at $INSTALL_PATH${NC}"
        exit 1
    fi

    if rm -f "$INSTALL_PATH"; then
        echo -e "${PURPLE}Ubuntail has been uninstalled successfully.${NC}"
        echo -e "Removed: ${RED}$INSTALL_PATH${NC}"
        echo
    else
        echo -e "${RED}Error: Failed to remove $INSTALL_PATH${NC}"
        echo -e "Please check file permissions and try again."
        exit 1
    fi

    # Verify uninstallation
    if command -v ubuntail >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: 'ubuntail' command is still available in your system.${NC}"
        echo -e "You may need to restart your terminal or check for other installations."
    else
        echo -e "${GREEN}Uninstallation verified successfully.${NC}"
    fi
}

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
        "hdparm"
        "wipefs"
        "rsync"
        "dd"
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

# Function to validate USB device path
validate_usb_device() {
    local device="$1"
    

    # Check if device path matches expected pattern
    if ! [[ "$device" =~ ^/dev/sd[a-z]$ ]]; then
        echo -e "${RED}Error: Invalid device path${NC}"
        echo -e "${YELLOW}Device path should be in the format /dev/sdb, /dev/sdc, etc.${NC}"
        return 1
    fi

    # Check if device exists
    if [ ! -b "$device" ]; then
        echo -e "${RED}Error: Device $device does not exist${NC}"
        return 1
    fi

    return 0
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
    echo -e "${RED}WARNING: ALL DATA ON THIS DEVICE WILL BE ERASED!${NC}"
    read -p "Is this the correct device? (y/N): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted"
        exit 1
    fi

    echo "Preparing device for partitioning..."
    
    # First, ensure all partitions are unmounted
    echo "Unmounting any existing partitions..."
    for partition in ${USB_DEVICE}*; do
        if mount | grep -q "$partition"; then
            echo "Unmounting $partition..."
            umount -f "$partition" 2>/dev/null || umount -l "$partition" 2>/dev/null || true
        fi
    done

    # Check and close any existing LUKS/mapper devices
    echo "Checking for existing encrypted volumes..."
    if [ -e "/dev/mapper/secure-config" ]; then
        echo "Found existing mapper device, attempting to close..."
        umount -f /dev/mapper/secure-config 2>/dev/null || true
        cryptsetup luksClose secure-config 2>/dev/null || {
            echo "Forcing closure of mapper device..."
            dmsetup remove --force secure-config 2>/dev/null || true
        }
    fi

    # Handle any existing LUKS volumes on the third partition
    if [ -e "${USB_DEVICE}3" ] && cryptsetup isLuks "${USB_DEVICE}3" 2>/dev/null; then
        echo -e "${YELLOW}Encrypted partition detected. Attempting to close...${NC}"
        cryptsetup luksClose "${USB_DEVICE}3" 2>/dev/null || true
    fi

    # Force all partitions to be forgotten
    echo "Forcing kernel to forget partitions..."
    for part in ${USB_DEVICE##*/}[0-9]*; do
        if [ -e "/sys/block/${USB_DEVICE##*/}/$part" ]; then
            echo 1 > "/sys/block/${USB_DEVICE##*/}/$part/device/delete" 2>/dev/null || true
        fi
    done

    # Force kernel to forget the main device
    if [ -e "/sys/block/${USB_DEVICE##*/}/device/delete" ]; then
        echo 1 > "/sys/block/${USB_DEVICE##*/}/device/delete" 2>/dev/null || true
    fi
    sleep 2

    # Rescan SCSI bus
    echo "Rescanning SCSI bus..."
    for host in /sys/class/scsi_host/host*; do
        echo "- - -" > "$host/scan" 2>/dev/null || true
    done
    sleep 5

    # Use wipefs to clear all signatures
    echo "Clearing all partition signatures..."
    wipefs -a "$USB_DEVICE" || true
    sleep 2

    # Clear the beginning and end of the device
    echo "Clearing partition table..."
    dd if=/dev/zero of="$USB_DEVICE" bs=1M count=10 conv=fsync 2>/dev/null || true
    
    # Get device size and clear the end
    DEVICE_SIZE_BYTES=$(blockdev --getsize64 "$USB_DEVICE")
    DEVICE_SIZE_MB=$((DEVICE_SIZE_BYTES / 1024 / 1024))
    END_POSITION=$((DEVICE_SIZE_MB - 10))
    if [ $END_POSITION -gt 10 ]; then
        dd if=/dev/zero of="$USB_DEVICE" bs=1M seek=$END_POSITION count=10 conv=fsync 2>/dev/null || true
    fi

    sync
    sleep 2

    # Try multiple partition table creation methods
    echo "Creating new partition table..."
    dd if=/dev/zero of="$USB_DEVICE" bs=512 count=1 conv=fsync 2>/dev/null || true
    sync
    sleep 1
    
    sgdisk --zap-all "$USB_DEVICE" || true
    sleep 1
    
    parted -s "$USB_DEVICE" mklabel gpt
    sleep 1

    # Force kernel to re-read partition table multiple ways
    blockdev --rereadpt "$USB_DEVICE" 2>/dev/null || true
    partprobe -s "$USB_DEVICE" || true
    hdparm -z "$USB_DEVICE" 2>/dev/null || true
    sleep 2

    # Create partitions one at a time
    echo "Creating partitions..."
    parted -s "$USB_DEVICE" mkpart "EFI" fat32 1MiB 512MiB
    sleep 1
    partprobe "$USB_DEVICE" || true
    
    parted -s "$USB_DEVICE" mkpart "UBUNTU-BOOT" fat32 512MiB 7GiB
    sleep 1
    partprobe "$USB_DEVICE" || true
    
    parted -s "$USB_DEVICE" mkpart "SECURE-CONFIG" 7GiB 100%
    sleep 1
    partprobe "$USB_DEVICE" || true

    # Set flags
    parted -s "$USB_DEVICE" set 1 esp on
    parted -s "$USB_DEVICE" set 2 boot on
    
    # Final partition table refresh
    sync
    partprobe -s "$USB_DEVICE" || true
    hdparm -z "$USB_DEVICE" 2>/dev/null || true
    sleep 5

    # Verify partitions were created
    if [ ! -e "${USB_DEVICE}1" ] || [ ! -e "${USB_DEVICE}2" ] || [ ! -e "${USB_DEVICE}3" ]; then
        echo -e "${RED}Error: Partitions were not created properly${NC}"
        exit 1
    fi

    # Format partitions
    echo "Formatting EFI partition..."
    mkfs.fat -F 32 -n "EFI" "${USB_DEVICE}1"
    
    echo "Formatting boot partition..."
    mkfs.fat -F 32 -n "UBUNTU-BOOT" "${USB_DEVICE}2"
    
    # Setup encrypted partition
    echo "Setting up encrypted partition..."
    echo -e "${YELLOW}You will be asked to set an encryption passphrase for the secure configuration partition.${NC}"
    echo -e "${YELLOW}Please remember this passphrase as it will be needed to access the secure data.${NC}"
    echo

    # Create encrypted partition with enhanced security
    cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --iter-time 5000 \
        --verify-passphrase \
        "${USB_DEVICE}3"

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to create encrypted partition${NC}"
        exit 1
    fi

    echo -e "\n${YELLOW}Now enter the same passphrase again to open the encrypted partition:${NC}"
    cryptsetup luksOpen "${USB_DEVICE}3" secure-config

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to open encrypted partition${NC}"
        exit 1
    fi

    # Format the encrypted partition
    echo "Formatting encrypted partition..."
    mkfs.ext4 -L "SECURE-CONFIG" /dev/mapper/secure-config

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to format encrypted partition${NC}"
        cryptsetup luksClose secure-config
        exit 1
    fi

    echo -e "${GREEN}USB device preparation completed successfully${NC}"
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
    if [[ ! $KEY =~ ^ts[a-zA-Z0-9-]+$ ]]; then
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

# Function to display help information
help() {
    echo -e "\n${ORANGE}═══════════════════════════════════════════${NC}"
    echo -e "${ORANGE}              Ubuntail                      ${NC}"
    echo -e "${ORANGE}═══════════════════════════════════════════${NC}\n"
    
    echo -e "${PURPLE}Description:${NC} Ubuntail is a tool for creating bootable Ubuntu ${UBUNTU_VERSION} USB drives with Tailscale integration"
    echo -e "${PURPLE}Usage:${NC}       ubuntail [command] [arguments]"
    
    echo -e "${PURPLE}Commands:${NC}"
    echo -e "  ${GREEN}create <iso-path> <usb-device> <tailscale-key> <username> <password>${NC}"
    echo -e "                  Create bootable USB with Ubuntu and Tailscale"
    echo -e "                  ${BLUE}Example:${NC} ubuntail create ubuntu.iso /dev/sdb tskey-xxx-xxx myuser mypassword\n"
    
    echo -e "  ${GREEN}install${NC}"
    echo -e "                  Install Ubuntail to system"
    echo -e "                  ${BLUE}Example:${NC} sudo ubuntail install\n"
    
    echo -e "  ${GREEN}uninstall${NC}"
    echo -e "                  Remove Ubuntail from system"
    echo -e "                  ${BLUE}Example:${NC} sudo ubuntail uninstall\n"
    
    echo -e "  ${GREEN}help${NC}"
    echo -e "                  Display this help message"
    echo -e "                  ${BLUE}Example:${NC} ubuntail help\n"
    
    echo -e "${PURPLE}Requirements:${NC}"
    echo -e "  - Ubuntu ${UBUNTU_VERSION} Server ISO"
    echo -e "  - USB drive (minimum ${REQUIRED_SPACE_GB}GB)"
    echo -e "  - Tailscale authentication key"
    echo -e "  - Root privileges\n"
    
    echo -e "${PURPLE}Notes:${NC}"
    echo -e "  - All operations require sudo privileges"
    echo -e "  - The USB device will be completely erased during creation"
    echo -e "  - Internet connection required for Tailscale setup\n"

    echo -e "${PURPLE}License:${NC} Apache 2.0"
    echo -e "${PURPLE}Repo:${NC}    https://github.com/mik-tf/ubuntail"

}

# Main installation function
main() {
    echo -e "${BLUE}Ubuntu ${UBUNTU_VERSION} and Tailscale Boot Maker${NC}"
    echo "============================================="

    case "${1:-}" in
        "create")
            shift  # Remove the 'create' command from arguments
            main "$@"  # Pass remaining arguments to main function
            ;;
        "install")
            install
            ;;
        "uninstall")
            uninstall
            ;;
        "help")
            help
            ;;
        "")
            help
            ;;
        *)
            echo -e "${RED}Invalid command: $1${NC}"
            echo -e "Use '${GREEN}ubuntail help${NC}' for usage information"
            exit 1
            ;;
    esac

    # Check internet connectivity
    check_internet

    # Check dependencies
    check_dependencies

    # Process create command arguments
    if [ "$#" -eq 5 ]; then
        ISO_PATH="$1"
        USB_DEVICE="$2"
        TAILSCALE_KEY="$3"
        NODE_USERNAME="$4"
        NODE_PASSWORD="$5"
    elif [ "$#" -eq 0 ]; then
        # Interactive mode
        # Get ISO path
        echo -e "\n${BLUE}Enter path to Ubuntu ${UBUNTU_VERSION} Server ISO:${NC}"
        read -r ISO_PATH

        # Function to list available USB devices
        list_usb_devices() {
            echo -e "\n${BLUE}Available USB devices:${NC}"
            lsblk -d -o NAME,SIZE,MODEL,SERIAL,TYPE,TRAN | grep -i "usb\|disk" | \
            while read -r line; do
                if [[ $line == *"usb"* ]] || [[ $line == *"disk"* ]]; then
                    echo "$line"
                fi
            done
            echo
        }

        # List and select USB device
        while true; do
            list_usb_devices
            echo -e "${BLUE}Enter USB device (e.g., /dev/sdb):${NC}"
            read -r USB_DEVICE
            if validate_usb_device "$USB_DEVICE"; then
                break
            fi
            echo -e "${YELLOW}Please try again with a valid device.${NC}"
        done

        # Get username (with default value)
        echo -e "\n${BLUE}Enter username (default: ubuntu):${NC}"
        read -r NODE_USERNAME

        # Get Tailscale auth key with validation
        while true; do
            echo -e "\n${BLUE}Enter Tailscale auth key:${NC}"
            read -r TAILSCALE_KEY
            if validate_tailscale_key "$TAILSCALE_KEY"; then
                break
            fi
        done

        # Get node password with confirmation
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
    else
        echo -e "${RED}Error: Invalid number of arguments${NC}"
        echo -e "Usage: ubuntail create <iso-path> <usb-device> <tailscale-key> <username> <password>"
        echo -e "   or: ubuntail create (for interactive mode)"
        exit 1
    fi

    # Verify ISO
    verify_iso "$ISO_PATH"

    # Confirm device selection with details
    echo -e "${YELLOW}Selected USB device:${NC}"
    lsblk "$USB_DEVICE" -o NAME,SIZE,MODEL,SERIAL
    read -p "Is this the correct device? This will ERASE all data! (y/N): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted"
        exit 1
    fi

    # Validate Tailscale key
    if ! validate_tailscale_key "$TAILSCALE_KEY"; then
        echo -e "${RED}Error: Invalid Tailscale auth key format${NC}"
        exit 1
    fi

    # Hash the password
    ENCRYPTED_PASS=$(mkpasswd -m sha-512 "$NODE_PASSWORD")

    # Validate USB device
    if ! validate_usb_device "$USB_DEVICE"; then
        exit 1
    fi

    # Prepare USB
    prepare_usb "$USB_DEVICE"

    # Create mount points
    echo "Creating mount points..."
    mkdir -p /mnt/{efi,usb-boot,usb-secure,iso}

    # Mount partitions
    echo "Mounting partitions..."
    mount "${USB_DEVICE}1" /mnt/efi || { echo -e "${RED}Failed to mount EFI partition${NC}"; exit 1; }
    mount "${USB_DEVICE}2" /mnt/usb-boot || { echo -e "${RED}Failed to mount boot partition${NC}"; exit 1; }
    mount /dev/mapper/secure-config /mnt/usb-secure || { echo -e "${RED}Failed to mount secure partition${NC}"; exit 1; }

    echo "Mounting ISO..."
    if mountpoint -q /mnt/iso; then
        echo "ISO mount point is already in use, attempting to unmount..."
        umount /mnt/iso || { echo -e "${RED}Failed to unmount existing ISO mount${NC}"; exit 1; }
    fi

    if ! mount -o loop "$ISO_PATH" /mnt/iso; then
        # Check if it's already mounted somewhere else
        MOUNTED_LOCATION=$(findmnt -n -o TARGET "$ISO_PATH" 2>/dev/null)
        if [ -n "$MOUNTED_LOCATION" ]; then
            echo "ISO is already mounted at $MOUNTED_LOCATION"
            echo "Using existing mount point..."
            # Create symlink to existing mount
            ln -sf "$MOUNTED_LOCATION" /mnt/iso
        else
            echo -e "${RED}Failed to mount ISO and couldn't find existing mount${NC}"
            exit 1
        fi
    fi

    # Copy ISO contents with progress and error handling
    echo "Copying Ubuntu installation files..."
    echo "This may take several minutes..."
    
    # First, try using cp for critical files
    echo "Copying essential files..."
    mkdir -p "/mnt/usb-boot/casper/"
    
    # Copy all squashfs files
    for squashfs in /mnt/iso/casper/*.squashfs /mnt/iso/casper/*.squashfs.gpg; do
        if [ -f "$squashfs" ]; then
            echo "Copying $(basename "$squashfs")..."
            cp -v "$squashfs" "/mnt/usb-boot/casper/" || {
                echo -e "${RED}Error: Failed to copy $(basename "$squashfs")${NC}"
                echo "Retrying copy with different method..."
                dd if="$squashfs" of="/mnt/usb-boot/casper/$(basename "$squashfs")" bs=1M status=progress || {
                    echo -e "${RED}Critical Error: Could not copy $(basename "$squashfs")${NC}"
                    exit 1
                }
            }
        fi
    done

    # Then copy the rest of the files
    echo "Copying remaining files..."
    rsync -ah --info=progress2 --exclude='casper/*.squashfs' --exclude='casper/*.squashfs.gpg' /mnt/iso/ /mnt/usb-boot/ || {
        echo -e "${YELLOW}Warning: Some non-critical files may not have copied completely${NC}"
        echo -e "${YELLOW}Continuing with installation...${NC}"
    }

    # Verify the squashfs files were copied correctly
    echo "Verifying squashfs files..."
    VERIFICATION_FAILED=0
    for squashfs in /mnt/iso/casper/*.squashfs; do
        if [ -f "$squashfs" ]; then
            BASENAME=$(basename "$squashfs")
            if [ -f "/mnt/usb-boot/casper/$BASENAME" ]; then
                ISO_SQUASHFS_SIZE=$(stat -c %s "$squashfs")
                USB_SQUASHFS_SIZE=$(stat -c %s "/mnt/usb-boot/casper/$BASENAME")
                if [ "$ISO_SQUASHFS_SIZE" = "$USB_SQUASHFS_SIZE" ]; then
                    echo -e "${GREEN}$BASENAME verified successfully${NC}"
                else
                    echo -e "${RED}Error: $BASENAME size mismatch${NC}"
                    echo "ISO size: $ISO_SQUASHFS_SIZE"
                    echo "USB size: $USB_SQUASHFS_SIZE"
                    VERIFICATION_FAILED=1
                fi
            else
                echo -e "${RED}Error: $BASENAME is missing after copy${NC}"
                VERIFICATION_FAILED=1
            fi
        fi
    done

    if [ $VERIFICATION_FAILED -eq 1 ]; then
        echo -e "${RED}Error: One or more squashfs files failed verification${NC}"
        exit 1
    fi

    # Unmount ISO before proceeding
    echo "Unmounting ISO..."
    umount /mnt/iso || {
        echo -e "${YELLOW}Warning: Failed to unmount ISO, attempting force unmount...${NC}"
        umount -f /mnt/iso || {
            echo -e "${RED}Error: Could not unmount ISO${NC}"
            exit 1
        }
    }

    # Verify essential files
    echo "Verifying essential files..."
    KERNEL_LOCATIONS=(
        "/mnt/usb-boot/casper/vmlinuz"
        "/mnt/usb-boot/boot/vmlinuz"
    )

    # ADD THIS NEW ARRAY RIGHT HERE, AFTER KERNEL_LOCATIONS
    INITRD_LOCATIONS=(
        "/mnt/usb-boot/casper/initrd"
        "/mnt/usb-boot/boot/initrd.img"
    )

    # Check for kernel
    KERNEL_FOUND=false
    for location in "${KERNEL_LOCATIONS[@]}"; do
        if [ -f "$location" ]; then
            KERNEL_FOUND=true
            break
        fi
    done

    # Check for initrd
    INITRD_FOUND=false
    for location in "${INITRD_LOCATIONS[@]}"; do
        if [ -f "$location" ]; then
            INITRD_FOUND=true
            break
        fi
    done

    if ! $KERNEL_FOUND; then
        echo -e "${RED}Error: Kernel file (vmlinuz) is missing${NC}"
        echo "The USB drive may not boot correctly"
        read -p "Continue anyway? (y/N): " confirm
        if [ "$confirm" != "y" ]; then
            echo "Aborting installation"
            exit 1
        fi
    fi

    if ! $INITRD_FOUND; then
        echo -e "${RED}Error: Initial ramdisk (initrd) is missing${NC}"
        echo "The USB drive may not boot correctly"
        read -p "Continue anyway? (y/N): " confirm
        if [ "$confirm" != "y" ]; then
            echo "Aborting installation"
            exit 1
        fi
    fi

    # Store credentials securely
    echo "Storing secure credentials..."
    mkdir -p /mnt/usb-secure/credentials
    cat > /mnt/usb-secure/credentials/credentials.env << EOF
TAILSCALE_AUTHKEY='${TAILSCALE_KEY}'
NODE_USERNAME='${NODE_USERNAME}'
ENCRYPTED_PASSWORD='${ENCRYPTED_PASS}'
HOSTNAME_PREFIX='node'
EOF
    chmod 600 /mnt/usb-secure/credentials/credentials.env

    # Setup GRUB
    echo "Setting up GRUB..."
    mkdir -p /mnt/usb-boot/boot/grub
    cp src/configs/grub/grub.cfg /mnt/usb-boot/boot/grub/
    
    # Install GRUB
    echo "Installing GRUB..."
    grub-install --target=x86_64-efi --efi-directory=/mnt/efi \
                --boot-directory=/mnt/usb-boot/boot --removable \
                --recheck || { echo -e "${RED}GRUB installation failed${NC}"; exit 1; }

    # Copy additional scripts and configurations
    echo "Copying additional configurations..."
    mkdir -p /mnt/usb-boot/scripts
    cp -r src/scripts/* /mnt/usb-boot/scripts/
    chmod +x /mnt/usb-boot/scripts/**/*.sh

    # Update cloud-init configurations
    mkdir -p /mnt/usb-boot/nocloud/
    cp src/configs/cloud-init/{meta-data,user-data} /mnt/usb-boot/nocloud/
    cp src/configs/system/network-config /mnt/usb-boot/nocloud/

    # Cleanup
    echo "Cleaning up..."
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

# Execute main function with all arguments
case "${1:-}" in
    "install")
        install
        ;;
    "uninstall")
        uninstall
        ;;
    "help")
        help
        ;;
    "create")
        shift  # Remove the 'create' command from arguments
        main "$@"  # Pass remaining arguments to main function
        ;;
    "")
        help
        ;;
    *)
        echo -e "${RED}Invalid command: $1${NC}"
        echo -e "Use '${GREEN}ubuntail help${NC}' for usage information"
        exit 1
        ;;
esac