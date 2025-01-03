#!/bin/bash

# Boot management script
GRUB_ENV="/boot/grub/grubenv"

usage() {
    echo "Usage: $0 {normal|install|recovery|healing}"
    echo "Manages boot options for Proof-of-Zero Boot"
    exit 1
}

set_boot_mode() {
    local mode="$1"
    case "$mode" in
        normal)   entry=0 ;;
        install)  entry=1 ;;
        recovery) entry=2 ;;
        healing)  entry=3 ;;
        *) usage ;;
    esac

    grub-editenv "$GRUB_ENV" set default="$entry"
    echo "Boot mode set to: $mode"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

[ $# -eq 1 ] || usage
set_boot_mode "$1"
