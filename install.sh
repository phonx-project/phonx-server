#!/usr/bin/env bash
# ============================================================================
# PhonX Server Installer
#
# Sets up a Linux VPS as a PhonX bypass server with:
#   - DNS tunnel endpoint (dnstt) on port 53
#   - VLESS+WS+TLS proxy (Xray) on port 443 with cover site fallback
#   - phonx-core daemon serving cover website on 127.0.0.1:8080
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/phonx-project/phonx-server/main/install.sh | bash
#
# Or clone and run:
#   git clone https://github.com/phonx-project/phonx-server.git
#   cd phonx-server && bash install.sh
# ============================================================================
{ # Brace ensures the entire script is downloaded before execution begins

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================
PHONX_VERSION="0.1.0"
PHONX_REPO="phonx-project/phonx-server"
PHONX_DIR="/etc/phonx"
PHONX_RELEASES="https://github.com/${PHONX_REPO}/releases/latest/download"
XRAY_RELEASES="https://github.com/XTLS/Xray-core/releases/latest/download"

EXISTING_INSTALL=false
FORCE_UPDATE=false
PHONX_CORE_AVAILABLE=true

# DNS domains array
declare -a DNS_DOMAINS=()

# =============================================================================
# Colors & Logging
# =============================================================================
if [[ -t 1 ]] || [[ -t 2 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

log_info()  { echo -e "${BLUE}[i]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*" >&2; }
log_step()  { echo -e "\n${CYAN}${BOLD}→ $*${NC}"; }

print_banner() {
    echo -e "${GREEN}"
    cat <<'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║          ██████╗ ██╗  ██╗ ██████╗ ███╗   ██╗██╗  ██╗ ║
  ║          ██╔══██╗██║  ██║██╔═══██╗████╗  ██║╚██╗██╔╝ ║
  ║          ██████╔╝███████║██║   ██║██╔██╗ ██║ ╚███╔╝  ║
  ║          ██╔═══╝ ██╔══██║██║   ██║██║╚██╗██║ ██╔██╗  ║
  ║          ██║     ██║  ██║╚██████╔╝██║ ╚████║██╔╝ ██╗ ║
  ║          ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═╝ ║
  ║                                                      ║
  ║              Server Installer  v0.1.0                ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

# =============================================================================
# Pre-flight Checks
# =============================================================================
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This installer must be run as root."
        log_error "Try: sudo bash install.sh"
        exit 1
    fi
}

check_existing_install() {
    if [[ -d "$PHONX_DIR" ]] && [[ -f "${PHONX_DIR}/server.json" ]]; then
        EXISTING_INSTALL=true
        log_warn "Existing PhonX installation detected at ${PHONX_DIR}"
        log_info "The following will be ${GREEN}preserved${NC}:"
        log_info "  - dnstt keypair (dnstt_key.priv, dnstt_key.pub)"
        log_info "  - TLS certificate (tls_cert.pem, tls_key.pem)"
        log_info "  - WebSocket path and UUIDs"
        log_info "  - User configs (users/)"
        log_info "The following will be ${YELLOW}updated${NC}:"
        log_info "  - Binaries (dnstt-server, xray, phonx-core)"
        log_info "  - Systemd service files"
        echo ""

        # Load existing values to preserve them
        if command -v jq &>/dev/null && [[ -f "${PHONX_DIR}/server.json" ]]; then
            EXISTING_UUID=$(jq -r '.uuid // empty' "${PHONX_DIR}/server.json" 2>/dev/null || true)
            EXISTING_WS_PATH=$(jq -r '.ws_path // empty' "${PHONX_DIR}/server.json" 2>/dev/null || true)
        fi

        # Also try to extract UUID from existing xray.json
        if [[ -z "${EXISTING_UUID:-}" ]] && [[ -f "${PHONX_DIR}/xray.json" ]]; then
            EXISTING_UUID=$(jq -r '.inbounds[1].settings.clients[0].id // empty' "${PHONX_DIR}/xray.json" 2>/dev/null || true)
        fi
        if [[ -z "${EXISTING_WS_PATH:-}" ]] && [[ -f "${PHONX_DIR}/xray.json" ]]; then
            EXISTING_WS_PATH=$(jq -r '.inbounds[1].streamSettings.wsSettings.path // empty' "${PHONX_DIR}/xray.json" 2>/dev/null || true)
        fi

        FORCE_UPDATE=true

        read -r -p "Continue with update? [Y/n] " response < /dev/tty
        case "$response" in
            [nN]|[nN][oO])
                log_info "Installation cancelled."
                exit 0
                ;;
        esac
    fi

    # Create phonx directory
    mkdir -p "$PHONX_DIR"
    chmod 700 "$PHONX_DIR"
}

# =============================================================================
# Network Detection
# =============================================================================
detect_server_ip() {
    log_step "Detecting server IP address..."

    # Try multiple services for reliability
    SERVER_IP=""
    local services=(
        "https://ifconfig.me"
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ipecho.net/plain"
        "https://checkip.amazonaws.com"
    )

    for service in "${services[@]}"; do
        SERVER_IP=$(curl -s4 --max-time 5 "$service" 2>/dev/null | tr -d '[:space:]') || true
        if [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        SERVER_IP=""
    done

    if [[ -z "$SERVER_IP" ]]; then
        log_warn "Could not auto-detect public IP address."
        echo ""
        read -r -p "Enter this server's public IPv4 address: " SERVER_IP < /dev/tty

        if [[ ! "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_error "Invalid IP address: ${SERVER_IP}"
            exit 1
        fi
    fi

    export SERVER_IP
    log_ok "Server IP: ${SERVER_IP}"
}

# =============================================================================
# DNS Domain Configuration
# =============================================================================
validate_domain() {
    local domain="$1"
    # Basic domain validation: alphanumeric, hyphens, dots, valid TLD
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

ask_dns_domains() {
    log_step "DNS Tunnel Configuration"

    echo ""
    echo -e "${BOLD}PhonX uses DNS tunneling as a fallback when your VPS IP is blocked.${NC}"
    echo -e "${BOLD}This requires a domain with specific DNS records.${NC}"
    echo ""
    echo -e "You need a cheap domain (~\$1/year) with ${YELLOW}TWO${NC} DNS records:"
    echo ""
    echo -e "  ${CYAN}1.${NC} NS record:  ${GREEN}t.yourdomain.com${NC}  →  ${GREEN}ns.yourdomain.com${NC}"
    echo -e "  ${CYAN}2.${NC} A  record:  ${GREEN}ns.yourdomain.com${NC} →  ${GREEN}${SERVER_IP}${NC}"
    echo ""
    echo -e "${DIM}The NS record tells the DNS system that your VPS is the authoritative"
    echo -e "nameserver for t.yourdomain.com. The A record (glue record) maps the"
    echo -e "nameserver hostname to your server's IP address.${NC}"
    echo ""
    echo -e "${YELLOW}Cloudflare users:${NC} The A record MUST use ${YELLOW}gray cloud (DNS only)${NC}."
    echo -e "${DIM}Proxy (orange cloud) would route queries to Cloudflare's IP instead of"
    echo -e "your VPS, and port 53 traffic would never reach dnstt-server.${NC}"
    echo ""
    echo -e "${DIM}Domain should be boring/innocuous (e.g., recipe-notes-app.com, not vpn-bypass.com)${NC}"
    echo ""

    while true; do
        read -r -p "Enter your domain (e.g., myblog-2024.com): " input_domain < /dev/tty

        # Trim whitespace
        input_domain=$(echo "$input_domain" | xargs)

        if [[ -z "$input_domain" ]]; then
            log_error "Domain cannot be empty."
            continue
        fi

        # Strip leading "t." if user included it
        input_domain="${input_domain#t.}"

        if ! validate_domain "$input_domain"; then
            log_error "Invalid domain format: ${input_domain}"
            log_error "Example: myblog-2024.com"
            continue
        fi

        # Build the dnstt domain (t.domain)
        local dnstt_domain="t.${input_domain}"
        DNS_DOMAINS=("$dnstt_domain")

        echo ""
        log_info "DNS tunnel domain: ${GREEN}${dnstt_domain}${NC}"
        log_info "Required DNS records:"
        log_info "  NS:  ${dnstt_domain} → ns.${input_domain}"
        log_info "  A:   ns.${input_domain} → ${SERVER_IP}"
        echo ""

        read -r -p "Is this correct? [Y/n] " confirm < /dev/tty
        case "$confirm" in
            [nN]|[nN][oO]) continue ;;
            *) break ;;
        esac
    done

    # Ask if they want to add more domains
    while true; do
        echo ""
        read -r -p "Add another DNS tunnel domain? [y/N] " add_more < /dev/tty
        case "$add_more" in
            [yY]|[yY][eE][sS])
                read -r -p "Enter domain: " extra_domain < /dev/tty
                extra_domain=$(echo "$extra_domain" | xargs)
                extra_domain="${extra_domain#t.}"
                if validate_domain "$extra_domain"; then
                    DNS_DOMAINS+=("t.${extra_domain}")
                    log_ok "Added: t.${extra_domain}"
                else
                    log_error "Invalid domain: ${extra_domain}"
                fi
                ;;
            *) break ;;
        esac
    done

    export DNS_DOMAINS
    log_ok "DNS domains configured: ${DNS_DOMAINS[*]}"
}

verify_dns_records() {
    log_step "Verifying DNS records..."

    # Check if dig is available
    if ! command -v dig &>/dev/null; then
        log_warn "dig command not available. Skipping DNS verification."
        log_warn "Make sure your DNS records are configured correctly."
        return 0
    fi

    local all_ok=true
    local first_domain="${DNS_DOMAINS[0]}"
    # Extract base domain from t.domain.com → domain.com
    local base_domain="${first_domain#t.}"

    echo ""
    log_info "Checking DNS records for ${base_domain}..."
    echo ""

    # Check NS record: t.domain.com should have NS pointing to ns.domain.com
    # We query the PARENT zone's nameserver directly (+norecurse) because
    # a recursive query would follow the delegation to our VPS port 53,
    # where dnstt-server isn't running yet — causing a false negative.
    local ns_result=""
    local parent_ns
    parent_ns=$(dig +short NS "${base_domain}" @8.8.8.8 2>/dev/null | head -1 | sed 's/\.$//')

    if [[ -n "$parent_ns" ]]; then
        # Query parent nameserver directly for the delegation (non-recursive)
        ns_result=$(dig NS "${first_domain}" @"${parent_ns}" +norecurse 2>/dev/null \
            | grep -i "IN.*NS" | grep -v "^;" \
            | awk '{print $NF}' | sed 's/\.$//' | head -1)
    fi

    # Fallback: try recursive query in case the above didn't work
    if [[ -z "$ns_result" ]]; then
        ns_result=$(dig +short NS "${first_domain}" @8.8.8.8 2>/dev/null | head -1 | sed 's/\.$//')
    fi

    local expected_ns="ns.${base_domain}"

    echo -e "  NS record for ${CYAN}${first_domain}${NC}:"
    echo -e "    Expected: ${GREEN}${expected_ns}${NC}"
    if [[ -n "$ns_result" ]]; then
        if [[ "$ns_result" == "$expected_ns" ]]; then
            echo -e "    Got:      ${GREEN}${ns_result}${NC}  ✓"
        else
            echo -e "    Got:      ${YELLOW}${ns_result}${NC}  (different but may work)"
        fi
    else
        echo -e "    Got:      ${RED}(not found)${NC}  ✗"
        all_ok=false
    fi
    echo ""

    # Check A record: ns.domain.com should point to server IP
    local a_result
    a_result=$(dig +short A "ns.${base_domain}" @8.8.8.8 2>/dev/null | head -1)

    echo -e "  A record for ${CYAN}ns.${base_domain}${NC}:"
    echo -e "    Expected: ${GREEN}${SERVER_IP}${NC}"
    if [[ -n "$a_result" ]]; then
        if [[ "$a_result" == "$SERVER_IP" ]]; then
            echo -e "    Got:      ${GREEN}${a_result}${NC}  ✓"
        else
            echo -e "    Got:      ${RED}${a_result}${NC}  ✗ (wrong IP)"
            all_ok=false
        fi
    else
        echo -e "    Got:      ${RED}(not found)${NC}  ✗"
        all_ok=false
    fi
    echo ""

    if [[ "$all_ok" == "true" ]]; then
        log_ok "DNS records verified successfully."
        return 0
    fi

    # Records not ready — give user options
    echo -e "${YELLOW}DNS records are not configured correctly.${NC}"
    echo ""
    echo -e "Before running this installer, add these records at your domain registrar"
    echo -e "(e.g., Namecheap, Porkbun, Cloudflare):"
    echo ""
    echo -e "  ${CYAN}1.${NC} NS record:  ${GREEN}${first_domain}${NC}  →  ${GREEN}ns.${base_domain}${NC}"
    echo -e "  ${CYAN}2.${NC} A  record:  ${GREEN}ns.${base_domain}${NC}  →  ${GREEN}${SERVER_IP}${NC}  ${YELLOW}(gray cloud / DNS only)${NC}"
    echo ""
    echo -e "${DIM}Cloudflare users: the A record MUST have proxy OFF (gray cloud).${NC}"
    echo -e "${DIM}Note: DNS changes can take up to 48 hours to propagate.${NC}"
    echo -e "${DIM}Check propagation at: https://dnschecker.org${NC}"
    echo ""

    while true; do
        echo -e "Options:"
        echo -e "  ${CYAN}[c]${NC} Continue anyway (skip DNS verification)"
        echo -e "  ${CYAN}[r]${NC} Retry the check"
        echo -e "  ${CYAN}[q]${NC} Quit and configure DNS first"
        echo ""
        read -r -p "Choose [c/r/q]: " choice < /dev/tty

        case "$choice" in
            [cC])
                log_warn "Continuing without DNS verification."
                log_warn "dnstt will not work until DNS records are properly configured."
                return 0
                ;;
            [rR])
                verify_dns_records
                return $?
                ;;
            [qQ]|*)
                log_info "Exiting. Configure DNS records and re-run the installer."
                exit 0
                ;;
        esac
    done
}

