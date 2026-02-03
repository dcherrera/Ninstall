#!/bin/bash
#
# NodeNook Setup Script
# Run this on ADDITIONAL machines to join an existing swarm
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/dcherrera/NodeNook/main/setup.sh | bash
#   # or
#   ./setup.sh
#
# Prerequisites:
#   - First node must already be running (use bootstrap.sh for that)
#   - You need the manager IP and join token from the first node
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

header "NodeNook Setup"
echo "This script will add this machine to an existing NodeNook cluster."
echo ""
echo "It will:"
echo "  1. Install Docker (if not present)"
echo "  2. Install Avahi for mDNS discovery (hostname.local)"
echo "  3. Set the hostname"
echo "  4. Join the Docker Swarm as a manager"
echo "  5. Set up SSH access for the dashboard"
echo "  6. Install auto-recovery service (self-healing after reboot/IP change)"
echo "  7. Configure shelf mode (no sleep, lid close ignored)"
echo ""
echo "You'll need:"
echo "  - The IP address of an existing swarm manager"
echo "  - The pairing code (from NodeNook app)"
echo ""
read -p "Press Enter to continue (or Ctrl+C to cancel)..." </dev/tty

# ============================================================
# Step 1: Check/Install Docker
# ============================================================
header "Step 1: Docker"

if command -v docker &> /dev/null; then
    log "Docker is already installed: $(docker --version)"
else
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    success "Docker installed!"
fi

# Add current user to docker group if not already
if ! groups | grep -q docker; then
    log "Adding $USER to docker group..."
    sudo usermod -aG docker $USER
    log "Refreshing group membership..."
    exec sg docker -c "$0 $*"
fi

# Enable Docker on boot
sudo systemctl enable docker 2>/dev/null || true

# Verify Docker works
if ! docker info &> /dev/null; then
    error "Docker is not running. Please start Docker and try again."
fi

success "Docker is ready!"

# ============================================================
# Step 1b: Install Avahi (mDNS for hostname discovery)
# ============================================================
header "Step 1b: mDNS Discovery"

log "Installing Avahi for hostname-based discovery..."

if command -v apt-get &> /dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y avahi-daemon avahi-utils libnss-mdns
elif command -v dnf &> /dev/null; then
    sudo dnf install -y avahi nss-mdns avahi-tools
elif command -v yum &> /dev/null; then
    sudo yum install -y avahi nss-mdns avahi-tools
else
    warn "Could not install Avahi automatically. mDNS discovery may not work."
fi

# Enable and start avahi
sudo systemctl enable avahi-daemon 2>/dev/null || true
sudo systemctl start avahi-daemon 2>/dev/null || true

# Ensure nsswitch.conf includes mdns for hostname resolution
if [ -f /etc/nsswitch.conf ]; then
    if ! grep -q "mdns" /etc/nsswitch.conf; then
        log "Configuring nsswitch for mDNS..."
        sudo sed -i 's/^hosts:.*/hosts: files mdns_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf
    fi
fi

success "mDNS discovery enabled!"
log "This node will be discoverable as: ${NEW_HOSTNAME:-$(hostname)}.local"

# ============================================================
# Step 2: Check if already in a swarm
# ============================================================
header "Step 2: Swarm Status"

if docker info 2>/dev/null | grep -q "Swarm: active"; then
    warn "This machine is already part of a swarm!"
    if docker info 2>/dev/null | grep -q "Is Manager: true"; then
        log "This node is a swarm manager."
        docker node ls
        echo ""
        read -p "Continue anyway? This will NOT re-join the swarm. [y/N]: " CONTINUE </dev/tty
        if [[ ! $CONTINUE =~ ^[Yy]$ ]]; then
            exit 0
        fi
        ALREADY_IN_SWARM=true
    else
        log "This node is a worker. To become a manager, leave the swarm first:"
        echo "  docker swarm leave"
        echo ""
        echo "Then run this script again."
        exit 1
    fi
else
    ALREADY_IN_SWARM=false
fi

# ============================================================
# Step 3: Set Hostname
# ============================================================
header "Step 3: Hostname"

CURRENT_HOSTNAME=$(hostname)
log "Current hostname: $CURRENT_HOSTNAME"
echo ""

