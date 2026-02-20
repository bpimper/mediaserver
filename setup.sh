#!/usr/bin/env bash
# =============================================================================
# Homelab Setup Script
# =============================================================================
# This script handles the full initial setup:
#   1. Generates the .env file interactively
#   2. Creates the directory structure
#   3. Generates self-signed TLS certificates (Root CA + wildcard)
#   4. Creates a TinyAuth user (pulls image, uses CLI)
#   5. Optionally installs Tailscale as a subnet router
#
# Usage:
#   chmod +x setup.sh
#   sudo bash setup.sh
#
# Re-running is safe — existing certs and configs are skipped.
# =============================================================================

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

print_step() {
    echo ""
    echo -e "${GREEN}▶ Step $1: $2${NC}"
}

print_info() {
    echo -e "  ${CYAN}ℹ${NC}  $1"
}

print_warn() {
    echo -e "  ${YELLOW}⚠${NC}  $1"
}

print_error() {
    echo -e "  ${RED}✗${NC}  $1" >&2
}

print_ok() {
    echo -e "  ${GREEN}✓${NC}  $1"
}

prompt() {
    echo -e -n "  ${YELLOW}?${NC}  $1: "
}

prompt_default() {
    echo -e -n "  ${YELLOW}?${NC}  $1 [${CYAN}$2${NC}]: "
}

read_with_default() {
    local input
    read -r input
    input=$(echo "$input" | xargs)
    if [[ -z "$input" ]]; then
        echo "$1"
    else
        echo "$input"
    fi
}

# ─── Root check ──────────────────────────────────────────────────────────────
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        print_error "This script must be run as root (or via sudo)."
        echo ""
        echo "  Run:  sudo bash setup.sh"
        exit 1
    fi
}

# ─── Docker check ────────────────────────────────────────────────────────────
check_docker() {
    if ! command -v docker &>/dev/null; then
        print_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
}

# =============================================================================
# PHASE 1: INTERACTIVE .ENV GENERATION
# =============================================================================

