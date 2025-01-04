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
REQUIRED_SPACE_GB=32
UBUNTU_VERSION="24.04"
TAILSCALE_RETRY_ATTEMPTS=3
TAILSCALE_RETRY_DELAY=30
LOG_FILE="/var/log/ubuntu-desktop-tailscale-installer.log"

# Function to setup logging
setup_logging() {
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
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

# Function to install ubuntail
install() {
    echo
    echo -e "${GREEN}Installing Ubuntail Desktop...${NC}"
    
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Please run with sudo privileges${NC}"
        exit 1
    fi

    INSTALL_DIR="/usr/local/bin"
    if [ ! -d "$INSTALL_DIR" ]; then
        mkdir -p "$INSTALL_DIR"
    fi

    # Get the script name without path and extension
    SCRIPT_NAME=$(basename "$0")
    SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

    if cp "$0" "$INSTALL_DIR/$SCRIPT_NAME_NO_EXT"; then
        chown root:root "$INSTALL_DIR/$SCRIPT_NAME_NO_EXT"
        chmod 755 "$INSTALL_DIR/$SCRIPT_NAME_NO_EXT"

        echo
        echo -e "${PURPLE}Ubuntail Desktop has been installed successfully.${NC}"
        echo -e "Installation location: ${GREEN}$INSTALL_DIR/$SCRIPT_NAME_NO_EXT${NC}"
        echo
        echo -e "Use ${BLUE}$SCRIPT_NAME_NO_EXT help${NC} to see the available commands."
        echo
    else
        echo -e "${RED}Error: Failed to copy script to $INSTALL_DIR${NC}"
        exit 1
    fi

    if command -v ubuntail >/dev/null 2>&1; then
        echo -e "${GREEN}Installation verified successfully.${NC}"
    else
        echo -e "${RED}Warning: Installation completed but 'ubuntail' command not found in PATH.${NC}"
        echo -e "You may need to add $INSTALL_DIR to your PATH or restart your terminal."
    fi
}

uninstall() {
    echo
    echo -e "${GREEN}Uninstalling Ubuntail Desktop...${NC}"
    
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Please run with sudo privileges${NC}"
        exit 1
    fi

    SCRIPT_NAME=$(basename "$0")
    SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
    INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME_NO_EXT"

    if [ ! -f "$INSTALL_PATH" ]; then
        echo -e "${RED}Error: Ubuntail Desktop is not installed at $INSTALL_PATH${NC}"
        exit 1
    fi

    if rm -f "$INSTALL_PATH"; then
        echo -e "${PURPLE}Ubuntail Desktop has been uninstalled successfully.${NC}"
        echo -e "Removed: ${RED}$INSTALL_PATH${NC}"
        echo
    else
        echo -e "${RED}Error: Failed to remove $INSTALL_PATH${NC}"
        echo -e "Please check file permissions and try again."
        exit 1
    fi

    if command -v "$SCRIPT_NAME_NO_EXT" >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: '$SCRIPT_NAME_NO_EXT' command is still available in your system.${NC}"
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
        "casper"  # Added for Desktop ISO
        "plymouth"  # Added for Desktop ISO
        "ubiquity"  # Added for Desktop ISO
    )

    echo "Checking dependencies..."
    local MISSING_DEPS=()
    for dep in "${DEPS[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$dep"; then
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

    if ! file "$ISO_PATH" | grep -q "Ubuntu.*${UBUNTU_VERSION}.*Desktop"; then
        echo -e "${YELLOW}Warning: This doesn't appear to be an Ubuntu ${UBUNTU_VERSION} Desktop ISO${NC}"
        read -p "Continue anyway? (y/N): " confirm
        if [ "$confirm" != "y" ]; then
            exit 1
        fi
    fi

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
    
    if [[ "$device" == "/dev/sda" || "$device" == "/dev/sda"[0-9]* ]]; then
        echo -e "${RED}Error: Cannot use /dev/sda as it is typically the system drive${NC}"
        echo -e "${YELLOW}Please select a different device (e.g., /dev/sdb, /dev/sdc)${NC}"
        return 1
    fi

    if ! [[ "$device" =~ ^/dev/sd[b-z]$ ]]; then
        echo -e "${RED}Error: Invalid device path${NC}"
        echo -e "${YELLOW}Device path should be in the format /dev/sdb, /dev/sdc, etc.${NC}"
        return 1
    fi

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
    
    DEVICE_SIZE=$(blockdev --getsize64 "$USB_DEVICE" | awk '{print $1/1024/1024/1024}')
    if [ "${DEVICE_SIZE%.*}" -lt "$REQUIRED_SPACE_GB" ]; then
        echo -e "${RED}Error: USB device too small. Need at least ${REQUIRED_SPACE_GB}GB${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Selected USB device:${NC}"
    lsblk "$USB_DEVICE" -o NAME,SIZE,MODEL,SERIAL
    echo -e "${RED}WARNING: ALL DATA ON THIS DEVICE WILL BE ERASED!${NC}"
    read -p "Is this the correct device? (y/N): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted"
        exit 1
    fi

    # Unmount and prepare device
    for partition in ${USB_DEVICE}*; do
        if mount | grep -q "$partition"; then
            umount -f "$partition" 2>/dev/null || true
        fi
    done

    # Clear existing partition table
    wipefs -a "$USB_DEVICE"
    dd if=/dev/zero of="$USB_DEVICE" bs=1M count=10 conv=fsync

    # Create new GPT partition table
    parted -s "$USB_DEVICE" mklabel gpt

    # Create partitions for Desktop installation
    parted -s "$USB_DEVICE" mkpart "EFI" fat32 1MiB 512MiB
    parted -s "$USB_DEVICE" mkpart "UBUNTU-DESKTOP" fat32 512MiB 30GiB
    parted -s "$USB_DEVICE" mkpart "PERSISTENCE" ext4 30GiB 100%

    # Set flags
    parted -s "$USB_DEVICE" set 1 esp on
    parted -s "$USB_DEVICE" set 2 boot on

    # Format partitions
    mkfs.fat -F 32 -n "EFI" "${USB_DEVICE}1"
    mkfs.fat -F 32 -n "UBUNTU-DESKTOP" "${USB_DEVICE}2"
    mkfs.ext4 -L "PERSISTENCE" "${USB_DEVICE}3"

    sync
    sleep 2
}

