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
echo "  2. Set the hostname"
echo "  3. Join the Docker Swarm as a manager"
echo "  4. Set up SSH access for the dashboard"
echo "  5. Configure shelf mode (no sleep, lid close ignored)"
echo ""
echo "You'll need:"
echo "  - The IP address of an existing swarm manager"
echo "  - The manager join token (from bootstrap.sh output)"
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
    # Re-run script with docker group (handle both file and curl|bash cases)
    SCRIPT_URL="https://raw.githubusercontent.com/dcherrera/Ninstall/main/setup.sh"
    if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "-bash" ]; then
        exec sg docker -c "$0 $*"
    else
        exec sg docker -c "curl -sSL $SCRIPT_URL | bash"
    fi
fi

# Enable Docker on boot
sudo systemctl enable docker 2>/dev/null || true

# Verify Docker works
if ! docker info &> /dev/null; then
    error "Docker is not running. Please start Docker and try again."
fi

success "Docker is ready!"

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
        echo "Make sure you ran ./pair.sh on the manager first."
        echo ""
        echo "Or enter the full token manually:"
        read -p "Manager join token: " MANAGER_TOKEN </dev/tty
        if [ -z "$MANAGER_TOKEN" ]; then
            error "Manager token is required."
        fi
    fi

    echo ""
    log "Joining swarm as a manager..."
    docker swarm join --token "$MANAGER_TOKEN" "$MANAGER_IP:2377"
    success "Joined swarm!"
fi

# ============================================================
# Step 5: Create NodeNook directories
# ============================================================
header "Step 5: Configuration"

log "Creating NodeNook directories..."
sudo mkdir -p "$NODENOOK_CONFIG"
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

# Set up authorized_keys if not already present
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

success "SSH is ready for dashboard access."
echo ""
echo "To enable passwordless access from your Mac, add your SSH public key:"
echo "  ssh-copy-id $USER@$NODE_IP"
echo ""
echo "Or copy the key from the first node:"
echo "  # On the first node:"
echo "  cat /opt/nodenook/config/dashboard_key.pub"
echo "  # Then add that to this node's ~/.ssh/authorized_keys"

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

success "This node has joined the NodeNook cluster (shelf mode enabled)!"
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  Node Information                                          │"
echo "├─────────────────────────────────────────────────────────────┤"
echo "│                                                             │"
echo "│  Hostname: $NEW_HOSTNAME"
echo "│  IP:       $NODE_IP"
echo "│  Role:     Manager"
echo "│                                                             │"
echo "│  Config:   $NODENOOK_CONFIG/node.env                       │"
echo "│                                                             │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
echo "The node-exporter service should automatically start on this node"
echo "(it runs in 'global' mode on all swarm nodes)."
echo ""
echo "Check with: docker service ps node-exporter"
echo ""
echo "Next steps:"
echo "  1. Set up SSH key access (see Step 6 above)"
echo "  2. Add more nodes by running setup.sh on them"
echo "  3. Verify in the NodeNook dashboard"
echo ""
echo "To see all nodes: docker node ls"
echo ""