generate_env() {
    print_header "Environment Configuration"
    print_info "Configure your .env file. Press Enter to accept defaults."
    echo ""

    # ── General ──
    echo -e "  ${BOLD}General${NC}"
    prompt_default "Project name" "homelab"
    COMPOSE_PROJECT_NAME=$(read_with_default "homelab")

    prompt_default "Timezone (e.g. Europe/London)" "Europe/Budapest"
    TZ=$(read_with_default "Europe/Budapest")

    prompt_default "PUID (run 'id -u' to check)" "1000"
    PUID=$(read_with_default "1000")

    prompt_default "PGID (run 'id -g' to check)" "1000"
    PGID=$(read_with_default "1000")

    prompt "Domain (e.g. home.local, lab.lan)"
    read -r DOMAIN
    DOMAIN=$(echo "$DOMAIN" | xargs)
    if [[ -z "$DOMAIN" ]]; then
        print_error "Domain is required."
        exit 1
    fi

    echo ""

    # ── Paths ──
    echo -e "  ${BOLD}Storage Paths${NC}"
    print_info "These are the root directories for Docker data and media files."

    prompt "Docker root path (e.g. /mnt/storage/docker)"
    read -r DOCKER_ROOT
    DOCKER_ROOT=$(echo "$DOCKER_ROOT" | xargs)
    if [[ -z "$DOCKER_ROOT" ]]; then
        print_error "Docker root path is required."
        exit 1
    fi

    prompt "Media root path (e.g. /mnt/storage/media)"
    read -r MEDIA_ROOT
    MEDIA_ROOT=$(echo "$MEDIA_ROOT" | xargs)
    if [[ -z "$MEDIA_ROOT" ]]; then
        print_error "Media root path is required."
        exit 1
    fi

    echo ""

    # ── Homepage Weather ──
    echo -e "  ${BOLD}Homepage Weather Widget${NC}"
    print_info "Get your coordinates from: https://open-meteo.com/en/docs"

    prompt "City name for weather label (e.g. London)"
    read -r HOMEPAGE_VAR_WEATHER_LABEL
    HOMEPAGE_VAR_WEATHER_LABEL=$(echo "$HOMEPAGE_VAR_WEATHER_LABEL" | xargs)

    prompt "Latitude (e.g. 51.5074)"
    read -r HOMEPAGE_VAR_WEATHER_LATITUDE
    HOMEPAGE_VAR_WEATHER_LATITUDE=$(echo "$HOMEPAGE_VAR_WEATHER_LATITUDE" | xargs)

    prompt "Longitude (e.g. -0.1278)"
    read -r HOMEPAGE_VAR_WEATHER_LONGITUDE
    HOMEPAGE_VAR_WEATHER_LONGITUDE=$(echo "$HOMEPAGE_VAR_WEATHER_LONGITUDE" | xargs)

    prompt_default "Locale (e.g. en, hu, de)" "en"
    HOMEPAGE_VAR_LOCALE=$(read_with_default "en")

    prompt_default "Units (metric / imperial)" "metric"
    HOMEPAGE_VAR_UNITS=$(read_with_default "metric")

    echo ""

    # ── Summary ──
    echo -e "  ${BOLD}Configuration Summary${NC}"
    echo -e "    Project:      ${CYAN}${COMPOSE_PROJECT_NAME}${NC}"
    echo -e "    Timezone:     ${CYAN}${TZ}${NC}"
    echo -e "    UID/GID:      ${CYAN}${PUID}:${PGID}${NC}"
    echo -e "    Domain:       ${CYAN}${DOMAIN}${NC}"
    echo -e "    Docker root:  ${CYAN}${DOCKER_ROOT}${NC}"
    echo -e "    Media root:   ${CYAN}${MEDIA_ROOT}${NC}"
    echo -e "    Weather:      ${CYAN}${HOMEPAGE_VAR_WEATHER_LABEL} (${HOMEPAGE_VAR_WEATHER_LATITUDE}, ${HOMEPAGE_VAR_WEATHER_LONGITUDE})${NC}"
    echo -e "    Locale/Units: ${CYAN}${HOMEPAGE_VAR_LOCALE} / ${HOMEPAGE_VAR_UNITS}${NC}"
    echo ""

    prompt "Does this look correct? (yes/no)"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy](es)?$ ]]; then
        print_info "Aborted. Please re-run the script."
        exit 0
    fi
}

