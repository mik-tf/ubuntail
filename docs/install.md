# Installation Guide

## Prerequisites

Before installation, ensure you have:

1. Ubuntu 24.04 Server ISO
2. USB drive (minimum 16GB)
3. Tailscale account and auth key
4. Required packages installed

## Installation Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/username/proof-of-zero-boot
   cd proof-of-zero-boot
   ```

2. Run the installer:
   ```bash
   sudo ./install.sh
   ```

3. Follow the prompts:
   - Provide path to Ubuntu ISO
   - Select USB device
   - Enter Tailscale auth key
   - Set node password

## Verification

After installation, verify:

1. USB is properly created:
   - Boot partition is accessible
   - GRUB menu appears on boot
   - Encrypted partition is secure

2. Node deployment:
   - Fresh installation works
   - Auto-configuration completes
   - Tailscale connection established

## Troubleshooting

Common issues and solutions:

1. USB not bootable:
   - Verify UEFI boot settings
   - Recreate USB using installer

2. Installation fails:
   - Check ISO integrity
   - Verify USB device not faulty
   - Check system requirements

3. Network issues:
   - Verify Tailscale auth key
   - Check internet connectivity
   - Confirm network settings
