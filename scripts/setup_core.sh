#!/usr/bin/env bash
# Download phonx-core binary and create server configuration

setup_core() {
    log_step "Setting up phonx-core..."

    local CORE_BIN="/usr/local/bin/phonx-core"

    # --- Download phonx-core binary ---
    if [[ ! -f "$CORE_BIN" ]] || [[ "${FORCE_UPDATE:-false}" == "true" ]]; then
        log_info "Downloading phonx-core (${ARCH_SUFFIX})..."

        local CORE_URL="${PHONX_RELEASES}/phonx-core-linux-${ARCH_SUFFIX}"

        if curl -fSL --progress-bar "$CORE_URL" -o "${CORE_BIN}.tmp" 2>/dev/null; then
            mv "${CORE_BIN}.tmp" "$CORE_BIN"
            chmod +x "$CORE_BIN"
            log_ok "phonx-core downloaded."
        else
            log_warn "phonx-core binary not available yet at:"
            log_warn "  ${CORE_URL}"
            log_warn "Cover site will be served, but genconfig will not be available."
            log_warn "You can download phonx-core manually later."
            PHONX_CORE_AVAILABLE=false
        fi
    else
        log_info "phonx-core already installed, skipping download."
    fi

    # --- Create server.json (server state file) ---
    log_info "Creating server configuration..."

    # Build DNS domains array for JSON
    local DNS_DOMAINS_JSON
    DNS_DOMAINS_JSON=$(printf '%s\n' "${DNS_DOMAINS[@]}" | jq -R . | jq -s .)

    local DNSTT_PUB
    DNSTT_PUB=$(cat "${PHONX_DIR}/dnstt_key.pub" 2>/dev/null || echo "")

    # Write server.json
    jq -n \
        --arg ip "$SERVER_IP" \
        --argjson port 443 \
        --arg ws_path "$WS_PATH" \
        --arg cf_host "${CF_HOST:-}" \
        --argjson dns_domains "$DNS_DOMAINS_JSON" \
        --arg dnstt_pubkey "$DNSTT_PUB" \
        --arg version "$PHONX_VERSION" \
        '{
            server_ip: $ip,
            proxy_port: $port,
            ws_path: $ws_path,
            cf_host: $cf_host,
            dns_domains: $dns_domains,
            dnstt_pubkey: $dnstt_pubkey,
            installed_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            version: $version
        }' > "${PHONX_DIR}/server.json"

    chmod 600 "${PHONX_DIR}/server.json"

    # Create users directory for tracking generated configs
    mkdir -p "${PHONX_DIR}/users"

    log_ok "Server configuration created."
}