write_env_file() {
    local ENV_FILE="./.env"

    if [[ -f "$ENV_FILE" ]]; then
        print_warn ".env file already exists."
        prompt "Overwrite? (yes/no)"
        read -r overwrite
        if [[ ! "$overwrite" =~ ^[Yy](es)?$ ]]; then
            print_info "Keeping existing .env file."
            # Source existing values for later steps
            set -a
            source "$ENV_FILE"
            set +a
            return
        fi
    fi

    cat > "$ENV_FILE" <<EOF
# ============================================================================
# GENERAL
# ============================================================================
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
TZ=${TZ}
PUID=${PUID}
PGID=${PGID}
DOMAIN=${DOMAIN}


# ============================================================================
# NETWORK
# ============================================================================
EDGE_SUBNET=169.254.2.0/28
CORE_SUBNET=169.254.2.16/28


# ============================================================================
# SHARED PATHS
# ============================================================================
DOCKER_ROOT=${DOCKER_ROOT}
MEDIA_ROOT=${MEDIA_ROOT}
APPDATA_DIR=\${DOCKER_ROOT}/appdata
CERTS_DIR=\${DOCKER_ROOT}/certs
CONFIG_DIR=\${DOCKER_ROOT}/config
MOVIES_DIR=\${MEDIA_ROOT}/movies
TV_DIR=\${MEDIA_ROOT}/tv
DOWNLOADS_DIR=\${MEDIA_ROOT}/downloads


# ============================================================================
# EXTERNAL
# ============================================================================
TMDB_API_KEY=


# ============================================================================
# SOCKETPROXY
# ============================================================================
SOCKETPROXY_VERSION=2.1.6


# ============================================================================
# TRAEFIK
# ============================================================================
TRAEFIK_VERSION=3.6.7
TRAEFIK_HTTP_PORT=80
TRAEFIK_HTTPS_PORT=443
TRAEFIK_CPU_LIMIT=1.0
TRAEFIK_MEM_LIMIT=512M


# ============================================================================
# TINYAUTH
# ============================================================================
TINYAUTH_VERSION=4.1.0
TINYAUTH_PORT=8082
TINYAUTH_USERS=
TINYAUTH_CPU_LIMIT=1.0
TINYAUTH_MEM_LIMIT=256M


# ============================================================================
# HOMEPAGE
# ============================================================================
HOMEPAGE_VERSION=v1.10.1
HOMEPAGE_PORT=3000
HOMEPAGE_CPU_LIMIT=0.5
HOMEPAGE_MEM_LIMIT=512M
HOMEPAGE_VAR_LOCALE=${HOMEPAGE_VAR_LOCALE}
HOMEPAGE_VAR_UNITS=${HOMEPAGE_VAR_UNITS}
HOMEPAGE_VAR_WEATHER_LABEL=${HOMEPAGE_VAR_WEATHER_LABEL}
HOMEPAGE_VAR_WEATHER_LATITUDE=${HOMEPAGE_VAR_WEATHER_LATITUDE}
HOMEPAGE_VAR_WEATHER_LONGITUDE=${HOMEPAGE_VAR_WEATHER_LONGITUDE}


# ============================================================================
# BESZEL
# ============================================================================
BESZEL_VERSION=0.18.3
BESZEL_AGENT_VERSION=0.18.3
BESZEL_USERNAME=
BESZEL_PASSWORD=
BESZEL_SYSTEM_ID=
BESZEL_AGENT_TOKEN=
BESZEL_AGENT_KEY=
BESZEL_PORT=8092
BESZEL_CPU_LIMIT=0.5
BESZEL_MEM_LIMIT=512M
BESZEL_AGENT_CPU_LIMIT=0.5
BESZEL_AGENT_MEM_LIMIT=128M


# ============================================================================
# QBITTORRENT
# ============================================================================
QBITTORRENT_VERSION=5.1.4
QBITTORRENT_USERNAME=admin
QBITTORRENT_PASSWORD=
QBITTORRENT_WEBUI_PORT=8090
QBITTORRENT_INFO_PORT=6881
QBITTORRENT_CPU_LIMIT=2.0
QBITTORRENT_MEM_LIMIT=512M


# ============================================================================
# JELLYFIN
# ============================================================================
JELLYFIN_VERSION=10.11.6
JELLYFIN_API_KEY=
JELLYFIN_HTTP_PORT=8096
JELLYFIN_HTTPS_PORT=8920
JELLYFIN_DLNA_PORT=1900
JELLYFIN_DISCOVERY_PORT=7359
JELLYFIN_CPU_LIMIT=4.0
JELLYFIN_MEM_LIMIT=4096M


# ============================================================================
# CINEPHAGE
# ============================================================================
CINEPHAGE_VERSION=latest
CINEPHAGE_PORT=3005
CINEPHAGE_CPU_LIMIT=2.0
CINEPHAGE_MEM_LIMIT=1024M
EOF

    chmod 600 "$ENV_FILE"
    print_ok ".env file created (permissions: 600)"
}

# =============================================================================
# PHASE 2: DIRECTORY STRUCTURE
# =============================================================================

create_directories() {
    print_step "2" "Create Directory Structure"

    local dirs=(
        "${DOCKER_ROOT}/appdata/beszel"
        "${DOCKER_ROOT}/appdata/qbittorrent"
        "${DOCKER_ROOT}/appdata/jellyfin/config"
        "${DOCKER_ROOT}/certs"
        "${DOCKER_ROOT}/config/qbittorrent"
        "${DOCKER_ROOT}/config/cinephage"
        "${MEDIA_ROOT}/movies"
        "${MEDIA_ROOT}/tv"
        "${MEDIA_ROOT}/downloads"
    )

    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            print_info "Already exists: $dir"
        else
            mkdir -p "$dir"
            print_ok "Created: $dir"
        fi
    done

    chown -R "${PUID}:${PGID}" "${DOCKER_ROOT}" "${MEDIA_ROOT}" 2>/dev/null || true
    print_ok "Ownership set to ${PUID}:${PGID}"
}

