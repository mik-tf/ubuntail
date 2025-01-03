<h1> Ubuntu and Tailscale Boot Maker </h1>

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-orange.svg)](https://ubuntu.com/)
[![Tailscale](https://img.shields.io/badge/Tailscale-Enabled-green.svg)](https://tailscale.com/)

<h2>Table of Contents</h2>

- [Introduction](#introduction)
- [Features](#features)
- [Prerequisites](#prerequisites)
  - [Hardware Requirements](#hardware-requirements)
  - [Software Requirements](#software-requirements)
  - [Network Requirements](#network-requirements)
- [Detailed Installation and Usage Guide](#detailed-installation-and-usage-guide)
  - [1. USB Creation](#1-usb-creation)
  - [2. BIOS/UEFI Configuration](#2-biosuefi-configuration)
  - [3. Initial Boot and Installation](#3-initial-boot-and-installation)
  - [4. Post-Installation Setup](#4-post-installation-setup)
  - [5. Common Operations](#5-common-operations)
  - [6. Troubleshooting Common Issues](#6-troubleshooting-common-issues)
  - [7. Maintenance](#7-maintenance)
  - [8. Security Best Practices](#8-security-best-practices)
- [Documentation](#documentation)
- [Security](#security)
- [Monitoring](#monitoring)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgments](#acknowledgments)

---

## Introduction

A USB boot system for automated Ubuntu 24.04 server deployment with secure remote management capabilities with Tailscale. Perfect for headless server deployments, edge computing, and automated infrastructure setups.

## Features

- **Self-Healing**: Automatic system recovery and maintenance
- **Secure Remote Access**: Integration with Tailscale for secure networking
- **Dual-Partition System**: Encrypted storage for sensitive data
- **Monitoring**: Built-in system health checks and alerts
- **Remote Management**: Secure command and control capabilities

## Prerequisites

### Hardware Requirements
- USB drive (minimum 16GB)
- Target system with:
  - UEFI boot support
  - x86_64 architecture
  - Minimum 4GB RAM
  - Minimum 20GB storage

### Software Requirements
- Ubuntu 24.04 Server ISO
- Required packages:
  ```bash
  sudo apt update && sudo apt install -y \
    cryptsetup \
    grub-efi-amd64 \
    parted \
    tailscale \
    mkpasswd \
    whois
  ```

### Network Requirements
- Internet connection
- Tailscale account and auth key

## Detailed Installation and Usage Guide

### 1. USB Creation
```bash
# Clone and prepare installer
git clone https://github.com/Mik-TF/ubuntail_bootmaker
cd ubuntail_bootmaker
sudo bash ./install.sh

# Follow prompts for:
# - Ubuntu ISO location
# - USB device selection
# - Tailscale auth key
# - Node password
```

### 2. BIOS/UEFI Configuration
Before booting from the USB, configure the target system's BIOS/UEFI:

1. **Access BIOS/UEFI**
   - During system startup, press the BIOS key (usually F2, F12, or Del)
   - Different manufacturers use different keys:
     - Dell: F2 or F12
     - HP: F10
     - Lenovo: F1 or F2
     - ASUS: F2 or Del
     - Acer: F2 or Del

2. **Configure Boot Settings**
   - Disable Secure Boot
   - Enable UEFI Boot Mode
   - Disable Legacy/CSM Boot
   - Enable USB Boot
   - Set Boot Order:
     1. USB Drive
     2. Hard Drive
     3. Network Boot (optional)

3. **Additional Settings**
   - Enable Intel VT-x/AMD-V (for virtualization)
   - Enable Execute Disable Bit
   - Disable Fast Boot
   - Set Power On After Power Loss (if available)

4. **Save and Exit**
   - Save changes and exit BIOS
   - System will reboot

### 3. Initial Boot and Installation

1. **Boot from USB**
   - Insert the prepared USB drive
   - Power on the system
   - Wait for GRUB menu

2. **Select Installation Mode**
   ```
   Available Options:
   1. Fresh Installation (Requires Encryption Password)
   2. Boot Installed System
   3. Recovery Mode
   4. Self-Healing Mode
   ```

3. **First-Time Installation**
   - Select "Fresh Installation"
   - Enter the LUKS encryption password when prompted
   - Installation will proceed automatically
   - System will reboot when complete

### 4. Post-Installation Setup

1. **Verify Installation**
   ```bash
   # From your management system
   ./src/scripts/remote-management.sh status node-[identifier]
   ```

2. **Configure Node**
   ```bash
   # Check system health
   ./src/scripts/remote-management.sh health node-[identifier]

   # Enable monitoring
   ./src/scripts/remote-management.sh monitor node-[identifier]
   ```

### 5. Common Operations

1. **Node Management**
   ```bash
   # List all nodes
   ./src/scripts/remote-management.sh list

   # View node logs
   ./src/scripts/remote-management.sh logs node-[identifier]

   # Trigger self-healing
   ./src/scripts/remote-management.sh heal node-[identifier]
   ```

2. **Recovery Operations**
   ```bash
   # Boot into recovery mode
   ./src/scripts/boot/manage-boot.sh recovery

   # Reset to normal boot
   ./src/scripts/boot/manage-boot.sh normal
   ```

### 6. Troubleshooting Common Issues

1. **USB Not Detected**
   - Verify USB is properly formatted
   - Try different USB ports
   - Check USB in another system

2. **Boot Failures**
   - Verify BIOS settings
   - Ensure Secure Boot is disabled
   - Check UEFI boot order

3. **Network Issues**
   - Verify network cable connection
   - Check Tailscale status
   - Ensure firewall rules allow Tailscale

4. **Installation Hangs**
   - Check system meets minimum requirements
   - Verify USB drive integrity
   - Try re-creating USB installer

### 7. Maintenance

1. **Regular Updates**
   ```bash
   # Update node software
   ./src/scripts/remote-management.sh update node-[identifier]

   # Check update status
   ./src/scripts/remote-management.sh status node-[identifier]
   ```

2. **Backup Important Data**
   ```bash
   # Backup node configuration
   ./src/scripts/remote-management.sh backup node-[identifier]
   ```

3. **Monitor System Health**
   ```bash
   # View health metrics
   ./src/scripts/remote-management.sh metrics node-[identifier]
   ```

### 8. Security Best Practices

1. **Password Management**
   - Change default passwords
   - Use strong encryption passwords
   - Regularly rotate credentials

2. **Network Security**
   - Keep Tailscale updated
   - Review access logs regularly
   - Monitor network connections

3. **Physical Security**
   - Secure physical access to nodes
   - Store USB drives safely
   - Document node locations and access

## Documentation

Detailed documentation is available in the `docs` directory:
- [Installation Guide](docs/install.md)
- [Security Considerations](docs/security.md)
- [Troubleshooting Guide](docs/troubleshooting.md)

## Security

Security is a top priority:
- All sensitive data is stored in an encrypted LUKS partition
- Network access is secured through Tailscale's zero-trust network
- Regular security updates and monitoring
- UEFI Secure Boot support

## Monitoring

The system includes comprehensive monitoring:
- CPU, memory, and disk usage tracking
- Network connectivity monitoring
- Automatic issue detection and resolution
- Alert system for critical events

## Contributing

Contributions are welcome!

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Ubuntu Server team for the base system
- Tailscale for secure networking
- GRUB developers for boot management
- Community contributors and testers