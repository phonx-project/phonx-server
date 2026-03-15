#!/usr/bin/env bash
# Download Xray-core and configure VLESS+WS+TLS proxy with fallback

setup_proxy() {
    log_step "Setting up proxy (Xray)..."

    local XRAY_BIN="/usr/local/bin/xray"
    local XRAY_ASSET_DIR="/usr/local/share/xray"

    # --- Download Xray-core ---
    if [[ ! -f "$XRAY_BIN" ]] || [[ "${FORCE_UPDATE:-false}" == "true" ]]; then
        log_info "Downloading Xray-core (${XRAY_ARCH})..."

        local XRAY_ZIP_NAME="Xray-linux-${XRAY_ARCH}.zip"
        local XRAY_URL="${XRAY_RELEASES}/${XRAY_ZIP_NAME}"
        local XRAY_TMP=$(mktemp -d)

        if ! curl -fSL --progress-bar "$XRAY_URL" -o "${XRAY_TMP}/${XRAY_ZIP_NAME}"; then
            log_error "Failed to download Xray-core from:"
            log_error "  ${XRAY_URL}"
            rm -rf "$XRAY_TMP"
            exit 1
        fi

        unzip -qo "${XRAY_TMP}/${XRAY_ZIP_NAME}" -d "$XRAY_TMP"

        # Install binary
        mv "${XRAY_TMP}/xray" "$XRAY_BIN"
        chmod +x "$XRAY_BIN"

        # Install geo data files
        mkdir -p "$XRAY_ASSET_DIR"
        for geofile in geoip.dat geosite.dat; do
            if [[ -f "${XRAY_TMP}/${geofile}" ]]; then
                mv "${XRAY_TMP}/${geofile}" "${XRAY_ASSET_DIR}/"
            fi
        done

        rm -rf "$XRAY_TMP"
        log_ok "Xray-core downloaded."
    else
        log_info "Xray-core already installed, skipping download."
    fi

    # --- Generate TLS certificate (self-signed, ECDSA P-256) ---
    if [[ ! -f "${PHONX_DIR}/tls_cert.pem" ]] || [[ ! -f "${PHONX_DIR}/tls_key.pem" ]]; then
        log_info "Generating self-signed TLS certificate..."

        # Random CN to avoid fingerprinting
        local RANDOM_CN
        RANDOM_CN="$(head -c 6 /dev/urandom | xxd -p).com"

        openssl req -x509 -newkey ec \
            -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "${PHONX_DIR}/tls_key.pem" \
            -out "${PHONX_DIR}/tls_cert.pem" \
            -days 3650 -nodes \
            -subj "/CN=${RANDOM_CN}" \
            2>/dev/null

        chmod 600 "${PHONX_DIR}/tls_key.pem"
        chmod 644 "${PHONX_DIR}/tls_cert.pem"

        log_ok "TLS certificate generated (ECDSA P-256, 10-year validity)."
    else
        log_info "TLS certificate already exists, preserving."
    fi

    # --- Generate or load UUID ---
    if [[ -n "${EXISTING_UUID:-}" ]]; then
        UUID="$EXISTING_UUID"
        log_info "Preserving existing UUID: ${UUID}"
    else
        UUID=$(cat /proc/sys/kernel/random/uuid)
        log_ok "Generated UUID: ${UUID}"
    fi

    # --- Generate or load WebSocket path ---
    if [[ -n "${EXISTING_WS_PATH:-}" ]]; then
        WS_PATH="$EXISTING_WS_PATH"
        log_info "Preserving existing WS path: ${WS_PATH}"
    else
        WS_PATH="/$(head -c 16 /dev/urandom | xxd -p | head -c 10)"
        log_ok "Generated WebSocket path: ${WS_PATH}"
    fi

    export UUID WS_PATH

    # --- Generate Xray config from template ---
    log_info "Creating Xray configuration..."

    # Build config from template
    sed -e "s|__UUID__|${UUID}|g" \
        -e "s|__WS_PATH__|${WS_PATH}|g" \
        "${SCRIPT_DIR}/config/xray.json.template" > "${PHONX_DIR}/xray.json"

    # Validate the generated JSON
    if ! jq empty "${PHONX_DIR}/xray.json" 2>/dev/null; then
        log_error "Generated Xray config is invalid JSON. This is a bug."
        exit 1
    fi

    log_ok "Xray configuration created."

    # --- Check port 443 availability ---
    if ss -lntp 2>/dev/null | grep -q ':443 '; then
        log_warn "Port 443 is currently in use. Xray may fail to start."
        log_warn "Conflicting service:"
        ss -lntp 2>/dev/null | grep ':443 ' | head -3
        log_warn "Consider stopping the conflicting service before starting Xray."
    fi

    log_ok "Proxy setup complete."
}