# =============================================================================
# PHASE 3: SELF-SIGNED CERTIFICATE GENERATION
# =============================================================================

generate_certs() {
    print_step "3" "Generate TLS Certificates"

    local CERTS_DIR="${DOCKER_ROOT}/certs"
    local CA_DIR="${CERTS_DIR}/ca"
    local CERT_DIR="${CERTS_DIR}/${DOMAIN}"

    mkdir -p "$CA_DIR"
    mkdir -p "$CERT_DIR"

    # ── Root CA ──
    if [[ -f "$CA_DIR/rootCA.key" ]]; then
        print_info "Root CA already exists, skipping..."
    else
        print_info "Creating Root CA..."

        openssl genrsa -out "$CA_DIR/rootCA.key" 4096 2>/dev/null

        openssl req -x509 -new -nodes \
            -key "$CA_DIR/rootCA.key" \
            -sha256 -days 3650 \
            -out "$CA_DIR/rootCA.pem" \
            -subj "/C=XX/ST=HomeLab/L=HomeLab/O=HomeLab/OU=IT/CN=HomeLab Root CA" \
            2>/dev/null

        print_ok "Root CA created: ${CA_DIR}/rootCA.pem"
    fi

    # ── Server Certificate ──
    if [[ -f "$CERT_DIR/${DOMAIN}.crt" ]]; then
        print_info "Server certificate already exists, skipping..."
    else
        print_info "Creating server certificate for *.${DOMAIN}..."

        openssl genrsa -out "$CERT_DIR/${DOMAIN}.key" 2048 2>/dev/null

        cat > "$CERT_DIR/${DOMAIN}.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C = XX
ST = HomeLab
L = HomeLab
O = HomeLab
OU = IT
CN = ${DOMAIN}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = *.${DOMAIN}
EOF

        openssl req -new \
            -key "$CERT_DIR/${DOMAIN}.key" \
            -out "$CERT_DIR/${DOMAIN}.csr" \
            -config "$CERT_DIR/${DOMAIN}.cnf" \
            2>/dev/null

        openssl x509 -req \
            -in "$CERT_DIR/${DOMAIN}.csr" \
            -CA "$CA_DIR/rootCA.pem" \
            -CAkey "$CA_DIR/rootCA.key" \
            -CAcreateserial \
            -out "$CERT_DIR/${DOMAIN}.crt" \
            -days 825 \
            -sha256 \
            -extfile "$CERT_DIR/${DOMAIN}.cnf" \
            -extensions v3_req \
            2>/dev/null

        print_ok "Server certificate created: ${CERT_DIR}/${DOMAIN}.crt"
    fi

    # ── Create Traefik certs.yml ──
    local CERTS_YML="${CERTS_DIR}/certs.yml"
    if [[ ! -f "$CERTS_YML" ]]; then
        cat > "$CERTS_YML" <<EOF
tls:
  certificates:
    - certFile: /certs/${DOMAIN}/${DOMAIN}.crt
      keyFile: /certs/${DOMAIN}/${DOMAIN}.key
EOF
        print_ok "Traefik certs.yml created"
    fi

    echo ""
    print_info "Certificate files:"
    echo -e "    CA Certificate:     ${CYAN}${CA_DIR}/rootCA.pem${NC}"
    echo -e "    Server Certificate: ${CYAN}${CERT_DIR}/${DOMAIN}.crt${NC}"
    echo -e "    Server Key:         ${CYAN}${CERT_DIR}/${DOMAIN}.key${NC}"
    echo ""
    print_info "Trust the CA on your devices:"
    echo -e "    Linux:   ${CYAN}sudo cp ${CA_DIR}/rootCA.pem /usr/local/share/ca-certificates/homelab-ca.crt && sudo update-ca-certificates${NC}"
    echo -e "    macOS:   ${CYAN}sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${CA_DIR}/rootCA.pem${NC}"
    echo -e "    Windows: ${CYAN}Import ${CA_DIR}/rootCA.pem into 'Trusted Root Certification Authorities'${NC}"
    echo -e "    Android: ${CYAN}Settings → Security → Install certificates → CA certificate${NC}"
}

