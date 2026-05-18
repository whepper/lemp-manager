#!/usr/bin/env bash
# modules/php.sh — PHP-FPM module for lemp-manager (WordPress optimized)

PHP_EXTENSIONS=(
    "php${PHP_VERSION}-fpm"
    "php${PHP_VERSION}-cli"
    "php${PHP_VERSION}-common"
    "php${PHP_VERSION}-mysql"
    "php${PHP_VERSION}-curl"
    "php${PHP_VERSION}-imagick"
    "php${PHP_VERSION}-gd"
    "php${PHP_VERSION}-mbstring"
    "php${PHP_VERSION}-xml"
    "php${PHP_VERSION}-zip"
    "php${PHP_VERSION}-intl"
    "php${PHP_VERSION}-bcmath"
    "php${PHP_VERSION}-opcache"
    "php${PHP_VERSION}-redis"
    "php${PHP_VERSION}-soap"
)

module_install_php() {
    log_info "Installing PHP ${PHP_VERSION} (FPM, WordPress extensions)..."

    _php_add_sury_repo
    apt-get update -qq
    pkg_install "${PHP_EXTENSIONS[@]}"

    _php_configure
    service_enable_start "php${PHP_VERSION}-fpm"
    log_info "PHP ${PHP_VERSION}-FPM installed."
}

module_remove_php() {
    log_info "Removing PHP ${PHP_VERSION}..."
    systemctl stop "php${PHP_VERSION}-fpm" 2>/dev/null || true
    pkg_remove "${PHP_EXTENSIONS[@]}"
    rm -rf "/etc/php/${PHP_VERSION}"
    log_success "PHP ${PHP_VERSION} removed."
}

module_upgrade_php() {
    log_info "Upgrading PHP ${PHP_VERSION}..."
    _php_add_sury_repo
    apt-get update -qq
    pkg_install "${PHP_EXTENSIONS[@]}"
    service_restart "php${PHP_VERSION}-fpm"
}

module_status_php() {
    print_header "PHP"

    if command -v php &>/dev/null; then
        local version
        version=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown")
        status_line "Version" "${version}" green
    else
        status_line "Version" "not installed" red
    fi

    local fpm_state
    fpm_state=$(service_status "php${PHP_VERSION}-fpm")
    if [[ "${fpm_state}" == "active" ]]; then
        status_line "FPM service" "${fpm_state}" green
    else
        status_line "FPM service" "${fpm_state}" red
    fi

    status_line "Configured version" "${PHP_VERSION}"
    status_line "Config dir" "/etc/php/${PHP_VERSION}/"
    status_line "Socket" "/run/php/php${PHP_VERSION}-fpm.sock"
    echo ""
}

# =============================================================================
# Internal helpers
# =============================================================================

_php_add_sury_repo() {
    if [[ -f /etc/apt/sources.list.d/php.list ]]; then
        log_info "Sury PHP repo already configured."
        return 0
    fi

    log_info "Adding Sury PHP repository (multi-version PHP for Debian)..."
    pkg_install apt-transport-https ca-certificates curl gnupg

    curl -sSLo /tmp/php.gpg https://packages.sury.org/php/apt.gpg
    gpg --dearmor < /tmp/php.gpg > /etc/apt/trusted.gpg.d/php.gpg
    rm /tmp/php.gpg

    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/php.list

    log_info "Sury repo added."
}

_php_configure() {
    # Shared FPM pool tuning
    local fpm_conf="/etc/php/${PHP_VERSION}/fpm/conf.d/99-lemp-manager.ini"
    local cli_conf="/etc/php/${PHP_VERSION}/cli/conf.d/99-lemp-manager.ini"

    cat > "${fpm_conf}" <<EOF
; lemp-manager WordPress tuning
upload_max_filesize  = 64M
post_max_size        = 64M
max_execution_time   = 300
max_input_time       = 300
max_input_vars       = 3000
memory_limit         = 256M
date.timezone        = Europe/Amsterdam
expose_php           = Off

; OPcache
opcache.enable                = 1
opcache.memory_consumption    = 128
opcache.max_accelerated_files = 10000
opcache.revalidate_freq       = 60
opcache.jit                   = tracing
opcache.jit_buffer_size       = 64M
EOF

    # CLI gets same settings except memory limit is uncapped
    cp "${fpm_conf}" "${cli_conf}"
    echo "memory_limit = -1" >> "${cli_conf}"

    # FPM pool: ondemand for low-traffic personal sites
    local pool_conf="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    sed -i 's/^pm = .*/pm = ondemand/' "${pool_conf}"
    sed -i 's/^pm.max_children = .*/pm.max_children = 10/' "${pool_conf}"
    sed -i 's/^;pm.process_idle_timeout.*/pm.process_idle_timeout = 10s/' "${pool_conf}"
    sed -i 's/^;pm.max_requests.*/pm.max_requests = 500/' "${pool_conf}"

    service_restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
    log_info "PHP configuration applied."
}
