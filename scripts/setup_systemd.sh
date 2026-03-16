#!/usr/bin/env bash
# Create and manage systemd service files for all PhonX components
# Service names are generic to avoid identification via systemctl list-units:
#   dns-resolver.service  (dnstt-server)
#   web-gateway.service   (xray)
#   web-app.service       (phonx-core)

# Service name constants — used across installer for consistency
SVC_DNSTT="dns-resolver"
SVC_XRAY="web-gateway"
SVC_CORE="web-app"

setup_systemd() {
    log_step "Setting up systemd services..."

    # Remove old service names from pre-rename installations
    for old_svc in dnstt-server xray phonx-core; do
        if systemctl is-active --quiet "${old_svc}.service" 2>/dev/null; then
            systemctl stop "${old_svc}.service" 2>/dev/null || true
        fi
        if [[ -f "/etc/systemd/system/${old_svc}.service" ]]; then
            systemctl disable "${old_svc}.service" 2>/dev/null || true
            rm -f "/etc/systemd/system/${old_svc}.service"
        fi
    done

    create_dnstt_service
    create_xray_service
    create_phonx_core_service

    # Restrict service files — they contain paths to private keys and internal ports
    chmod 600 /etc/systemd/system/${SVC_DNSTT}.service
    chmod 600 /etc/systemd/system/${SVC_XRAY}.service
    chmod 600 /etc/systemd/system/${SVC_CORE}.service

    # Reload systemd to pick up new service files
    systemctl daemon-reload

    # Enable all services (start on boot)
    systemctl enable ${SVC_DNSTT}.service 2>/dev/null || true
    systemctl enable ${SVC_XRAY}.service 2>/dev/null || true
    systemctl enable ${SVC_CORE}.service 2>/dev/null || true

    # Start/restart services in correct order
    # 1. web-app first (cover site must be ready for Xray fallback)
    log_info "Starting cover site server..."
    systemctl restart ${SVC_CORE}.service
    sleep 1
    if systemctl is-active --quiet ${SVC_CORE}.service; then
        log_ok "Cover site server is running."
    else
        log_warn "Cover site server failed to start. Check: journalctl -u ${SVC_CORE} -n 20"
    fi

    # 2. web-gateway (Xray proxy)
    log_info "Starting proxy..."
    systemctl restart ${SVC_XRAY}.service
    sleep 1
    if systemctl is-active --quiet ${SVC_XRAY}.service; then
        log_ok "Proxy is running."
    else
        log_error "Proxy failed to start. Check: journalctl -u ${SVC_XRAY} -n 20"
        log_error "Config validation:"
        /usr/local/bin/xray run -test -config "${PHONX_DIR}/xray.json" 2>&1 | tail -5 || true
    fi

    # 3. dns-resolver (dnstt-server)
    log_info "Starting DNS tunnel..."
    systemctl restart ${SVC_DNSTT}.service
    sleep 1
    if systemctl is-active --quiet ${SVC_DNSTT}.service; then
        log_ok "DNS tunnel is running."
    else
        log_warn "DNS tunnel failed to start. Check: journalctl -u ${SVC_DNSTT} -n 20"
        log_warn "This may be expected if DNS records haven't propagated yet."
    fi

    log_ok "Systemd services configured."
}

create_dnstt_service() {
    log_info "Creating ${SVC_DNSTT}.service..."

    # Write domain to EnvironmentFile (mode 600) — keeps domain out of .service file
    local DNSTT_DOMAIN="${DNS_DOMAINS[0]}"
    cat > "${PHONX_DIR}/dnstt.env" <<EOF
DNSTT_DOMAIN=${DNSTT_DOMAIN}
DNSTT_FORWARD_PORT=10001
EOF
    chmod 600 "${PHONX_DIR}/dnstt.env"

    cat > /etc/systemd/system/${SVC_DNSTT}.service <<DNSTTSERVICE
[Unit]
Description=DNS Resolver Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${PHONX_DIR}/dnstt.env
ExecStart=/usr/local/bin/dnstt-server \\
    -privkey-file ${PHONX_DIR}/dnstt_key.priv \\
    -udp :53 \\
    \${DNSTT_DOMAIN} \\
    127.0.0.1:\${DNSTT_FORWARD_PORT}
Restart=always
RestartSec=5
LimitNOFILE=65535

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/phonx
ReadWritePaths=/var/log
PrivateTmp=true

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SVC_DNSTT}

[Install]
WantedBy=multi-user.target
DNSTTSERVICE
}

create_xray_service() {
    log_info "Creating ${SVC_XRAY}.service..."

    cat > /etc/systemd/system/${SVC_XRAY}.service <<XRAYSERVICE
[Unit]
Description=Web Gateway Service
After=network-online.target ${SVC_CORE}.service
Wants=network-online.target

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray run -config /etc/phonx/xray.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3
LimitNOFILE=65535

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/phonx
ReadWritePaths=/var/log/xray
PrivateTmp=true

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SVC_XRAY}

[Install]
WantedBy=multi-user.target
XRAYSERVICE
}

create_phonx_core_service() {
    log_info "Creating ${SVC_CORE}.service..."

    if [[ -x /usr/local/bin/phonx-core ]]; then
        # Full phonx-core daemon
        cat > /etc/systemd/system/${SVC_CORE}.service <<CORESERVICE
[Unit]
Description=Web Application Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/phonx-core serve
WorkingDirectory=/etc/phonx
Restart=always
RestartSec=3
LimitNOFILE=65535

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/phonx/cover
ReadWritePaths=/etc/phonx/users /etc/phonx/xray.json /var/log
PrivateTmp=true

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SVC_CORE}

[Install]
WantedBy=multi-user.target
CORESERVICE
    else
        # Fallback: serve cover site with Python HTTP server until phonx-core is available
        log_info "phonx-core not found — using Python HTTP server for cover site."
        cat > /etc/systemd/system/${SVC_CORE}.service <<'CORESERVICE'
[Unit]
Description=Web Application Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 127.0.0.1 --directory /etc/phonx/cover
Restart=always
RestartSec=3

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/phonx/cover
PrivateTmp=true

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=web-app

[Install]
WantedBy=multi-user.target
CORESERVICE
    fi
}