# =============================================================================
# PHASE 4: TINYAUTH USER CREATION
# =============================================================================

create_tinyauth_user() {
    print_step "4" "Create TinyAuth User"

    local TINYAUTH_IMAGE="ghcr.io/steveiliop56/tinyauth:v4"

    print_info "Pulling TinyAuth image..."
    if docker pull "$TINYAUTH_IMAGE" > /dev/null 2>&1; then
        print_ok "TinyAuth image pulled."
    else
        print_error "Failed to pull TinyAuth image. Check your internet connection."
        print_warn "You can create a user later with:"
        print_info "  docker run -i -t --rm ${TINYAUTH_IMAGE} user create --interactive"
        return
    fi

    echo ""
    print_info "Creating a TinyAuth user. You will be prompted for credentials."
    print_info "Select 'format for docker' when asked for output format."
    echo ""

    local USER_HASH
    USER_HASH=$(docker run -i -t --rm "$TINYAUTH_IMAGE" user create --interactive 2>&1) || true

    if [[ -z "$USER_HASH" ]]; then
        print_warn "No user hash captured. You can create one manually later."
        print_info "  docker run -i -t --rm ${TINYAUTH_IMAGE} user create --interactive"
        return
    fi

    # Extract the user:hash line (the one containing $ signs from bcrypt)
    local EXTRACTED_HASH
    EXTRACTED_HASH=$(echo "$USER_HASH" | grep -E '^\S+:\$' | tail -1 | xargs) || true

    if [[ -n "$EXTRACTED_HASH" ]]; then
        # Escape $ signs for .env (double them)
        local ESCAPED_HASH
        ESCAPED_HASH=$(echo "$EXTRACTED_HASH" | sed 's/\$/\$\$/g')
        sed -i "s|^TINYAUTH_USERS=.*|TINYAUTH_USERS='${ESCAPED_HASH}'|" ./.env
        print_ok "TinyAuth user written to .env"
    else
        echo ""
        print_warn "Could not auto-extract the user hash from output."
        print_info "Copy the generated user:hash from above and paste it into .env"
        print_info "as TINYAUTH_USERS (remember to double the \$ signs for compose)."
    fi
}

# =============================================================================
# PHASE 5: TAILSCALE (OPTIONAL)
# =============================================================================

# ─── Detection functions ─────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        DISTRO_NAME="${PRETTY_NAME:-Unknown}"
        DISTRO_ID="${ID:-unknown}"
    else
        DISTRO_NAME="Unknown"
        DISTRO_ID="unknown"
    fi
}

detect_kernel() {
    KERNEL_VERSION=$(uname -r)
}

detect_primary_interface() {
    PRIMARY_IFACE=$(ip -o route show default | awk '{print $5}' | head -1)
    if [[ -z "$PRIMARY_IFACE" ]]; then
        print_error "Could not detect a primary network interface."
        return 1
    fi
}

detect_host_ip() {
    HOST_IP=$(ip -4 addr show "$PRIMARY_IFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1)
    if [[ -z "$HOST_IP" ]]; then
        print_error "Could not detect an IPv4 address on interface '$PRIMARY_IFACE'."
        return 1
    fi
}

detect_host_subnet() {
    local CIDR
    CIDR=$(ip -4 addr show "$PRIMARY_IFACE" | grep 'inet ' | awk '{print $2}' | head -1)
    local PREFIX
    PREFIX=$(echo "$CIDR" | cut -d'/' -f2)

    if command -v ipcalc &>/dev/null; then
        HOST_SUBNET=$(ipcalc -s "$CIDR" | grep Network | awk '{print $2}')
    else
        local IP_PARTS=()
        IFS='.' read -ra IP_PARTS <<< "$HOST_IP"
        local MASK=0xFFFFFFFF
        MASK=$(( MASK << (32 - PREFIX) ))
        MASK=$(( MASK & 0xFFFFFFFF ))

        local IP_INT=0
        for octet in "${IP_PARTS[@]}"; do
            IP_INT=$(( (IP_INT << 8) + octet ))
        done

        local NET_INT=$(( IP_INT & MASK ))
        local O1=$(( (NET_INT >> 24) & 0xFF ))
        local O2=$(( (NET_INT >> 16) & 0xFF ))
        local O3=$(( (NET_INT >> 8)  & 0xFF ))
        local O4=$(( NET_INT & 0xFF ))

        HOST_SUBNET="${O1}.${O2}.${O3}.${O4}/${PREFIX}"
    fi
}

detect_ip_forwarding() {
    FWD_V4=$(cat /proc/sys/net/ipv4/ip_forward)
    FWD_V6=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo "0")
}

