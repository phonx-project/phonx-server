#!/usr/bin/env bash
# Prepare cover website directory.
# The cover site is embedded in the phonx-core binary — no separate download needed.
# This script only creates the directory so admins can optionally deploy a custom cover site.
# If /etc/phonx/cover/index.html exists, phonx-core serves it; otherwise it serves the embedded page.

setup_cover() {
    log_step "Setting up cover website..."

    local COVER_DIR="${PHONX_DIR}/cover"
    mkdir -p "$COVER_DIR"

    if [[ -f "${COVER_DIR}/index.html" ]]; then
        log_info "Custom cover site found, phonx-core will serve it."
    else
        log_info "No custom cover site. phonx-core will serve its embedded cover page."
    fi

    # Ensure no git traces in cover directory
    rm -rf "${COVER_DIR}/.git" "${COVER_DIR}/.gitignore" "${COVER_DIR}/.github" 2>/dev/null || true

    log_ok "Cover website ready."
}
