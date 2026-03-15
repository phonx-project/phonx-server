#!/usr/bin/env bash
# Install required system dependencies

install_deps() {
    log_step "Installing system dependencies..."

    # Update package lists
    $PKG_UPDATE 2>/dev/null || true

    # Core dependencies
    local PACKAGES="curl wget unzip openssl jq"

    # DNS utilities for record verification
    PACKAGES="${PACKAGES} ${DNS_UTILS_PKG}"

    # Install all packages
    $PKG_INSTALL $PACKAGES 2>/dev/null || {
        log_warn "Batch install failed, trying packages individually..."
        for pkg in $PACKAGES; do
            $PKG_INSTALL "$pkg" 2>/dev/null || log_warn "Could not install: $pkg"
        done
    }

    # Verify essential commands are available
    local REQUIRED_CMDS="curl openssl jq"
    local missing=0
    for cmd in $REQUIRED_CMDS; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not available: $cmd"
            missing=1
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        log_error "Missing required dependencies. Please install them manually and re-run."
        exit 1
    fi

    # Create log directory for Xray
    mkdir -p /var/log/xray

    log_ok "Dependencies installed."
}