# Suggest next node number
if [ "$CURRENT_HOSTNAME" = "localhost" ] || [[ "$CURRENT_HOSTNAME" =~ ^ubuntu ]]; then
    read -p "Enter hostname for this node [node-2]: " NEW_HOSTNAME </dev/tty
    NEW_HOSTNAME=${NEW_HOSTNAME:-node-2}
else
    read -p "Enter hostname for this node [$CURRENT_HOSTNAME]: " NEW_HOSTNAME </dev/tty
    NEW_HOSTNAME=${NEW_HOSTNAME:-$CURRENT_HOSTNAME}
fi

if [ "$CURRENT_HOSTNAME" != "$NEW_HOSTNAME" ]; then
    log "Setting hostname to: $NEW_HOSTNAME"
    sudo hostnamectl set-hostname "$NEW_HOSTNAME"

    # Update /etc/hosts
    if ! grep -q "$NEW_HOSTNAME" /etc/hosts; then
        echo "127.0.1.1 $NEW_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
    fi
    success "Hostname set to: $NEW_HOSTNAME"
else
    log "Hostname unchanged."
fi

# ============================================================
# Step 4: Join Swarm
# ============================================================
header "Step 4: Join Swarm"

if [ "$ALREADY_IN_SWARM" = true ]; then
    log "Already in swarm, skipping join..."
else
    echo "On the existing swarm manager, run: ./pair.sh"
    echo "This will show you a Manager IP and a short 6-character Pairing Code."
    echo ""

    read -p "Manager IP address: " MANAGER_IP </dev/tty
    if [ -z "$MANAGER_IP" ]; then
        error "Manager IP is required."
    fi

    echo ""
    read -p "Pairing code (6 characters): " PAIR_CODE </dev/tty
    if [ -z "$PAIR_CODE" ]; then
        error "Pairing code is required."
    fi

    # Fetch the token from the pairing server
    log "Fetching join token from manager..."
    MANAGER_TOKEN=$(curl -sf "http://$MANAGER_IP:9876/" 2>/dev/null)

    if [ -z "$MANAGER_TOKEN" ]; then
        echo ""
        warn "Could not fetch token from pairing server."
        echo "Make sure the Add Node dialog is open in NodeNook."
        echo ""
        echo "Or enter the full token manually:"
        read -p "Manager join token: " MANAGER_TOKEN </dev/tty
        if [ -z "$MANAGER_TOKEN" ]; then
            error "Manager token is required."
        fi
    fi

    # Fetch SSH keys from pairing server
    log "Fetching SSH keys..."
    SSH_KEYS=$(curl -sf "http://$MANAGER_IP:9876/keys" 2>/dev/null)
    if [ -n "$SSH_KEYS" ]; then
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        # Add keys if not already present
        while IFS= read -r key; do
            if [ -n "$key" ] && ! grep -qF "$key" ~/.ssh/authorized_keys 2>/dev/null; then
                echo "$key" >> ~/.ssh/authorized_keys
            fi
        done <<< "$SSH_KEYS"
        success "SSH keys added!"
    fi

    echo ""
    log "Joining swarm as a manager..."
    docker swarm join --token "$MANAGER_TOKEN" "$MANAGER_IP:2377"
    success "Joined swarm!"
fi

# ============================================================
# Step 5: Create NodeNook directories and Auto-Recovery
# ============================================================
header "Step 5: Configuration & Auto-Recovery"

log "Creating NodeNook directories..."
sudo mkdir -p "$NODENOOK_CONFIG"
sudo mkdir -p "$NODENOOK_DIR/bin"
sudo mkdir -p "$NODENOOK_DIR/logs"
sudo chown -R $USER:$USER "$NODENOOK_DIR"

# Save local node info
NODE_IP=$(hostname -I | awk '{print $1}')
cat > "$NODENOOK_CONFIG/node.env" << EOF
# NodeNook Node Configuration
# Generated: $(date)

NODE_HOSTNAME=$NEW_HOSTNAME
NODE_IP=$NODE_IP
NODE_ROLE=manager
EOF

chmod 600 "$NODENOOK_CONFIG/node.env"
success "Node configuration saved to $NODENOOK_CONFIG/node.env"

