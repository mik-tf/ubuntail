#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

SSH_OPTIONS="-o ConnectTimeout=10 -o BatchMode=yes"

# Execute command on remote node
execute_remote() {
    local node="$1"
    local command="$2"
    ssh $SSH_OPTIONS "ubuntu@${node}.ts.net" "$command"
}

# Check node status
check_node() {
    local node="$1"
    echo "Checking node: $node"
    
    if ! tailscale ping -c 1 "$node" &>/dev/null; then
        echo -e "${RED}❌ Node unreachable via Tailscale${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Node reachable${NC}"
    execute_remote "$node" "health-check"
}

# Trigger self-healing
trigger_healing() {
    local node="$1"
    echo "Triggering self-healing on node: $node"
    execute_remote "$node" "sudo /usr/local/bin/self-heal.sh"
}

# Main command handler
case "$1" in
    list)
        echo "Available nodes:"
        tailscale status | grep "node-" | awk '{print $1}'
        ;;
    status)
        [ -z "$2" ] && echo "Usage: $0 status <node>" && exit 1
        check_node "$2"
        ;;
    heal)
        [ -z "$2" ] && echo "Usage: $0 heal <node>" && exit 1
        trigger_healing "$2"
        ;;
    restart)
        [ -z "$2" ] && echo "Usage: $0 restart <node>" && exit 1
        execute_remote "$2" "sudo reboot"
        ;;
    logs)
        [ -z "$2" ] && echo "Usage: $0 logs <node>" && exit 1
        execute_remote "$2" "sudo tail -f /var/log/system-monitor.log"
        ;;
    *)
        echo "Usage: $0 {list|status|heal|restart|logs} [node]"
        exit 1
        ;;
esac
