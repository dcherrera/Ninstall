#!/bin/bash
#
# NodeNook Pairing Script
# Run this on an existing swarm manager to generate a short pairing code
# for new machines to join.
#
# Usage: ./pair.sh
#

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[NodeNook]${NC} $1"; }
success() { echo -e "${GREEN}[NodeNook]${NC} $1"; }

# Generate a short 6-character code
CODE=$(cat /dev/urandom | tr -dc 'A-Z0-9' | fold -w 6 | head -n 1)

# Get manager token and IP
MANAGER_TOKEN=$(docker swarm join-token manager -q 2>/dev/null)
MANAGER_IP=$(hostname -I | awk '{print $1}')

if [ -z "$MANAGER_TOKEN" ]; then
    echo "Error: This machine is not a swarm manager."
    exit 1
fi

# Create temp directory for pairing
PAIR_DIR="/tmp/nodenook-pair"
mkdir -p "$PAIR_DIR"

# Write pairing info
cat > "$PAIR_DIR/index.html" << EOF
$MANAGER_TOKEN
EOF

# Store the code for validation
echo "$CODE" > "$PAIR_DIR/code"

# Start simple HTTP server
PORT=9876

log "Starting pairing server..."

# Kill any existing pairing server
pkill -f "python3 -m http.server $PORT" 2>/dev/null || true
sleep 1

# Start server in background
cd "$PAIR_DIR"
python3 -m http.server $PORT --bind 0.0.0.0 &>/dev/null &
SERVER_PID=$!

# Give it a moment to start
sleep 1

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  NodeNook Pairing${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  On the new machine, run:"
echo ""
echo -e "    ${GREEN}curl -sSL https://raw.githubusercontent.com/dcherrera/Ninstall/main/setup.sh | bash${NC}"
echo ""
echo -e "  Then enter:"
echo ""
echo -e "    Manager IP:  ${YELLOW}$MANAGER_IP${NC}"
echo -e "    Pairing Code: ${YELLOW}$CODE${NC}"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Press Ctrl+C when done pairing."
echo ""

# Wait for Ctrl+C
trap "kill $SERVER_PID 2>/dev/null; rm -rf $PAIR_DIR; echo ''; log 'Pairing server stopped.'" EXIT
wait $SERVER_PID