# ============================================================
# Step 5b: Setup cluster.env (fetch from manager or create)
# ============================================================
log "Setting up cluster configuration..."

# Try to fetch existing cluster.env from manager
CLUSTER_ENV_FETCHED=false
if [ -n "$MANAGER_IP" ]; then
    EXISTING_CLUSTER_ENV=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        "$USER@$MANAGER_IP" "cat $NODENOOK_CONFIG/cluster.env 2>/dev/null" 2>/dev/null || true)

    if [ -n "$EXISTING_CLUSTER_ENV" ]; then
        echo "$EXISTING_CLUSTER_ENV" > "$NODENOOK_CONFIG/cluster.env"
        CLUSTER_ENV_FETCHED=true
        log "Fetched cluster configuration from manager"
    fi
fi

# Create or update cluster.env
if [ "$CLUSTER_ENV_FETCHED" = true ]; then
    # Add this node to CLUSTER_HOSTNAMES if not already present
    source "$NODENOOK_CONFIG/cluster.env"
    if ! echo "$CLUSTER_HOSTNAMES" | grep -qw "$NEW_HOSTNAME"; then
        CLUSTER_HOSTNAMES="$CLUSTER_HOSTNAMES $NEW_HOSTNAME"
        sed -i "s/^CLUSTER_HOSTNAMES=.*/CLUSTER_HOSTNAMES=\"$CLUSTER_HOSTNAMES\"/" "$NODENOOK_CONFIG/cluster.env"
        log "Added $NEW_HOSTNAME to cluster hostnames"
    fi
else
    # Create new cluster.env (this is first node or couldn't fetch)
    cat > "$NODENOOK_CONFIG/cluster.env" << EOF
# NodeNook Cluster Configuration
# All node hostnames (whitelist for auto-recovery)
# Generated: $(date)

CLUSTER_HOSTNAMES="$NEW_HOSTNAME"
CLUSTER_USER="$USER"
EOF
    log "Created new cluster configuration"
fi

chmod 600 "$NODENOOK_CONFIG/cluster.env"

# ============================================================
# Step 5c: Install Auto-Recovery Script
# ============================================================
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

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Load cluster configuration
if [ ! -f "$CONFIG_DIR/cluster.env" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: cluster.env not found" >> "$LOG"
    exit 1
fi
source "$CONFIG_DIR/cluster.env"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG" >&2
}

# Get current hostname
MY_HOSTNAME=$(hostname)

# Discover online nodes via mDNS + SSH verification (security: only trust SSH-accessible nodes)
discover_online_nodes() {
    local online=""
    for host in $CLUSTER_HOSTNAMES; do
        # Try to resolve via mDNS
        local ip=""
        ip=$(avahi-resolve -n "${host}.local" 2>/dev/null | awk '{print $2}')

        # Fallback to regular DNS if mDNS fails
        if [ -z "$ip" ]; then
            ip=$(getent hosts "${host}.local" 2>/dev/null | awk '{print $1}')
        fi
        if [ -z "$ip" ]; then
            ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1}')
        fi

        [ -z "$ip" ] && continue

        # Verify SSH access (security: proves it's a real cluster node with our keys)
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            "$CLUSTER_USER@${host}.local" "true" 2>/dev/null; then
            online="$online $host"
        elif ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            "$CLUSTER_USER@$ip" "true" 2>/dev/null; then
            online="$online $host"
        fi
    done
    # Sort alphabetically and return
    echo $online | tr ' ' '\n' | sort | tr '\n' ' ' | xargs
}

# Am I the recovery leader? (lowest alphabetical hostname among online nodes)
am_i_leader() {
    local online_sorted="$1"
    local first=$(echo $online_sorted | awk '{print $1}')
    [ "$first" = "$MY_HOSTNAME" ]
}

