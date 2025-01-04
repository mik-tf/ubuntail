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
    
    # Check if device path is /dev/sda
    if [[ "$device" == "/dev/sda" || "$device" == "/dev/sda"[0-9]* ]]; then
        echo -e "${RED}Error: Cannot use /dev/sda as it is typically the system drive${NC}"
        echo -e "${YELLOW}Please select a different device (e.g., /dev/sdb, /dev/sdc)${NC}"
        return 1
    fi

    # Check if device path matches expected pattern
    if ! [[ "$device" =~ ^/dev/sd[b-z]$ ]]; then
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
    read -p "Is this the correct device? (y/N): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted"
        exit 1
    fi
    
    # Unmount any existing partitions
    umount "${USB_DEVICE}"* 2>/dev/null || true
    
    # Create partitions
    echo "Creating partition table..."
    parted "$USB_DEVICE" --script mklabel gpt

    echo "Creating partitions..."
    parted "$USB_DEVICE" --script \
        mkpart "EFI" fat32 1MiB 512MiB \
        mkpart "UBUNTU-BOOT" fat32 512MiB 7GiB \
        mkpart "SECURE-CONFIG" 7GiB 100%
    
    parted "$USB_DEVICE" --script set 1 esp on
    parted "$USB_DEVICE" --script set 2 boot on
    
    # Wait for the system to recognize the new partitions
    echo "Waiting for partitions to be recognized..."
    sleep 5
    partprobe "$USB_DEVICE"
    sleep 2
    
    # Format partitions
    echo "Formatting EFI partition..."
    mkfs.fat -F 32 -n "EFI" "${USB_DEVICE}1"
    
    echo "Formatting boot partition..."
    mkfs.fat -F 32 -n "UBUNTU-BOOT" "${USB_DEVICE}2"
    
    # Setup encrypted partition with better security
    echo "Setting up encrypted partition..."
    echo -e "${YELLOW}You will be asked to set an encryption passphrase for the secure configuration partition.${NC}"
    echo -e "${YELLOW}Please remember this passphrase as it will be needed to access the secure data.${NC}"
    echo

    # Create encrypted partition
    cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${USB_DEVICE}3"

    echo -e "\n${YELLOW}Now enter the same passphrase again to open the encrypted partition:${NC}"
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

        # List and select USB device
        while true; do
            echo -e "\n${BLUE}Available USB devices:${NC}"
            lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT | grep "disk" | grep -v "sda"
            echo -e "\n${BLUE}Enter USB device (e.g., /dev/sdb):${NC}"
            read -r USB_DEVICE
            if validate_usb_device "$USB_DEVICE"; then
                break
            fi
            echo -e "${YELLOW}Please try again with a valid device.${NC}"
        done

        # Get username (with default value)
        echo -e "\n${BLUE}Enter username (default: ubuntu):${NC}"
        read -r NODE_USERNAME
        NODE_USERNAME=${NODE_USERNAME:-ubuntu}  # Use 'ubuntu' if no input provided

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
    mount -o loop "$ISO_PATH" /mnt/iso || { echo -e "${RED}Failed to mount ISO${NC}"; exit 1; }

    # Copy ISO contents with progress
    echo "Copying Ubuntu installation files..."
    rsync -ah --progress /mnt/iso/ /mnt/usb-boot/

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