# Function to copy ISO contents
copy_iso_contents() {
    local ISO_PATH="$1"
    local USB_DEVICE="$2"

    # Create mount points
    mkdir -p /mnt/{iso,efi,desktop,persistence}

    # Mount partitions
    mount "${USB_DEVICE}1" /mnt/efi
    mount "${USB_DEVICE}2" /mnt/desktop
    mount "${USB_DEVICE}3" /mnt/persistence
    mount -o loop "$ISO_PATH" /mnt/iso

    # Copy ISO contents
    echo "Copying Ubuntu Desktop files (this may take a while)..."
    rsync -ah --info=progress2 /mnt/iso/ /mnt/desktop/

    # Setup persistence
    echo "Setting up persistence..."
    mkdir -p /mnt/persistence/upper /mnt/persistence/work
    cat > /mnt/persistence/persistence.conf << EOF
/ union
/home union
/var union
/usr union
/etc union
EOF

    # Install GRUB
    echo "Installing GRUB..."
    grub-install --target=x86_64-efi --efi-directory=/mnt/efi \
                --boot-directory=/mnt/desktop/boot --removable

    # Create custom GRUB configuration
    cat > /mnt/desktop/boot/grub/grub.cfg << EOF
set default=0
set timeout=10

menuentry "Ubuntu Desktop Live" {
    set gfxpayload=keep
    linux /casper/vmlinuz boot=casper persistent quiet splash ---
    initrd /casper/initrd
}

menuentry "Ubuntu Desktop Install" {
    set gfxpayload=keep
    linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
    initrd /casper/initrd
}
EOF

    # Cleanup
    sync
    umount /mnt/{iso,efi,desktop,persistence}
    rm -rf /mnt/{iso,efi,desktop,persistence}
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

# Help function
help() {
    echo -e "\n${ORANGE}═══════════════════════════════════════════${NC}"
    echo -e "${ORANGE}         Ubuntail Desktop Edition           ${NC}"
    echo -e "${ORANGE}═══════════════════════════════════════════${NC}\n"
    
    echo -e "${PURPLE}Description:${NC} Create bootable Ubuntu ${UBUNTU_VERSION} Desktop USB with Tailscale integration"
    echo -e "${PURPLE}Usage:${NC}       ubuntail [command] [arguments]"
    
    echo -e "${PURPLE}Commands:${NC}"
    echo -e "  ${GREEN}create <iso-path> <usb-device> <tailscale-key>${NC}"
    echo -e "                  Create bootable USB with Ubuntu Desktop and Tailscale"
    echo -e "                  ${BLUE}Example:${NC} ubuntail create ubuntu-desktop.iso /dev/sdb tskey-xxx-xxx\n"
    
    echo -e "  ${GREEN}install${NC}"
    echo -e "                  Install Ubuntail Desktop to system"
    echo -e "                  ${BLUE}Example:${NC} sudo ubuntail install\n"
    
    echo -e "  ${GREEN}uninstall${NC}"
    echo -e "                  Remove Ubuntail Desktop from system"
    echo -e "                  ${BLUE}Example:${NC} sudo ubuntail uninstall\n"
    
    echo -e "${PURPLE}Requirements:${NC}"
    echo -e "  - Ubuntu ${UBUNTU_VERSION} Desktop ISO"
    echo -e "  - USB drive (minimum ${REQUIRED_SPACE_GB}GB)"
    echo -e "  - Tailscale authentication key"
    echo -e "  - Root privileges\n"
}

# Main function
main() {
    echo -e "${BLUE}Ubuntu ${UBUNTU_VERSION} Desktop and Tailscale Boot Maker${NC}"
    echo "=================================================="

    case "${1:-}" in
        "create")
            shift
            if [ "$#" -ne 3 ]; then
                echo -e "${RED}Error: Invalid number of arguments${NC}"
                echo "Usage: ubuntail create <iso-path> <usb-device> <tailscale-key>"
                exit 1
            fi
            
            ISO_PATH="$1"
            USB_DEVICE="$2"
            TAILSCALE_KEY="$3"

            # Validate inputs
            verify_iso "$ISO_PATH"
            validate_usb_device "$USB_DEVICE"
            validate_tailscale_key "$TAILSCALE_KEY"

            # Prepare and create bootable USB
            check_dependencies
            prepare_usb "$USB_DEVICE"
            copy_iso_contents "$ISO_PATH" "$USB_DEVICE"

            echo -e "${GREEN}Ubuntu Desktop USB created successfully!${NC}"
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

        *)
            help
            ;;
    esac
}

# Execute main with all arguments
main "$@"