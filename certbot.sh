#!/usr/bin/env bash
# modules/certbot.sh — Let's Encrypt / Certbot module for lemp-manager

CERTBOT_PACKAGES=(certbot python3-certbot-nginx)
CERTBOT_SERVICE="certbot.timer"

module_install_certbot() {
    log_info "Installing Certbot (Let's Encrypt)..."

    apt-get update -qq
    pkg_install "${CERTBOT_PACKAGES[@]}"

    # Enable auto-renewal timer
    systemctl enable --now certbot.timer 2>/dev/null || true

    log_info "Certbot installed. Auto-renewal enabled via systemd timer."
}

module_remove_certbot() {
    log_info "Removing Certbot..."
    systemctl stop certbot.timer 2>/dev/null || true
    pkg_remove "${CERTBOT_PACKAGES[@]}"
    log_success "Certbot removed. Certificates in /etc/letsencrypt remain."
}

module_upgrade_certbot() {
    log_info "Upgrading Certbot..."
    pkg_install "${CERTBOT_PACKAGES[@]}"
}

module_status_certbot() {
    print_header "Certbot / Let's Encrypt"

    if command -v certbot &>/dev/null; then
        local version
        version=$(certbot --version 2>&1 | grep -oP '[\d.]+' | head -1 || echo "unknown")
        status_line "Version" "${version}" green
    else
        status_line "Installed" "no" red
    fi

    local timer_state
    timer_state=$(service_status certbot.timer)
    if [[ "${timer_state}" == "active" ]]; then
        status_line "Auto-renewal" "active (systemd timer)" green
    else
        status_line "Auto-renewal" "${timer_state}" yellow
    fi

    # List issued certs
    if command -v certbot &>/dev/null; then
        local certs
        certs=$(certbot certificates 2>/dev/null | grep "Domains:" | sed 's/.*Domains: //' || echo "none")
        status_line "Issued certs" "${certs:-none}"
    fi
    echo ""
}

# =============================================================================
# Per-site SSL (called by site.sh)
# =============================================================================

certbot_provision() {
    local domain="$1"
    local email="${2:-}"

    if [[ -z "${email}" ]]; then
        read -rp "  Email address for Let's Encrypt notifications: " email
    fi

    log_info "Provisioning SSL certificate for ${domain}..."

    certbot --nginx \
        --non-interactive \
        --agree-tos \
        --email "${email}" \
        --domains "${domain},www.${domain}" \
        --redirect

    log_success "SSL certificate provisioned for ${domain}."
}
