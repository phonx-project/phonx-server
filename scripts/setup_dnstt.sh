#!/usr/bin/env bash
# Download dnstt-server binary and configure DNS tunnel

check_port_53() {
    log_step "Checking port 53 availability..."

    # If our own dnstt-server is running (from previous install), stop it first
    if ss -lnp 2>/dev/null | grep ':53 ' | grep -q 'dnstt-server'; then
        log_info "Stopping existing dnstt-server to free port 53..."
        systemctl stop dns-resolver 2>/dev/null || true
        systemctl stop dnstt-server 2>/dev/null || true  # old service name
        sleep 1
    fi

    if ss -lnp 2>/dev/null | grep -q ':53 '; then
        # Check if systemd-resolved is the culprit
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            log_warn "systemd-resolved is occupying port 53."
            log_info "Disabling DNS stub listener to free port 53 for dnstt..."

            # Disable the stub listener (keeps systemd-resolved running for local resolution)
            mkdir -p /etc/systemd/resolved.conf.d/
            cat > /etc/systemd/resolved.conf.d/phonx-no-stub.conf <<'RESOLVEDCONF'
[Resolve]
DNSStubListener=no
DNS=1.1.1.1 1.0.0.1
RESOLVEDCONF

            # Restart systemd-resolved with new config
            systemctl restart systemd-resolved

            # Point resolv.conf to a working resolver
            # (systemd-resolved stub at 127.0.0.53 is now disabled)
            if [[ -L /etc/resolv.conf ]]; then
                rm -f /etc/resolv.conf
            fi
            cat > /etc/resolv.conf <<'RESOLVCONF'
nameserver 1.1.1.1
nameserver 1.0.0.1
RESOLVCONF

            # Give it a moment to release the port
            sleep 1

            if ss -lnp 2>/dev/null | grep -q ':53 '; then
                log_error "Port 53 is still in use after disabling systemd-resolved stub."
                log_error "Please free port 53 manually and re-run the installer."
                ss -lnp 2>/dev/null | grep ':53 ' | head -5
                exit 1
            fi

            log_ok "systemd-resolved stub disabled, port 53 is free."
        else
            # Something else is using port 53
            log_error "Port 53 is in use by another service:"
            ss -lnp 2>/dev/null | grep ':53 ' | head -5
            log_error ""
            log_error "dnstt requires port 53. Please stop the conflicting service:"
            log_error "  - If it's a DNS server (bind, dnsmasq): systemctl stop <service>"
            log_error "  - Then re-run this installer."
            exit 1
        fi
    else
        log_ok "Port 53 is available."
    fi
}

setup_dnstt() {
    log_step "Setting up dnstt server..."

    local DNSTT_BIN="/usr/local/bin/dnstt-server"

    # Download dnstt-server binary
    if [[ ! -f "$DNSTT_BIN" ]] || [[ "${FORCE_UPDATE:-false}" == "true" ]]; then
        log_info "Downloading dnstt-server (${ARCH_SUFFIX})..."
        local DNSTT_URL="${PHONX_RELEASES}/dnstt-server-linux-${ARCH_SUFFIX}"

        if curl -fSL --progress-bar "$DNSTT_URL" -o "${DNSTT_BIN}.tmp" 2>/dev/null; then
            mv "${DNSTT_BIN}.tmp" "$DNSTT_BIN"
            chmod +x "$DNSTT_BIN"
            log_ok "dnstt-server downloaded."
        else
            rm -f "${DNSTT_BIN}.tmp"
            if [[ -f "$DNSTT_BIN" ]]; then
                log_warn "Could not download latest dnstt-server, keeping existing binary."
            else
                log_error "Failed to download dnstt-server from:"
                log_error "  ${DNSTT_URL}"
                log_error "Make sure the binary is available at phonx-project releases."
                exit 1
            fi
        fi
    else
        log_info "dnstt-server already installed, skipping download."
    fi

    # Generate keypair if not already present
    if [[ ! -f "${PHONX_DIR}/dnstt_key.priv" ]] || [[ ! -f "${PHONX_DIR}/dnstt_key.pub" ]]; then
        log_info "Generating dnstt keypair..."

        # Try file-based key generation first (newer dnstt versions)
        if "$DNSTT_BIN" -gen-key \
            -privkey-file "${PHONX_DIR}/dnstt_key.priv" \
            -pubkey-file "${PHONX_DIR}/dnstt_key.pub" 2>/dev/null; then
            log_ok "dnstt keypair generated (file mode)."
        else
            # Fallback: parse stdout/stderr output
            local KEY_OUTPUT
            KEY_OUTPUT=$("$DNSTT_BIN" -gen-key 2>&1) || true

            local PRIVKEY PUBKEY
            PRIVKEY=$(echo "$KEY_OUTPUT" | grep -i 'privkey' | awk '{print $NF}')
            PUBKEY=$(echo "$KEY_OUTPUT" | grep -i 'pubkey' | awk '{print $NF}')

            if [[ -z "$PRIVKEY" ]] || [[ -z "$PUBKEY" ]]; then
                log_error "Failed to generate dnstt keypair. Output was:"
                log_error "$KEY_OUTPUT"
                exit 1
            fi

            echo "$PRIVKEY" > "${PHONX_DIR}/dnstt_key.priv"
            echo "$PUBKEY" > "${PHONX_DIR}/dnstt_key.pub"
            log_ok "dnstt keypair generated (parsed mode)."
        fi

        chmod 600 "${PHONX_DIR}/dnstt_key.priv"
        chmod 644 "${PHONX_DIR}/dnstt_key.pub"
    else
        log_info "dnstt keypair already exists, preserving."
    fi

    # Export public key for use in configs
    DNSTT_PUBKEY=$(cat "${PHONX_DIR}/dnstt_key.pub")
    export DNSTT_PUBKEY

    log_ok "dnstt server configured."
}
