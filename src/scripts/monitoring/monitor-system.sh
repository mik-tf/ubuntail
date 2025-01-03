#!/bin/bash

# Configuration
LOG_FILE="/var/log/system-monitor.log"
ALERT_THRESHOLD_CPU=90
ALERT_THRESHOLD_MEM=90
ALERT_THRESHOLD_DISK=90

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$1"
}

# Check system resources
check_system_resources() {
    # CPU Load
    CPU_LOAD=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d. -f1)
    if [ "$CPU_LOAD" -gt "$ALERT_THRESHOLD_CPU" ]; then
        log "ALERT: High CPU usage: $CPU_LOAD%"
        return 1
    fi

    # Memory Usage
    MEM_USAGE=$(free | grep Mem | awk '{print $3/$2 * 100.0}' | cut -d. -f1)
    if [ "$MEM_USAGE" -gt "$ALERT_THRESHOLD_MEM" ]; then
        log "ALERT: High memory usage: $MEM_USAGE%"
        return 1
    fi

    # Disk Usage
    DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
    if [ "$DISK_USAGE" -gt "$ALERT_THRESHOLD_DISK" ]; then
        log "ALERT: High disk usage: $DISK_USAGE%"
        return 1
    fi

    return 0
}

# Check network connectivity
check_network() {
    if ! tailscale status &>/dev/null; then
        log "ALERT: Tailscale not running"
        return 1
    fi

    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        log "ALERT: No internet connectivity"
        return 1
    fi

    return 0
}

# Self-healing functions
heal_system() {
    local issue="$1"
    log "Attempting to heal: $issue"

    case "$issue" in
        "cpu")
            TOP_PROC=$(ps aux | sort -nr -k 3 | head -1)
            log "Killing high CPU process: $TOP_PROC"
            pkill -f "$(echo "$TOP_PROC" | awk '{print $11}')"
            ;;
        "memory")
            log "Clearing page cache"
            sync; echo 1 > /proc/sys/vm/drop_caches
            ;;
        "disk")
            log "Cleaning up disk space"
            journalctl --vacuum-time=2d
            apt-get clean
            ;;
        "network")
            log "Restarting network services"
            systemctl restart networking
            systemctl restart tailscaled
            sleep 5
            source /mnt/secure/credentials/credentials.env
            tailscale up --authkey "${TAILSCALE_AUTHKEY}" --hostname "$(hostname)" --ssh
            ;;
    esac
}

# Main monitoring loop
main() {
    while true; do
        log "Starting system check..."

        if ! check_system_resources; then
            [ "$CPU_LOAD" -gt "$ALERT_THRESHOLD_CPU" ] && heal_system "cpu"
            [ "$MEM_USAGE" -gt "$ALERT_THRESHOLD_MEM" ] && heal_system "memory"
            [ "$DISK_USAGE" -gt "$ALERT_THRESHOLD_DISK" ] && heal_system "disk"
        fi

        if ! check_network; then
            heal_system "network"
        fi

        sleep 300 # Check every 5 minutes
    done
}

main