detect_existing_tailscale() {
    TAILSCALE_INSTALLED=false
    if command -v tailscale &>/dev/null; then
        TAILSCALE_INSTALLED=true
        TAILSCALE_EXISTING_VERSION=$(tailscale version 2>/dev/null | head -1 || echo "unknown")
    fi
}

# ─── Tailscale input ─────────────────────────────────────────────────────────
ask_auth_key() {
    local key=""
    local attempts=0

    while true; do
        prompt "Paste your Tailscale auth key"
        read -r key
        key=$(echo "$key" | xargs)

        if [[ -z "$key" ]]; then
            print_warn "Auth key cannot be empty."
            continue
        fi

        if [[ "$key" != tskey-auth-* ]]; then
            print_warn "Auth keys start with: tskey-auth-"
            ((attempts++))
            if [[ $attempts -ge 3 ]]; then
                print_error "Too many invalid attempts."
                print_info "Generate a key at: https://login.tailscale.com/admin/settings/keys"
                return 1
            fi
            continue
        fi

        AUTH_KEY="$key"
        print_ok "Auth key accepted."
        break
    done
}

ask_subnet_confirmation() {
    print_info "Detected LAN subnet: ${BOLD}${HOST_SUBNET}${NC}"
    print_info "From interface '${PRIMARY_IFACE}' (IP: ${HOST_IP})"
    echo ""
    prompt "Is this correct? (yes/no)"
    read -r answer

    if [[ "$answer" =~ ^[Yy](es)?$ ]]; then
        ADVERTISE_SUBNET="$HOST_SUBNET"
        return
    fi

    prompt "Enter your LAN subnet in CIDR notation (e.g. 192.168.1.0/24)"
    read -r custom_subnet
    custom_subnet=$(echo "$custom_subnet" | xargs)

    if [[ "$custom_subnet" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        ADVERTISE_SUBNET="$custom_subnet"
        print_ok "Subnet set to: ${ADVERTISE_SUBNET}"
    else
        print_error "Invalid format. Skipping Tailscale."
        return 1
    fi
}

# ─── Tailscale installation ──────────────────────────────────────────────────
install_tailscale() {
    print_step "5" "Tailscale Installation (Optional)"

    prompt "Would you like to install Tailscale as a VPN subnet router? (yes/no)"
    read -r want_tailscale

    if [[ ! "$want_tailscale" =~ ^[Yy](es)?$ ]]; then
        print_info "Skipping Tailscale installation."
        return
    fi

    echo ""
    print_info "Gathering system information..."
    detect_distro
    detect_kernel
    detect_primary_interface || return
    detect_host_ip || return
    detect_host_subnet
    detect_ip_forwarding
    detect_existing_tailscale

    print_ok "OS:        ${DISTRO_NAME}"
    print_ok "Kernel:    ${KERNEL_VERSION}"
    print_ok "Interface: ${PRIMARY_IFACE}"
    print_ok "Host IP:   ${HOST_IP}"
    print_ok "Subnet:    ${HOST_SUBNET}"
    echo ""

    ask_subnet_confirmation || return
    echo ""
    ask_auth_key || return

    # ── Review ──
    echo ""
    echo -e "  ${BOLD}Tailscale will:${NC}"
    echo -e "    1. Enable IP forwarding (persisted to /etc/sysctl.d/99-tailscale.conf)"
    echo -e "    2. Install Tailscale via official installer"
    echo -e "    3. Authenticate with your auth key"
    echo -e "    4. Advertise subnet route: ${CYAN}${ADVERTISE_SUBNET}${NC}"
    echo ""
    echo -e "  ${BOLD}Will NOT touch:${NC} docker-compose.yml, .env, running containers"
    echo ""

    prompt "Proceed? (yes/no)"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy](es)?$ ]]; then
        print_info "Skipping Tailscale."
        return
    fi

    # ── Enable IP forwarding ──
    print_info "Enabling IP forwarding..."
    cat > /etc/sysctl.d/99-tailscale.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null 2>&1
    print_ok "IP forwarding enabled and persisted."

    # ── Install ──
    print_info "Installing Tailscale..."
    if curl -fsSL https://tailscale.com/install.sh | sh; then
        print_ok "Tailscale installed."
    else
        print_error "Installation failed."
        return
    fi

    # ── Start service ──
    systemctl enable tailscaled 2>/dev/null || true
    systemctl start tailscaled
    sleep 2

    if systemctl is-active --quiet tailscaled; then
        print_ok "tailscaled service is running."
    else
        print_error "tailscaled failed to start. Check: sudo journalctl -u tailscaled -n 50"
        return
    fi

    # ── Authenticate ──
    print_info "Authenticating..."
    if tailscale up --auth-key="$AUTH_KEY" --advertise-routes="$ADVERTISE_SUBNET" 2>&1; then
        print_ok "Authenticated and advertising ${ADVERTISE_SUBNET}."
    else
        print_error "Authentication failed. Retry manually:"
        print_info "  sudo tailscale up --auth-key=<key> --advertise-routes=${ADVERTISE_SUBNET}"
        return
    fi

    # ── Verify ──
    local TS_IP
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "not yet assigned")
    print_ok "Tailscale IP: ${TS_IP}"

    echo ""
    echo -e "  ${BOLD}Next steps (Tailscale admin console):${NC}"
    echo -e "    1. Approve the subnet route: https://login.tailscale.com/admin/machines"
    echo -e "    2. Disable key expiry on this machine"
    echo -e "    3. Configure Split DNS for your domain (${DOMAIN})"
    echo -e "    4. Install Tailscale clients on your other devices"
}

