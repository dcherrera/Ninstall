#!/bin/bash
#
# NodeNook Bootstrap Script
# Run this on your FIRST machine to initialize the swarm
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/dcherrera/Ninstall/main/bootstrap.sh | bash
#   # or
#   ./bootstrap.sh
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
NODENOOK_DATA="$NODENOOK_DIR/data"

header "NodeNook Bootstrap"
echo "This script will set up the first node of your NodeNook cluster."
echo ""
echo "It will:"
echo "  1. Install Docker (if not present)"
echo "  2. Set the hostname"
echo "  3. Initialize the Docker Swarm"
echo "  4. Deploy Traefik (reverse proxy)"
echo "  5. Deploy monitoring (Prometheus + Node Exporter)"
echo "  6. Save configuration for the dashboard"
echo ""
read -p "Press Enter to continue (or Ctrl+C to cancel)..."

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
    warn "You'll need to log out and back in for group changes to take effect."
    warn "After logging back in, run this script again."
    exit 0
fi

# Enable Docker on boot
sudo systemctl enable docker 2>/dev/null || true

# Verify Docker works
if ! docker info &> /dev/null; then
    error "Docker is not running. Please start Docker and try again."
fi

success "Docker is ready!"

# ============================================================
# Step 2: Set Hostname
# ============================================================
header "Step 2: Hostname"

CURRENT_HOSTNAME=$(hostname)
log "Current hostname: $CURRENT_HOSTNAME"
echo ""
read -p "Enter hostname for this node [node-1]: " NEW_HOSTNAME
NEW_HOSTNAME=${NEW_HOSTNAME:-node-1}

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
# Step 3: Initialize Swarm
# ============================================================
header "Step 3: Docker Swarm"

if docker info 2>/dev/null | grep -q "Swarm: active"; then
    warn "This machine is already part of a swarm."
    if docker info 2>/dev/null | grep -q "Is Manager: true"; then
        log "This node is a swarm manager."
    fi
else
    # Get the default IP address
    DEFAULT_IP=$(hostname -I | awk '{print $1}')
    log "Detected IP address: $DEFAULT_IP"
    read -p "Use this IP for swarm? [Y/n]: " USE_DEFAULT_IP
    USE_DEFAULT_IP=${USE_DEFAULT_IP:-Y}

    if [[ $USE_DEFAULT_IP =~ ^[Yy]$ ]]; then
        SWARM_IP=$DEFAULT_IP
    else
        read -p "Enter IP address for swarm: " SWARM_IP
    fi

    log "Initializing Docker Swarm..."
    docker swarm init --advertise-addr "$SWARM_IP"
    success "Swarm initialized!"
fi

# Get and save join tokens
MANAGER_TOKEN=$(docker swarm join-token manager -q)
WORKER_TOKEN=$(docker swarm join-token worker -q)
SWARM_IP=$(docker info --format '{{.Swarm.NodeAddr}}')

# ============================================================
# Step 4: Create NodeNook directories and configs
# ============================================================
header "Step 4: Configuration"

log "Creating NodeNook directories..."
sudo mkdir -p "$NODENOOK_CONFIG"
sudo mkdir -p "$NODENOOK_DATA/traefik"
sudo mkdir -p "$NODENOOK_DATA/prometheus"
sudo chown -R $USER:$USER "$NODENOOK_DIR"

# Save swarm info
cat > "$NODENOOK_CONFIG/swarm.env" << EOF
# NodeNook Swarm Configuration
# Generated: $(date)

SWARM_MANAGER_IP=$SWARM_IP
SWARM_MANAGER_TOKEN=$MANAGER_TOKEN
SWARM_WORKER_TOKEN=$WORKER_TOKEN
EOF

chmod 600 "$NODENOOK_CONFIG/swarm.env"
success "Swarm configuration saved to $NODENOOK_CONFIG/swarm.env"

# Create Traefik config
cat > "$NODENOOK_CONFIG/traefik.yml" << 'EOF'
api:
  dashboard: true
  insecure: true

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    swarmMode: true
    exposedByDefault: false
    network: nodenook-public

log:
  level: INFO
EOF

success "Traefik configuration created."

# Create Prometheus config
cat > "$NODENOOK_CONFIG/prometheus.yml" << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # Prometheus itself
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Node Exporter - discovers all nodes via DNS
  - job_name: 'node-exporter'
    dns_sd_configs:
      - names:
          - 'tasks.node-exporter'
        type: 'A'
        port: 9100

  # Docker daemon metrics (if enabled)
  - job_name: 'docker'
    dns_sd_configs:
      - names:
          - 'tasks.node-exporter'
        type: 'A'
        port: 9323
EOF

success "Prometheus configuration created."

# ============================================================
# Step 5: Create Docker networks
# ============================================================
header "Step 5: Networks"

if ! docker network ls | grep -q nodenook-public; then
    log "Creating nodenook-public overlay network..."
    docker network create --driver overlay --attachable nodenook-public
    success "Network created!"
else
    log "nodenook-public network already exists."
fi

# ============================================================
# Step 6: Deploy Traefik
# ============================================================
header "Step 6: Traefik (Reverse Proxy)"

log "Deploying Traefik..."

docker service rm traefik 2>/dev/null || true

