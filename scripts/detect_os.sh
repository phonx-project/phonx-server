#!/usr/bin/env bash
# Detect OS, distribution, architecture, and package manager

detect_os() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_error "This installer only supports Linux."
        exit 1
    fi

    # Detect architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            ARCH_SUFFIX="amd64"
            XRAY_ARCH="64"
            ;;
        aarch64|arm64)
            ARCH_SUFFIX="arm64"
            XRAY_ARCH="arm64-v8a"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            log_error "PhonX supports x86_64 (amd64) and aarch64 (arm64) only."
            exit 1
            ;;
    esac

    # Detect distribution
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-Linux}"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="rhel"
        OS_VERSION="unknown"
        OS_NAME=$(cat /etc/redhat-release)
    else
        log_warn "Cannot identify Linux distribution. Proceeding with defaults."
        OS_ID="unknown"
        OS_VERSION="unknown"
        OS_NAME="Linux"
    fi

    # Determine package manager
    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop|kali|raspbian)
            PKG_MANAGER="apt"
            PKG_UPDATE="apt-get update -qq"
            PKG_INSTALL="apt-get install -y -qq"
            DNS_UTILS_PKG="dnsutils"
            IPTABLES_PERSIST_PKG="iptables-persistent"
            ;;
        centos|rhel|rocky|alma|ol)
            PKG_MANAGER="yum"
            PKG_UPDATE="yum makecache -q"
            PKG_INSTALL="yum install -y -q"
            DNS_UTILS_PKG="bind-utils"
            IPTABLES_PERSIST_PKG="iptables-services"
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
                PKG_UPDATE="dnf makecache -q"
                PKG_INSTALL="dnf install -y -q"
            fi
            ;;
        fedora)
            PKG_MANAGER="dnf"
            PKG_UPDATE="dnf makecache -q"
            PKG_INSTALL="dnf install -y -q"
            DNS_UTILS_PKG="bind-utils"
            IPTABLES_PERSIST_PKG="iptables-services"
            ;;
        arch|manjaro)
            PKG_MANAGER="pacman"
            PKG_UPDATE="pacman -Sy --noconfirm"
            PKG_INSTALL="pacman -S --noconfirm"
            DNS_UTILS_PKG="bind"
            IPTABLES_PERSIST_PKG="iptables"
            ;;
        *)
            log_warn "Unknown distro '${OS_ID}'. Attempting apt-based install."
            PKG_MANAGER="apt"
            PKG_UPDATE="apt-get update -qq"
            PKG_INSTALL="apt-get install -y -qq"
            DNS_UTILS_PKG="dnsutils"
            IPTABLES_PERSIST_PKG="iptables-persistent"
            ;;
    esac

    export ARCH ARCH_SUFFIX XRAY_ARCH OS_ID OS_VERSION OS_NAME
    export PKG_MANAGER PKG_UPDATE PKG_INSTALL DNS_UTILS_PKG IPTABLES_PERSIST_PKG

    log_ok "Detected: ${OS_NAME} (${ARCH} / ${ARCH_SUFFIX})"
}
