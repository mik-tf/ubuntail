#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

print_status() {
    local service="$1"
    local status="$2"
    local message="$3"
    printf "%-20s [%s] %s\n" "$service" "$status" "$message"
}

# System uptime
uptime_formatted=$(uptime -p)
print_status "System Uptime" "INFO" "$uptime_formatted"

# CPU Load
cpu_load=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
if [ $(echo "$cpu_load > 90" | bc -l) -eq 1 ]; then
    print_status "CPU Load" "${RED}WARN${NC}" "$cpu_load%"
else
    print_status "CPU Load" "${GREEN}OK${NC}" "$cpu_load%"
fi

# Memory Usage
mem_info=$(free -h | awk 'NR==2{printf "%.1f%%\t%s/%s", $3*100/$2, $3,$2 }')
print_status "Memory Usage" "INFO" "$mem_info"

# Disk Usage
disk_info=$(df -h / | awk 'NR==2{printf "%s\t%s/%s", $5, $3,$2}')
print_status "Disk Usage" "INFO" "$disk_info"

# Tailscale Status
if tailscale status &>/dev/null; then
    print_status "Tailscale" "${GREEN}OK${NC}" "Running"
else
    print_status "Tailscale" "${RED}FAIL${NC}" "Not running"
fi

# Recent System Issues
echo -e "\nRecent System Issues:"
tail -n 5 /var/log/system-monitor.log