docker service create \
    --name traefik \
    --constraint 'node.role == manager' \
    --publish published=80,target=80,mode=host \
    --publish published=443,target=443,mode=host \
    --publish published=8080,target=8080 \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly \
    --mount type=bind,source=$NODENOOK_CONFIG/traefik.yml,target=/etc/traefik/traefik.yml,readonly \
    --network nodenook-public \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.traefik.rule=Host(\`traefik.nodenook.local\`)" \
    --label "traefik.http.routers.traefik.service=api@internal" \
    --label "traefik.http.services.traefik.loadbalancer.server.port=8080" \
    traefik:v3.0

success "Traefik deployed!"
log "Dashboard will be available at: http://traefik.nodenook.local"
log "(Once you configure DNS - see below)"

# ============================================================
# Step 7: Deploy Monitoring
# ============================================================
header "Step 7: Monitoring"

log "Deploying Node Exporter (global - runs on all nodes)..."

docker service rm node-exporter 2>/dev/null || true

docker service create \
    --name node-exporter \
    --mode global \
    --network nodenook-public \
    --mount type=bind,source=/proc,target=/host/proc,readonly \
    --mount type=bind,source=/sys,target=/host/sys,readonly \
    --mount type=bind,source=/,target=/rootfs,readonly \
    prom/node-exporter:latest \
    --path.procfs=/host/proc \
    --path.sysfs=/host/sys \
    --path.rootfs=/rootfs \
    --collector.filesystem.mount-points-exclude="^/(sys|proc|dev|host|etc)($$|/)"

success "Node Exporter deployed!"

log "Deploying Prometheus..."

docker service rm prometheus 2>/dev/null || true

docker service create \
    --name prometheus \
    --constraint 'node.role == manager' \
    --network nodenook-public \
    --mount type=bind,source=$NODENOOK_CONFIG/prometheus.yml,target=/etc/prometheus/prometheus.yml,readonly \
    --mount type=volume,source=prometheus-data,target=/prometheus \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.prometheus.rule=Host(\`prometheus.nodenook.local\`)" \
    --label "traefik.http.services.prometheus.loadbalancer.server.port=9090" \
    prom/prometheus:latest

success "Prometheus deployed!"
log "Dashboard will be available at: http://prometheus.nodenook.local"

# ============================================================
# Step 8: Generate SSH key for dashboard
# ============================================================
header "Step 8: SSH Key for Dashboard"

SSH_KEY_PATH="$NODENOOK_CONFIG/dashboard_key"

if [ ! -f "$SSH_KEY_PATH" ]; then
    log "Generating SSH key pair for dashboard access..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "nodenook-dashboard"

    # Add to authorized_keys
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    cat "${SSH_KEY_PATH}.pub" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

    success "SSH key generated and added to authorized_keys"
else
    log "SSH key already exists."
fi

# ============================================================
# Step 9: Verify deployment
# ============================================================
header "Step 9: Verification"

log "Checking swarm nodes..."
docker node ls

echo ""
log "Checking services..."
docker service ls

echo ""
log "Waiting for services to start..."
sleep 5

# Check service status
TRAEFIK_STATUS=$(docker service ps traefik --format "{{.CurrentState}}" 2>/dev/null | head -1)
PROMETHEUS_STATUS=$(docker service ps prometheus --format "{{.CurrentState}}" 2>/dev/null | head -1)
NODE_EXPORTER_STATUS=$(docker service ps node-exporter --format "{{.CurrentState}}" 2>/dev/null | head -1)

echo ""
log "Service status:"
echo "  Traefik:       $TRAEFIK_STATUS"
echo "  Prometheus:    $PROMETHEUS_STATUS"
echo "  Node Exporter: $NODE_EXPORTER_STATUS"

# ============================================================
# Complete!
# ============================================================
header "Bootstrap Complete!"

success "Your NodeNook cluster is ready!"
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  IMPORTANT: Save this information!                         │"
echo "├─────────────────────────────────────────────────────────────┤"
echo "│                                                             │"
echo "│  Swarm Manager IP: $SWARM_IP"
echo "│                                                             │"
echo "│  Manager Join Token (for adding nodes as managers):        │"
echo "│  $MANAGER_TOKEN"
echo "│                                                             │"
echo "│  Config saved to: $NODENOOK_CONFIG/swarm.env               │"
echo "│  SSH private key: $SSH_KEY_PATH                            │"
echo "│                                                             │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
echo "Next steps:"
echo ""
echo "  1. Configure DNS for *.nodenook.local"
echo "     Option A: Add to your router's DNS"
echo "     Option B: Add to /etc/hosts on your Mac:"
echo "        echo '$SWARM_IP traefik.nodenook.local prometheus.nodenook.local' | sudo tee -a /etc/hosts"
echo ""
echo "  2. Test the dashboards:"
echo "     - Traefik:    http://traefik.nodenook.local (or http://$SWARM_IP:8080)"
echo "     - Prometheus: http://prometheus.nodenook.local (or http://$SWARM_IP:9090)"
echo ""
echo "  3. Copy the SSH private key to your Mac for the dashboard:"
echo "     scp $USER@$SWARM_IP:$SSH_KEY_PATH ~/.ssh/nodenook_key"
echo ""
echo "  4. Add more nodes by running setup.sh on them"
echo "     (Once we build the dashboard, you'll use pairing codes)"
echo "     For now, on other machines run:"
echo "       docker swarm join --token $MANAGER_TOKEN $SWARM_IP:2377"
echo ""
