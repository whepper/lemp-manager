#!/usr/bin/env bash
# modules/firewall.sh — UFW + fail2ban for lemp-manager

FIREWALL_PACKAGES=(ufw fail2ban)

module_install_firewall() {
    log_info "Installing firewall (UFW + fail2ban)..."

    apt-get update -qq
    pkg_install "${FIREWALL_PACKAGES[@]}"

    _ufw_configure
    _fail2ban_configure

    log_info "Firewall installed. Allowed ports: 22, 80, 443."
}

module_remove_firewall() {
    log_info "Removing firewall..."
    ufw disable 2>/dev/null || true
    systemctl stop fail2ban 2>/dev/null || true
    pkg_remove "${FIREWALL_PACKAGES[@]}"
    log_success "Firewall removed."
}

module_upgrade_firewall() {
    log_info "Upgrading firewall packages..."
    pkg_install "${FIREWALL_PACKAGES[@]}"
    service_restart fail2ban
}

module_status_firewall() {
    print_header "Firewall"

    # UFW
    if command -v ufw &>/dev/null; then
        local ufw_state
        ufw_state=$(ufw status 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
        if [[ "${ufw_state}" == "active" ]]; then
            status_line "UFW" "${ufw_state}" green
        else
            status_line "UFW" "${ufw_state}" red
        fi
    else
        status_line "UFW" "not installed" red
    fi

    # fail2ban
    local f2b_state
    f2b_state=$(service_status fail2ban)
    if [[ "${f2b_state}" == "active" ]]; then
        status_line "fail2ban" "${f2b_state}" green

        # Show banned IP counts per jail
        if command -v fail2ban-client &>/dev/null; then
            local wp_bans
            wp_bans=$(fail2ban-client status wordpress 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "?")
            status_line "WP login bans" "${wp_bans}"

            local ssh_bans
            ssh_bans=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "?")
            status_line "SSH bans" "${ssh_bans}"
        fi
    else
        status_line "fail2ban" "${f2b_state}" red
    fi
    echo ""
}

# =============================================================================
# Internal helpers
# =============================================================================

_ufw_configure() {
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow http
    ufw allow https
    ufw --force enable
    log_info "UFW enabled: 22, 80, 443."
}

_fail2ban_configure() {
    # WordPress wp-login.php brute force jail
    cat > /etc/fail2ban/jail.d/wordpress.conf <<'EOF'
[wordpress]
enabled  = true
port     = http,https
filter   = wordpress
logpath  = /var/log/nginx/*.access.log
maxretry = 5
findtime = 300
bantime  = 3600
EOF

    # fail2ban WordPress filter
    cat > /etc/fail2ban/filter.d/wordpress.conf <<'EOF'
[Definition]
failregex = ^<HOST> .* "POST .*wp-login\.php
            ^<HOST> .* "POST .*xmlrpc\.php
ignoreregex =
EOF

    service_enable_start fail2ban
    log_info "fail2ban configured: WordPress + SSH jails active."
}
