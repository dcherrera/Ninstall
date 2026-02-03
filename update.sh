#!/bin/bash
#
# NodeNook Update Script
# Run this on EXISTING nodes to add auto-recovery features
#
# Usage:
#   cd ~/Ninstall && git pull && ./update.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[NodeNook]${NC} $1"; }
success() { echo -e "${GREEN}[NodeNook]${NC} $1"; }
warn() { echo -e "${YELLOW}[NodeNook]${NC} $1"; }
error() { echo -e "${RED}[NodeNook]${NC} $1"; exit 1; }
header() { echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"; }

# NodeNook data directory
NODENOOK_DIR="/opt/nodenook"
NODENOOK_CONFIG="$NODENOOK_DIR/config"

header "NodeNook Update - Auto-Recovery"
echo "This script will add/update auto-recovery features on this node."
echo ""
echo "It will install:"
echo "  - Avahi (mDNS discovery)"
echo "  - Auto-recovery script"
echo "  - Systemd service for boot recovery"
echo ""

# Get current hostname
NEW_HOSTNAME=$(hostname)
NODE_IP=$(hostname -I | awk '{print $1}')

log "Hostname: $NEW_HOSTNAME"
log "IP: $NODE_IP"
echo ""

# ============================================================
# Step 1: Install Avahi (mDNS)
# ============================================================
header "Step 1: mDNS Discovery"

if command -v avahi-resolve &> /dev/null; then
    log "Avahi is already installed"
else
    log "Installing Avahi for hostname-based discovery..."

    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y avahi-daemon avahi-utils libnss-mdns
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y avahi nss-mdns avahi-tools
    elif command -v yum &> /dev/null; then
        sudo yum install -y avahi nss-mdns avahi-tools
    else
        warn "Could not install Avahi automatically."
    fi
fi

# Enable and start avahi
sudo systemctl enable avahi-daemon 2>/dev/null || true
sudo systemctl start avahi-daemon 2>/dev/null || true

# Ensure nsswitch.conf includes mdns
if [ -f /etc/nsswitch.conf ]; then
    if ! grep -q "mdns" /etc/nsswitch.conf; then
        log "Configuring nsswitch for mDNS..."
        sudo sed -i 's/^hosts:.*/hosts: files mdns_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf
    fi
fi

success "mDNS discovery enabled - node reachable as ${NEW_HOSTNAME}.local"

# ============================================================
# Step 2: Create directories
# ============================================================
header "Step 2: Directories"

log "Creating NodeNook directories..."
sudo mkdir -p "$NODENOOK_CONFIG"
sudo mkdir -p "$NODENOOK_DIR/bin"
sudo mkdir -p "$NODENOOK_DIR/logs"
sudo chown -R $USER:$USER "$NODENOOK_DIR"

success "Directories ready"

# ============================================================
# Step 3: Setup cluster.env
# ============================================================
header "Step 3: Cluster Configuration"

if [ -f "$NODENOOK_CONFIG/cluster.env" ]; then
    log "Existing cluster.env found"
    source "$NODENOOK_CONFIG/cluster.env"
    log "  Cluster nodes: $CLUSTER_HOSTNAMES"
else
    log "No cluster.env found, creating new one..."

    # Ask for other node hostnames
    echo ""
    echo "Enter all cluster node hostnames (space-separated)."
    echo "Example: surface-pro2 surface-pro3 surface-pro7"
    echo ""
    read -p "Hostnames [$NEW_HOSTNAME]: " INPUT_HOSTNAMES </dev/tty

    CLUSTER_HOSTNAMES="${INPUT_HOSTNAMES:-$NEW_HOSTNAME}"

    cat > "$NODENOOK_CONFIG/cluster.env" << EOF
# NodeNook Cluster Configuration
# All node hostnames (whitelist for auto-recovery)
# Generated: $(date)

CLUSTER_HOSTNAMES="$CLUSTER_HOSTNAMES"
CLUSTER_USER="$USER"
EOF
fi

# Ensure this node is in the list
source "$NODENOOK_CONFIG/cluster.env"
if ! echo "$CLUSTER_HOSTNAMES" | grep -qw "$NEW_HOSTNAME"; then
    CLUSTER_HOSTNAMES="$CLUSTER_HOSTNAMES $NEW_HOSTNAME"
    sed -i "s/^CLUSTER_HOSTNAMES=.*/CLUSTER_HOSTNAMES=\"$CLUSTER_HOSTNAMES\"/" "$NODENOOK_CONFIG/cluster.env"
    log "Added $NEW_HOSTNAME to cluster hostnames"
fi

chmod 600 "$NODENOOK_CONFIG/cluster.env"
success "Cluster configuration ready"
log "  Nodes: $CLUSTER_HOSTNAMES"

# ============================================================
# Step 4: Install Auto-Recovery Script
# ============================================================
header "Step 4: Auto-Recovery Script"

log "Installing auto-recovery script..."

sudo tee "$NODENOOK_DIR/bin/swarm-recovery.sh" > /dev/null << 'RECOVERY_SCRIPT'
#!/bin/bash
#
# NodeNook Swarm Auto-Recovery Script
# Self-healing with dynamic leader election (lowest hostname = leader)
#

set -e

CONFIG_DIR="/opt/nodenook/config"
LOG_DIR="/opt/nodenook/logs"
LOG="$LOG_DIR/recovery.log"

mkdir -p "$LOG_DIR"

if [ ! -f "$CONFIG_DIR/cluster.env" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: cluster.env not found" >> "$LOG"
    exit 1
fi
source "$CONFIG_DIR/cluster.env"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG" >&2; }

MY_HOSTNAME=$(hostname)

discover_online_nodes() {
    local online=""
    for host in $CLUSTER_HOSTNAMES; do
        local ip=""
        ip=$(avahi-resolve -n "${host}.local" 2>/dev/null | awk '{print $2}')
        [ -z "$ip" ] && ip=$(getent hosts "${host}.local" 2>/dev/null | awk '{print $1}')
        [ -z "$ip" ] && ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1}')
        [ -z "$ip" ] && continue

        if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            "$CLUSTER_USER@${host}.local" "true" 2>/dev/null; then
            online="$online $host"
        elif ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            "$CLUSTER_USER@$ip" "true" 2>/dev/null; then
            online="$online $host"
        fi
    done
    echo $online | tr ' ' '\n' | sort | tr '\n' ' ' | xargs
}

am_i_leader() {
    local online_sorted="$1"
    local first=$(echo $online_sorted | awk '{print $1}')
    [ "$first" = "$MY_HOSTNAME" ]
}

try_rejoin() {
    for host in $CLUSTER_HOSTNAMES; do
        [ "$host" = "$MY_HOSTNAME" ] && continue
        local ip=""
        ip=$(avahi-resolve -n "${host}.local" 2>/dev/null | awk '{print $2}')
        [ -z "$ip" ] && ip=$(getent hosts "${host}.local" 2>/dev/null | awk '{print $1}')
        [ -z "$ip" ] && continue

        local token=""
        token=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            "$CLUSTER_USER@${host}.local" "docker swarm join-token manager -q 2>/dev/null" 2>/dev/null || true)

        if [ -n "$token" ] && [[ "$token" == SWMTKN-* ]]; then
            log "Got token from $host, attempting to join..."
            docker swarm leave --force 2>/dev/null || true
            sleep 2
            if docker swarm join --token "$token" "${ip}:2377" 2>/dev/null; then
                log "Successfully rejoined swarm via $host ($ip)"
                return 0
            fi
        fi
    done
    return 1
}

