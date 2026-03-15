#!/usr/bin/env bash
# PhonX Server Uninstaller
# Usage: curl -sL https://raw.githubusercontent.com/phonx-project/phonx-server/main/uninstall.sh | sudo bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[i]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*" >&2; }

PHONX_DIR="/etc/phonx"

if [[ "$(id -u)" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

if [[ ! -d "$PHONX_DIR" ]]; then
    log_error "PhonX does not appear to be installed (/etc/phonx not found)."
    exit 1
fi

echo ""
echo -e "${BOLD}${RED}PhonX Server Uninstaller${NC}"
echo ""
echo -e "This will remove:"
echo -e "  - Systemd services (dnstt-server, xray, phonx-core)"
echo -e "  - Binaries (dnstt-server, xray, phonx-core)"
echo -e "  - Configuration directory (${PHONX_DIR})"
echo -e "  - Firewall rules added by PhonX"
echo ""
echo -e "${YELLOW}WARNING: This will delete your dnstt keypair and TLS certificate.${NC}"
echo -e "${YELLOW}All existing client configs will stop working.${NC}"
echo ""
read -r -p "Are you sure you want to uninstall? [y/N] " confirm < /dev/tty
case "$confirm" in
    [yY]|[yY][eE][sS]) ;;
    *) log_info "Cancelled."; exit 0 ;;
esac

echo ""

# --- Stop and disable services ---
log_info "Stopping services..."
for svc in dnstt-server xray phonx-core; do
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        systemctl stop "${svc}.service" 2>/dev/null || true
        log_ok "Stopped ${svc}"
    fi
    if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
        systemctl disable "${svc}.service" 2>/dev/null || true
    fi
    rm -f "/etc/systemd/system/${svc}.service"
done
systemctl daemon-reload 2>/dev/null || true
log_ok "Services removed."

# --- Remove binaries ---
log_info "Removing binaries..."
for bin in /usr/local/bin/dnstt-server /usr/local/bin/xray /usr/local/bin/phonx-core; do
    if [[ -f "$bin" ]]; then
        rm -f "$bin"
        log_ok "Removed ${bin}"
    fi
done
rm -rf /usr/local/share/xray 2>/dev/null || true
log_ok "Binaries removed."

# --- Backup config before deletion ---
BACKUP="/root/phonx-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
log_info "Backing up ${PHONX_DIR} to ${BACKUP}..."
tar czf "$BACKUP" -C /etc phonx 2>/dev/null || true
log_ok "Backup saved to ${BACKUP}"

# --- Remove config directory ---
log_info "Removing ${PHONX_DIR}..."
rm -rf "$PHONX_DIR"
log_ok "Configuration removed."

# --- Clean up firewall rules ---
log_info "Resetting firewall to ACCEPT all..."
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -F INPUT 2>/dev/null || true
ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -F INPUT 2>/dev/null || true

if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save 2>/dev/null || true
elif [[ -f /etc/iptables/rules.v4 ]]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
fi
log_ok "Firewall reset."

# --- Clean up logs ---
rm -rf /var/log/xray 2>/dev/null || true

echo ""
echo -e "${GREEN}${BOLD}PhonX has been uninstalled.${NC}"
echo -e "Backup of your config: ${CYAN}${BACKUP}${NC}"
echo -e "To restore later: tar xzf ${BACKUP} -C /etc"
echo ""
