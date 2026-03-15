#!/usr/bin/env bash
# Create and manage systemd service files for all PhonX components

setup_systemd() {
    log_step "Setting up systemd services..."

    create_dnstt_service
    create_xray_service
    create_phonx_core_service

    # Reload systemd to pick up new service files
    systemctl daemon-reload

    # Enable all services (start on boot)
    systemctl enable dnstt-server.service 2>/dev/null || true
    systemctl enable xray.service 2>/dev/null || true
    systemctl enable phonx-core.service 2>/dev/null || true

    # Start/restart services in correct order
    # 1. phonx-core first (cover site must be ready for Xray fallback)
    log_info "Starting phonx-core..."
    if [[ "${PHONX_CORE_AVAILABLE:-true}" == "true" ]] && [[ -x /usr/local/bin/phonx-core ]]; then
        systemctl restart phonx-core.service
        sleep 1
        if systemctl is-active --quiet phonx-core.service; then
            log_ok "phonx-core is running."
        else
            log_warn "phonx-core failed to start. Check: journalctl -u phonx-core -n 20"
        fi
    else
        log_warn "phonx-core not available, skipping start."
    fi

    # 2. Xray (proxy)
    log_info "Starting Xray..."
    systemctl restart xray.service
    sleep 1
    if systemctl is-active --quiet xray.service; then
        log_ok "Xray is running."
    else
        log_error "Xray failed to start. Check: journalctl -u xray -n 20"
        log_error "Config validation:"
        /usr/local/bin/xray run -test -config "${PHONX_DIR}/xray.json" 2>&1 | tail -5 || true
    fi

    # 3. dnstt-server
    log_info "Starting dnstt-server..."
    systemctl restart dnstt-server.service
    sleep 1
    if systemctl is-active --quiet dnstt-server.service; then
        log_ok "dnstt-server is running."
    else
        log_warn "dnstt-server failed to start. Check: journalctl -u dnstt-server -n 20"
        log_warn "This may be expected if DNS records haven't propagated yet."
    fi

    log_ok "Systemd services configured."
}

create_dnstt_service() {
    log_info "Creating dnstt-server.service..."

    # Build domain arguments — dnstt-server takes one domain
    # Use the first domain from the list
    local DNSTT_DOMAIN="${DNS_DOMAINS[0]}"

    cat > /etc/systemd/system/dnstt-server.service <<DNSTTSERVICE
[Unit]
Description=dnstt DNS Tunnel Server
Documentation=https://www.bamsoftware.com/software/dnstt/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dnstt-server \\
    -privkey-file ${PHONX_DIR}/dnstt_key.priv \\
    -udp :53 \\
    -tcp :53 \\
    ${DNSTT_DOMAIN} \\
    127.0.0.1:10001
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
SyslogIdentifier=dnstt-server

[Install]
WantedBy=multi-user.target
DNSTTSERVICE
}

create_xray_service() {
    log_info "Creating xray.service..."

    cat > /etc/systemd/system/xray.service <<'XRAYSERVICE'
[Unit]
Description=Xray Proxy Service
Documentation=https://xtls.github.io/
After=network-online.target phonx-core.service
Wants=network-online.target

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray run -config /etc/phonx/xray.json
ExecReload=/bin/kill -HUP $MAINPID
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
SyslogIdentifier=xray

[Install]
WantedBy=multi-user.target
XRAYSERVICE
}

create_phonx_core_service() {
    log_info "Creating phonx-core.service..."

    cat > /etc/systemd/system/phonx-core.service <<'CORESERVICE'
[Unit]
Description=PhonX Core Daemon
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
SyslogIdentifier=phonx-core

[Install]
WantedBy=multi-user.target
CORESERVICE
}
