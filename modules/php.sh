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
# php switch
# =============================================================================

php_switch() {
    local new_version="$1"
    local old_version="${PHP_VERSION}"

    if [[ ! "${new_version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid PHP version '${new_version}'. Expected format: 8.3"
        exit 1
    fi

    if [[ "${new_version}" == "${old_version}" ]]; then
        log_warn "PHP ${new_version} is already the active version — nothing to do."
        exit 0
    fi

    log_info "Switching PHP ${old_version} → ${new_version}..."

    # 1. Mirror installed packages from old version
    log_info "Detecting installed packages for PHP ${old_version}..."
    local old_pkgs new_pkgs=()
    mapfile -t old_pkgs < <(dpkg-query -W -f='${Package}\n' "php${old_version}-*" 2>/dev/null | sort -u)

    if [[ ${#old_pkgs[@]} -eq 0 ]]; then
        log_warn "No packages found for PHP ${old_version} — using default extension list."
        for pkg in "${PHP_EXTENSIONS[@]}"; do
            new_pkgs+=("${pkg/${old_version}/${new_version}}")
        done
    else
        for pkg in "${old_pkgs[@]}"; do
            new_pkgs+=("${pkg/${old_version}/${new_version}}")
        done
    fi

    # 2. Install new version (skip packages that don't exist in the repo)
    _php_add_sury_repo
    apt-get update -qq

    local available_pkgs=()
    for pkg in "${new_pkgs[@]}"; do
        if apt-cache show "${pkg}" &>/dev/null 2>&1; then
            available_pkgs+=("${pkg}")
        else
            log_warn "Package not available, skipping: ${pkg}"
        fi
    done
    pkg_install "${available_pkgs[@]}"

    # 3. Enable and start new FPM before configuring so the service unit exists
    log_info "Enabling php${new_version}-fpm..."
    service_enable_start "php${new_version}-fpm"

    # 4. Apply lemp-manager PHP tuning for the new version
    PHP_VERSION="${new_version}"
    _php_configure

    # 5. Rewrite nginx vhosts
    local vhosts_dir="/etc/nginx/sites-available"
    local vhost_count=0
    if [[ -d "${vhosts_dir}" ]]; then
        while IFS= read -r -d '' vhost; do
            if grep -q "php${old_version}-fpm\.sock" "${vhost}"; then
                sed -i "s|php${old_version}-fpm\.sock|php${new_version}-fpm.sock|g" "${vhost}"
                log_info "Updated vhost: $(basename "${vhost}")"
                vhost_count=$((vhost_count + 1))
            fi
        done < <(find "${vhosts_dir}" -maxdepth 1 -type f -print0)
    fi

    # 6. Persist new version to lemp.conf
    log_info "Updating PHP_VERSION in ${CONFIG_FILE}..."
    sed -i "s|^PHP_VERSION=.*|PHP_VERSION=\"${new_version}\"|" "${CONFIG_FILE}"

    # 7. Test nginx and reload
    log_info "Testing nginx configuration..."
    if nginx -t 2>/dev/null; then
        service_reload nginx
        log_success "Nginx reloaded."
    else
        log_error "Nginx config test failed — FPM is running but nginx was NOT reloaded."
        log_error "Fix /etc/nginx/sites-available/ manually then run: nginx -t && systemctl reload nginx"
        exit 1
    fi

    # 8. Optionally stop old FPM
    if confirm "Stop and disable php${old_version}-fpm?"; then
        systemctl stop    "php${old_version}-fpm" 2>/dev/null || true
        systemctl disable "php${old_version}-fpm" 2>/dev/null || true
        log_info "php${old_version}-fpm stopped and disabled."
    else
        log_info "php${old_version}-fpm left running."
    fi

    # 9. Summary
    echo ""
    log_success "============================================="
    log_success " PHP switch complete: ${old_version} → ${new_version}"
    log_success "============================================="
    echo ""
    echo "  Previous version : ${old_version}"
    echo "  Active version   : ${new_version}"
    echo "  Vhosts updated   : ${vhost_count}"
    echo "  FPM socket       : /run/php/php${new_version}-fpm.sock"
    echo "  PHP config dir   : /etc/php/${new_version}/"
    echo "  lemp.conf        : PHP_VERSION=\"${new_version}\""
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