# Try to rejoin an existing healthy swarm
try_rejoin() {
    for host in $CLUSTER_HOSTNAMES; do
        [ "$host" = "$MY_HOSTNAME" ] && continue

        # Resolve hostname
        local ip=""
        ip=$(avahi-resolve -n "${host}.local" 2>/dev/null | awk '{print $2}')
        if [ -z "$ip" ]; then
            ip=$(getent hosts "${host}.local" 2>/dev/null | awk '{print $1}')
        fi
        [ -z "$ip" ] && continue

        # Try to get fresh token via SSH (secure: encrypted channel)
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

# Cache tokens for quick recovery (stored securely with restricted permissions)
cache_tokens() {
    docker swarm join-token manager -q > "$CONFIG_DIR/manager.token" 2>/dev/null || true
    docker swarm join-token worker -q > "$CONFIG_DIR/worker.token" 2>/dev/null || true
    chmod 600 "$CONFIG_DIR"/*.token 2>/dev/null || true
}

# Main recovery logic
main() {
    log "=========================================="
    log "NodeNook Auto-Recovery Starting"
    log "Hostname: $MY_HOSTNAME"
    log "Cluster nodes: $CLUSTER_HOSTNAMES"
    log "=========================================="

    # Check if swarm is already healthy
    if docker node ls &>/dev/null 2>&1; then
        log "Swarm is healthy, caching tokens and exiting"
        cache_tokens
        exit 0
    fi

    log "Swarm is unhealthy or not active, starting recovery..."

    # Wait for network to fully initialize
    log "Waiting for network..."
    sleep 10

    # Discovery phase - find all online nodes
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

    # Try to rejoin first (maybe another node already recovered the cluster)
    log "Attempting to rejoin existing cluster..."
    if try_rejoin; then
        cache_tokens
        exit 0
    fi

    # Leader election based on alphabetical hostname order
    if am_i_leader "$online"; then
        log "I am recovery leader (lowest hostname among online nodes)"
        log "Waiting 90s to allow other nodes to come online..."
        sleep 90

        # Rediscover after waiting
        online=$(discover_online_nodes)
        log "After wait - Online nodes: $online"

        # Try rejoin again (maybe cluster recovered while we waited)
        if try_rejoin; then
            cache_tokens
            exit 0
        fi

        # Force new cluster as last resort
        log "All recovery attempts failed. Forcing new cluster..."
        docker swarm leave --force 2>/dev/null || true
        sleep 2

        local my_ip=$(hostname -I | awk '{print $1}')
        if docker swarm init --advertise-addr "$my_ip"; then
            log "New cluster created with advertise address: $my_ip"
            cache_tokens

            # Notify other nodes to retry recovery
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

        # Retry loop - wait for leader to create cluster, then join
        for i in $(seq 1 12); do
            sleep 30
            log "Retry $i/12 - attempting to rejoin..."
            if try_rejoin; then
                cache_tokens
                log "Successfully rejoined on retry $i"
                exit 0
            fi
        done

        log_error "Max retries exceeded, recovery failed. Manual intervention needed."
        exit 1
    fi
}

main "$@"
RECOVERY_SCRIPT

sudo chmod 700 "$NODENOOK_DIR/bin/swarm-recovery.sh"
sudo chown root:root "$NODENOOK_DIR/bin/swarm-recovery.sh"
success "Auto-recovery script installed"

# ============================================================
# Step 5d: Install Systemd Service
# ============================================================
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
success "Auto-recovery service enabled (will run on boot)"

# ============================================================
# Step 6: Set up SSH access
# ============================================================
header "Step 6: SSH Access"

# Ensure SSH server is installed
if ! command -v sshd &> /dev/null && ! systemctl is-active --quiet ssh 2>/dev/null && ! systemctl is-active --quiet sshd 2>/dev/null; then
    log "Installing OpenSSH server..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y openssh-server
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y openssh-server
    elif command -v yum &> /dev/null; then
        sudo yum install -y openssh-server
    else
        warn "Could not install SSH server automatically. Please install it manually."
    fi

    # Enable and start SSH
    sudo systemctl enable ssh 2>/dev/null || sudo systemctl enable sshd 2>/dev/null || true
    sudo systemctl start ssh 2>/dev/null || sudo systemctl start sshd 2>/dev/null || true
    success "SSH server installed and started!"
else
    log "SSH server is already available."
fi

success "SSH keys were added during pairing - dashboard can now connect!"

# ============================================================
# Step 6b: Exchange SSH Host Keys with Cluster Nodes
# ============================================================
log "Setting up SSH host key trust with cluster nodes..."

# Store host keys for known cluster nodes (prevents MITM warnings during recovery)
source "$NODENOOK_CONFIG/cluster.env" 2>/dev/null || true

if [ -n "$CLUSTER_HOSTNAMES" ]; then
    for host in $CLUSTER_HOSTNAMES; do
        [ "$host" = "$NEW_HOSTNAME" ] && continue
        ssh-keyscan -H "${host}.local" >> ~/.ssh/known_hosts 2>/dev/null || true
        if [ -n "$MANAGER_IP" ]; then
            ssh-keyscan -H "$MANAGER_IP" >> ~/.ssh/known_hosts 2>/dev/null || true
        fi
    done
    log "Added known cluster host keys"
fi

# ============================================================
# Step 6c: Sync Cluster Config to Other Nodes
# ============================================================
log "Syncing cluster configuration to other nodes..."

source "$NODENOOK_CONFIG/cluster.env" 2>/dev/null || true

SYNC_COUNT=0
for host in $CLUSTER_HOSTNAMES; do
    [ "$host" = "$NEW_HOSTNAME" ] && continue
    if scp -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        "$NODENOOK_CONFIG/cluster.env" "$USER@${host}.local:$NODENOOK_CONFIG/cluster.env" 2>/dev/null; then
        log "  Synced to $host"
        SYNC_COUNT=$((SYNC_COUNT + 1))
    fi
done

if [ $SYNC_COUNT -gt 0 ]; then
    success "Cluster config synced to $SYNC_COUNT node(s)"
fi

# ============================================================
# Step 7: Configure Shelf Mode (no sleep)
# ============================================================
header "Step 7: Shelf Mode"

log "Configuring system to never sleep (shelf mode)..."

# Disable sleep and suspend targets
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# Configure logind to ignore lid close and idle
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/shelf-mode.conf > /dev/null << SHELFCONF
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
SHELFCONF

# Restart logind to apply
sudo systemctl restart systemd-logind

success "Shelf mode configured!"
echo "  - System will never sleep or suspend"
echo "  - Lid close is ignored"
echo "  - Screen will dim but system stays awake"

# ============================================================
# Step 8: Verify
# ============================================================
header "Step 8: Verification"

log "Checking swarm nodes..."
docker node ls

echo ""
log "Checking services running on this node..."
docker ps

echo ""
log "This node's info:"
docker node inspect self --format '{{.Description.Hostname}} - {{.Status.State}} - {{.Spec.Role}}'

# ============================================================
# Complete!
# ============================================================
header "Setup Complete!"

success "This node has joined the NodeNook cluster!"
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  Node Information                                          │"
echo "├─────────────────────────────────────────────────────────────┤"
echo "│                                                             │"
echo "│  Hostname:     $NEW_HOSTNAME"
echo "│  IP:           $NODE_IP"
echo "│  mDNS:         ${NEW_HOSTNAME}.local"
echo "│  Role:         Manager"
echo "│                                                             │"
echo "│  Config:       $NODENOOK_CONFIG/"
echo "│  Recovery:     $NODENOOK_DIR/bin/swarm-recovery.sh"
echo "│  Logs:         $NODENOOK_DIR/logs/recovery.log"
echo "│                                                             │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
echo "Features enabled:"
echo "  ✓ Shelf mode (never sleeps, lid close ignored)"
echo "  ✓ mDNS discovery (reachable as ${NEW_HOSTNAME}.local)"
echo "  ✓ Auto-recovery (self-healing after reboot/IP change)"
echo ""
echo "Auto-Recovery:"
echo "  The cluster will automatically heal after reboots or IP changes."
echo "  Nodes discover each other via mDNS and the lowest alphabetical"
echo "  hostname becomes the recovery leader if needed."
echo ""
echo "  View logs:        cat $NODENOOK_DIR/logs/recovery.log"
echo "  Manual recovery:  sudo systemctl restart nodenook-recovery"
echo ""
echo "Useful commands:"
echo "  docker node ls                      # List all swarm nodes"
echo "  ping ${NEW_HOSTNAME}.local          # Test mDNS"
echo "  systemctl status nodenook-recovery  # Check recovery service"
echo ""