# =============================================================================
# Config Generation & Completion
# =============================================================================
generate_first_config() {
    log_step "Generating initial client configuration..."

    if [[ -x /usr/local/bin/phonx-core ]]; then
        local CONFIG_OUTPUT
        CONFIG_OUTPUT=$(/usr/local/bin/phonx-core genconfig 2>&1) || true

        if [[ -n "$CONFIG_OUTPUT" ]] && [[ "$CONFIG_OUTPUT" != *"error"* ]]; then
            FIRST_CONFIG="$CONFIG_OUTPUT"
            log_ok "Client configuration generated."
        else
            log_warn "phonx-core genconfig returned an error:"
            log_warn "$CONFIG_OUTPUT"
            FIRST_CONFIG=""
        fi
    else
        log_warn "phonx-core is not available. Skipping initial config generation."
        log_warn "Run 'phonx-core genconfig' manually once it's installed."
        FIRST_CONFIG=""
    fi
}

show_completion() {
    echo ""
    echo ""
    echo -e "${GREEN}"
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │                                                          │"
    echo "  │              PhonX Server Ready!                         │"
    echo "  │                                                          │"

    if [[ -n "${FIRST_CONFIG:-}" ]]; then
        echo "  │  Send this to your users:                                │"
        echo "  │                                                          │"
        echo "  │  ${FIRST_CONFIG}"
        echo "  │                                                          │"
        echo "  │  User pastes this into PhonX client → connected.         │"
    else
        echo "  │  Server is configured and running.                       │"
        echo "  │                                                          │"
        echo "  │  To generate a client config:                            │"
        echo "  │    phonx-core genconfig                                  │"
    fi

    echo "  │                                                          │"
    echo "  │  To generate config for another user:                    │"
    echo "  │    phonx-core genconfig                                  │"
    echo "  │  (Each run = new UUID + new client_token)                │"
    echo "  │                                                          │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo -e "${NC}"

    # Print service status summary
    echo -e "${BOLD}Service Status:${NC}"
    local svc_dnstt svc_xray svc_core
    svc_dnstt=$(systemctl is-active dnstt-server.service 2>/dev/null) || true
    svc_xray=$(systemctl is-active xray.service 2>/dev/null) || true
    svc_core=$(systemctl is-active phonx-core.service 2>/dev/null) || true
    echo -e "  dnstt-server: ${svc_dnstt:-unknown}"
    echo -e "  xray:         ${svc_xray:-unknown}"
    echo -e "  phonx-core:   ${svc_core:-unknown}"
    echo ""

    echo -e "${BOLD}Server Details:${NC}"
    echo -e "  IP:           ${SERVER_IP}"
    echo -e "  Proxy:        Port 443 (VLESS+WS+TLS 1.3)"
    echo -e "  DNS Tunnel:   Port 53 (dnstt → ${DNS_DOMAINS[*]})"
    echo -e "  Cover Site:   127.0.0.1:8080 (Xray fallback)"
    echo -e "  WS Path:      ${WS_PATH}"
    echo ""

    echo -e "${BOLD}Useful Commands:${NC}"
    echo -e "  ${CYAN}phonx-core genconfig${NC}              Generate new client config"
    echo -e "  ${CYAN}systemctl status xray${NC}             Check proxy status"
    echo -e "  ${CYAN}systemctl status dnstt-server${NC}     Check DNS tunnel status"
    echo -e "  ${CYAN}systemctl status phonx-core${NC}       Check core daemon status"
    echo -e "  ${CYAN}journalctl -u xray -f${NC}            Follow Xray logs"
    echo -e "  ${CYAN}journalctl -u dnstt-server -f${NC}    Follow dnstt logs"
    echo ""

    echo -e "${BOLD}Config Directory:${NC} ${PHONX_DIR}/"
    echo -e "  ${DIM}server.json     — server state"
    echo -e "  xray.json       — Xray proxy config"
    echo -e "  dnstt_key.priv  — dnstt private key (NEVER share)"
    echo -e "  dnstt_key.pub   — dnstt public key"
    echo -e "  tls_cert.pem    — TLS certificate"
    echo -e "  cover/          — cover website files${NC}"
    echo ""

    echo -e "${YELLOW}Important:${NC}"
    echo -e "  - Back up ${PHONX_DIR}/ — if you migrate servers with the same keys,"
    echo -e "    existing client configs will continue to work."
    echo -e "  - Never share dnstt_key.priv or server.json."
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    print_banner

    # --- Pre-flight ---
    check_root
    detect_os
    check_existing_install
    install_deps
    detect_server_ip
    ask_dns_domains
    verify_dns_records

    # --- Component Setup ---
    check_port_53
    setup_dnstt
    setup_proxy
    setup_cover
    setup_core

    # --- System Configuration ---
    setup_firewall
    setup_systemd

    # --- Finalize ---
    generate_first_config
    show_completion
}