# =============================================================================
# PHASE 6: SUMMARY
# =============================================================================

print_summary() {
    print_header "Setup Complete"

    echo ""
    echo -e "  ${BOLD}What was done:${NC}"
    echo -e "    ${GREEN}✓${NC}  .env file generated"
    echo -e "    ${GREEN}✓${NC}  Directory structure created"
    echo -e "    ${GREEN}✓${NC}  TLS certificates generated (Root CA + wildcard)"
    echo -e "    ${GREEN}✓${NC}  TinyAuth user created"
    echo ""
    echo -e "  ${BOLD}Before running 'docker compose up -d':${NC}"
    echo -e "    1. Review and complete the .env file (passwords, API keys, etc.)"
    echo -e "    2. Trust the Root CA on your client devices"
    echo -e "    3. Set up local DNS (router or /etc/hosts) pointing *.${DOMAIN} to this host"
    echo ""
    echo -e "  ${BOLD}After the first 'docker compose up -d':${NC}"
    echo -e "    1. Configure Beszel (Hub + Agent pairing, copy tokens to .env)"
    echo -e "    2. Configure Jellyfin (initial wizard, then generate API key for .env)"
    echo -e "    3. Configure qBittorrent (set username/password, update .env)"
    echo -e "    4. Configure Cinephage via its web UI (TMDB API key)"
    echo ""
    echo -e "  ${BOLD}See CONFIG.md for full details.${NC}"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    print_header "Homelab Setup"
    echo ""
    print_info "This script will configure your homelab environment."
    print_info "It generates .env, creates directories, certs, and auth users."
    echo ""

    check_root
    check_docker

    # Phase 1: .env
    print_step "1" "Generate .env Configuration"
    generate_env
    write_env_file

    # Phase 2: Directories
    create_directories

    # Phase 3: Certificates
    generate_certs

    # Phase 4: TinyAuth
    create_tinyauth_user

    # Phase 5: Tailscale (optional)
    install_tailscale

    # Done
    print_summary
}

main "$@"
