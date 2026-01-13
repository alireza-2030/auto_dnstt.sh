#!/bin/bash

# Hardcoded values for Automatic Installation
NS_SUBDOMAIN="n.frostcomic.com"
TUNNEL_MODE="ssh" # options: socks, ssh
MTU_VALUE="1232"

set -e

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root"
    exit 1
fi

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration variables
DNSTT_BASE_URL="https://dnstt.network"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/dnstt"
SYSTEMD_DIR="/etc/systemd/system"
DNSTT_PORT="5300"
DNSTT_USER="dnstt"
CONFIG_FILE="${CONFIG_DIR}/dnstt-server.conf"

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }

# 1. Detect OS and Architecture
detect_os_arch() {
    . /etc/os-release
    PKG_MANAGER=$(command -v apt >/dev/null && echo "apt" || echo "dnf")
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    print_status "OS: $NAME, Arch: $ARCH, Manager: $PKG_MANAGER"
}

# 2. Install Dependencies
install_deps() {
    print_status "Installing dependencies..."
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt update && apt install -y curl iptables iptables-persistent
    else
        dnf install -y curl iptables iptables-services
    fi
}

# 3. Setup User and Dirs
setup_env() {
    id "$DNSTT_USER" &>/dev/null || useradd -r -s /bin/false "$DNSTT_USER"
    mkdir -p "$CONFIG_DIR"
    chown "$DNSTT_USER":"$DNSTT_USER" "$CONFIG_DIR"
}

# 4. Download Binary
download_server() {
    print_status "Downloading dnstt-server..."
    curl -L -o "${INSTALL_DIR}/dnstt-server" "${DNSTT_BASE_URL}/dnstt-server-linux-${ARCH}"
    chmod +x "${INSTALL_DIR}/dnstt-server"
}

# 5. Keys Management
generate_keys() {
    key_prefix=$(echo "$NS_SUBDOMAIN" | sed 's/\./_/g')
    PRIVATE_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.key"
    PUBLIC_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.pub"
    
    if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
        print_status "Generating new keys..."
        dnstt-server -gen-key -privkey-file "$PRIVATE_KEY_FILE" -pubkey-file "$PUBLIC_KEY_FILE"
    fi
    chown "$DNSTT_USER":"$DNSTT_USER" "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
}

# 6. Firewall Configuration
setup_firewall() {
    print_status "Configuring Iptables..."
    interface=$(ip route | grep default | awk '{print $5}' | head -1)
    iptables -I INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT
    iptables -t nat -I PREROUTING -i "$interface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT"
    
    # Save rules
    if [ "$PKG_MANAGER" == "apt" ]; then
        iptables-save > /etc/iptables/rules.v4
    else
        iptables-save > /etc/sysconfig/iptables
    fi
}

# 7. Systemd Service
setup_service() {
    print_status "Creating Systemd Service..."
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | cut -d':' -f2 | head -1 || echo "22")
    
    cat > "${SYSTEMD_DIR}/dnstt-server.service" << EOF
[Unit]
Description=dnstt DNS Tunnel
After=network.target

[Service]
ExecStart=${INSTALL_DIR}/dnstt-server -udp :${DNSTT_PORT} -privkey-file ${PRIVATE_KEY_FILE} -mtu ${MTU_VALUE} ${NS_SUBDOMAIN} 127.0.0.1:${ssh_port}
Restart=always
User=$DNSTT_USER

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable dnstt-server
    systemctl restart dnstt-server
}

# Main Execution
detect_os_arch
install_deps
setup_env
download_server
generate_keys
setup_firewall
setup_service

echo -e "\n${BLUE}==================================================${NC}"
echo -e "${GREEN}نصب با موفقیت تمام شد!${NC}"
echo -e "Public Key شما:"
cat "$PUBLIC_KEY_FILE"
echo -e "\n${BLUE}==================================================${NC}"
