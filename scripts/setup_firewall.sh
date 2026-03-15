#!/usr/bin/env bash
# Configure iptables firewall rules

setup_firewall() {
    log_step "Configuring firewall..."

    # Check if iptables is available
    if ! command -v iptables &>/dev/null; then
        log_warn "iptables not found. Skipping firewall configuration."
        log_warn "Please configure your firewall manually to allow ports: 22, 53, 80, 443"
        return 0
    fi

    # Flush existing INPUT rules (preserve other chains)
    # We rebuild the INPUT chain from scratch
    log_info "Applying firewall rules..."

    # Allow loopback
    iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -i lo -j ACCEPT

    # Allow established/related connections
    iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow SSH (port 22) — critical: don't lock ourselves out
    iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT

    # Allow DNS (port 53) for dnstt — both TCP and UDP
    iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p udp --dport 53 -j ACCEPT
    iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p tcp --dport 53 -j ACCEPT

    # Allow HTTP (port 80) — for future Let's Encrypt (Phase 2)
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT

    # Allow HTTPS (port 443) — Xray proxy + cover site
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT

    # Set default policy to DROP for INPUT
    # Internal ports (8080, 10001) are localhost-only — default DROP protects them
    iptables -P INPUT DROP

    log_ok "Firewall rules applied."

    # --- Persist rules across reboots ---
    persist_firewall_rules
}

persist_firewall_rules() {
    log_info "Persisting firewall rules..."

    case "$PKG_MANAGER" in
        apt)
            # Debian/Ubuntu: use netfilter-persistent
            if ! command -v netfilter-persistent &>/dev/null; then
                # Pre-seed debconf to avoid interactive prompts
                echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | \
                    debconf-set-selections 2>/dev/null || true
                echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | \
                    debconf-set-selections 2>/dev/null || true
                $PKG_INSTALL "$IPTABLES_PERSIST_PKG" 2>/dev/null || true
            fi

            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save 2>/dev/null || true
                log_ok "Firewall rules persisted (netfilter-persistent)."
            else
                # Fallback: save manually
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                log_ok "Firewall rules saved to /etc/iptables/rules.v4"
            fi
            ;;

        yum|dnf)
            # CentOS/RHEL/Fedora: use iptables-services
            if ! systemctl is-active --quiet iptables 2>/dev/null; then
                $PKG_INSTALL "$IPTABLES_PERSIST_PKG" 2>/dev/null || true
                systemctl enable iptables 2>/dev/null || true
                systemctl start iptables 2>/dev/null || true
            fi
            service iptables save 2>/dev/null || \
                iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            log_ok "Firewall rules persisted (iptables-services)."
            ;;

        *)
            # Generic fallback
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

            # Create a restore script for boot
            if [[ ! -f /etc/network/if-pre-up.d/iptables ]]; then
                mkdir -p /etc/network/if-pre-up.d
                cat > /etc/network/if-pre-up.d/iptables <<'IPTSCRIPT'
#!/bin/sh
/sbin/iptables-restore < /etc/iptables/rules.v4
IPTSCRIPT
                chmod +x /etc/network/if-pre-up.d/iptables
            fi
            log_ok "Firewall rules saved to /etc/iptables/rules.v4"
            ;;
    esac
}