cache_tokens() {
    docker swarm join-token manager -q > "$CONFIG_DIR/manager.token" 2>/dev/null || true
    docker swarm join-token worker -q > "$CONFIG_DIR/worker.token" 2>/dev/null || true
    chmod 600 "$CONFIG_DIR"/*.token 2>/dev/null || true
}

main() {
    log "=========================================="
    log "NodeNook Auto-Recovery Starting"
    log "Hostname: $MY_HOSTNAME"
    log "Cluster nodes: $CLUSTER_HOSTNAMES"
    log "=========================================="

    if docker node ls &>/dev/null 2>&1; then
        log "Swarm is healthy, caching tokens and exiting"
        cache_tokens
        exit 0
    fi

    log "Swarm is unhealthy or not active, starting recovery..."
    log "Waiting for network..."
    sleep 10

    local online=$(discover_online_nodes)
    local online_count=$(echo $online | wc -w)
    log "Online nodes ($online_count): $online"

    if [ $online_count -eq 0 ]; then
        log "No other nodes reachable. Waiting and retrying..."
        sleep 30
        online=$(discover_online_nodes)
        online_count=$(echo $online | wc -w)
        log "Retry - Online nodes ($online_count): $online"
    fi

    log "Attempting to rejoin existing cluster..."
    if try_rejoin; then
        cache_tokens
        exit 0
    fi

    if am_i_leader "$online"; then
        log "I am recovery leader (lowest hostname among online nodes)"
        log "Waiting 90s to allow other nodes to come online..."
        sleep 90

        online=$(discover_online_nodes)
        log "After wait - Online nodes: $online"

        if try_rejoin; then
            cache_tokens
            exit 0
        fi

        log "All recovery attempts failed. Forcing new cluster..."
        docker swarm leave --force 2>/dev/null || true
        sleep 2

        local my_ip=$(hostname -I | awk '{print $1}')
        if docker swarm init --advertise-addr "$my_ip"; then
            log "New cluster created with advertise address: $my_ip"
            cache_tokens

            log "Notifying other nodes to rejoin..."
            for host in $CLUSTER_HOSTNAMES; do
                [ "$host" = "$MY_HOSTNAME" ] && continue
                ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                    "$CLUSTER_USER@${host}.local" \
                    "sudo systemctl restart nodenook-recovery 2>/dev/null" &
            done
            wait
            log "Recovery complete - new cluster created"
            exit 0
        else
            log_error "Failed to initialize new swarm"
            exit 1
        fi
    else
        log "Not the leader, waiting for leader to recover cluster..."
        for i in $(seq 1 12); do
            sleep 30
            log "Retry $i/12 - attempting to rejoin..."
            if try_rejoin; then
                cache_tokens
                log "Successfully rejoined on retry $i"
                exit 0
            fi
        done
        log_error "Max retries exceeded, recovery failed."
        exit 1
    fi
}

main "$@"
RECOVERY_SCRIPT

sudo chmod 700 "$NODENOOK_DIR/bin/swarm-recovery.sh"
sudo chown root:root "$NODENOOK_DIR/bin/swarm-recovery.sh"
success "Auto-recovery script installed"

# ============================================================
# Step 5: Install Systemd Service
# ============================================================
header "Step 5: Systemd Service"

log "Installing auto-recovery systemd service..."

sudo tee /etc/systemd/system/nodenook-recovery.service > /dev/null << 'SYSTEMD_SERVICE'
[Unit]
Description=NodeNook Swarm Auto-Recovery
Documentation=https://github.com/dcherrera/Ninstall
After=network-online.target docker.service avahi-daemon.service
Wants=network-online.target docker.service avahi-daemon.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
ExecStart=/opt/nodenook/bin/swarm-recovery.sh
TimeoutStartSec=600
StandardOutput=append:/opt/nodenook/logs/recovery.log
StandardError=append:/opt/nodenook/logs/recovery.log

[Install]
WantedBy=multi-user.target
SYSTEMD_SERVICE

sudo systemctl daemon-reload
sudo systemctl enable nodenook-recovery.service
success "Auto-recovery service enabled"

# ============================================================
# Step 6: Sync to Other Nodes
# ============================================================
header "Step 6: Sync Cluster Config"

log "Syncing cluster.env to other nodes..."

source "$NODENOOK_CONFIG/cluster.env"
SYNC_COUNT=0

for host in $CLUSTER_HOSTNAMES; do
    [ "$host" = "$NEW_HOSTNAME" ] && continue
    if scp -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        "$NODENOOK_CONFIG/cluster.env" "$USER@${host}.local:$NODENOOK_CONFIG/cluster.env" 2>/dev/null; then
        log "  Synced to $host"
        SYNC_COUNT=$((SYNC_COUNT + 1))
    else
        warn "  Could not sync to $host (run update.sh there too)"
    fi
done

if [ $SYNC_COUNT -gt 0 ]; then
    success "Cluster config synced to $SYNC_COUNT node(s)"
fi

# ============================================================
# Complete!
# ============================================================
header "Update Complete!"

success "Auto-recovery features installed!"
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  Node: $NEW_HOSTNAME"
echo "│  mDNS: ${NEW_HOSTNAME}.local"
echo "├─────────────────────────────────────────────────────────────┤"
echo "│  Recovery script: $NODENOOK_DIR/bin/swarm-recovery.sh"
echo "│  Recovery logs:   $NODENOOK_DIR/logs/recovery.log"
echo "│  Cluster config:  $NODENOOK_CONFIG/cluster.env"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
echo "The cluster will now self-heal after reboots or IP changes."
echo ""
echo "To update other nodes, run on each:"
echo "  cd ~/Ninstall && git pull && ./update.sh"
echo ""
echo "Useful commands:"
echo "  systemctl status nodenook-recovery  # Check service"
echo "  cat $NODENOOK_DIR/logs/recovery.log # View logs"
echo "  sudo systemctl restart nodenook-recovery  # Test recovery"
echo ""