# =============================================================================
# Script Entry Point
# =============================================================================

# Determine script directory (cloned repo vs curl|bash)
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -d "$(dirname "${BASH_SOURCE[0]}")/scripts" ]]; then
    # Running from cloned repo
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # Running via curl|bash — download the repo
    SCRIPT_DIR=$(mktemp -d)
    CLEANUP_SCRIPTS=true

    echo -e "${BLUE}[i]${NC} Downloading PhonX installer package..."
    if ! curl -sL "https://github.com/${PHONX_REPO}/archive/main.tar.gz" | \
        tar xz -C "$SCRIPT_DIR" --strip-components=1 2>/dev/null; then
        echo -e "${RED}[✗]${NC} Failed to download installer package." >&2
        echo -e "${RED}[✗]${NC} Please try cloning the repository instead:" >&2
        echo -e "${RED}[✗]${NC}   git clone https://github.com/${PHONX_REPO}.git" >&2
        rm -rf "$SCRIPT_DIR"
        exit 1
    fi
fi

export SCRIPT_DIR

# Source all component scripts
for script in detect_os install_deps setup_dnstt setup_proxy setup_cover \
              setup_firewall setup_core setup_systemd; do
    if [[ -f "${SCRIPT_DIR}/scripts/${script}.sh" ]]; then
        source "${SCRIPT_DIR}/scripts/${script}.sh"
    else
        echo -e "${RED}[✗]${NC} Missing script: scripts/${script}.sh" >&2
        exit 1
    fi
done

# Run the installer
main "$@"

# Cleanup downloaded scripts if applicable
if [[ "${CLEANUP_SCRIPTS:-}" == "true" ]]; then
    rm -rf "$SCRIPT_DIR"
fi

} # End of download safety brace
