#!/usr/bin/env bash
# site.sh — Multi-site WordPress management for lemp-manager

# Load all required modules for site management
load_module nginx
load_module mariadb
load_module certbot
load_module wordpress

# =============================================================================
# site create <domain>
# =============================================================================

site_create() {
    local domain="${1:-}"
    require_root

    if [[ -z "${domain}" ]]; then
        log_error "Usage: ./lemp.sh site create <domain>"
        exit 1
    fi

    if site_exists "${domain}"; then
        log_error "Site '${domain}' already exists. Use 'site info ${domain}' to view details."
        exit 1
    fi

    print_header "Creating site: ${domain}"

    # DNS pre-check (warn only, don't block)
    check_dns "${domain}" || true

    # Derive DB credentials
    local safe_name
    safe_name=$(sanitize_domain "${domain}")
    # Truncate to fit MariaDB's 32-char username limit
    local db_name="wp_${safe_name:0:28}"
    local db_user="${safe_name:0:28}_u"
    local db_pass
    db_pass=$(generate_password)

    local web_root="${WEB_ROOT}/${domain}"

    # 1. Create web root
    log_info "Creating web root: ${web_root}"
    mkdir -p "${web_root}"
    chown www-data:www-data "${web_root}"

    # 2. Provision MariaDB
    log_info "Provisioning database..."
    mariadb_create_site_db "${db_name}" "${db_user}" "${db_pass}"

    # 3. Create Nginx vhost (HTTP)
    log_info "Creating Nginx vhost..."
    nginx_create_vhost "${domain}"

    # 4. Install WP-CLI if needed
    wordpress_install_wpcli

    # 5. Install WordPress
    wordpress_install_site "${domain}" "${web_root}" "${db_name}" "${db_user}" "${db_pass}"

    # 6. Save site state
    site_save_state "${domain}" "${db_name}" "${db_user}" "${db_pass}"

    echo ""
    log_info "Next step: run './lemp.sh site ssl ${domain}' to enable HTTPS."
}

# =============================================================================
# site remove <domain>
# =============================================================================

site_remove() {
    local domain="${1:-}"
    require_root

    if [[ -z "${domain}" ]]; then
        log_error "Usage: ./lemp.sh site remove <domain>"
        exit 1
    fi

    if ! site_exists "${domain}"; then
        log_error "Site '${domain}' not found."
        exit 1
    fi

    site_load_state "${domain}"

    print_header "Removing site: ${domain}"
    log_warn "This will permanently delete:"
    echo "  - Web root  : ${WEB_ROOT}/${domain}"
    echo "  - Database  : ${DB_NAME}"
    echo "  - DB user   : ${DB_USER}"
    echo "  - Nginx vhost"
    echo ""

    confirm "Permanently remove site '${domain}'?" || exit 0

    # Remove Nginx vhost
    nginx_remove_vhost "${domain}"

    # Remove WordPress files
    wordpress_remove_site "${WEB_ROOT}/${domain}"

    # Remove database
    mariadb_remove_site_db "${DB_NAME}" "${DB_USER}"

    # Remove SSL cert (optional)
    if [[ "${SSL_ENABLED}" == "true" ]]; then
        if confirm "Also revoke and delete the Let's Encrypt certificate?"; then
            certbot delete --cert-name "${domain}" --non-interactive 2>/dev/null || true
        fi
    fi

    # Remove Nginx log files
    rm -f "/var/log/nginx/${domain}.access.log" "/var/log/nginx/${domain}.error.log"

    # Remove state file
    rm -f "$(site_state_file "${domain}")"

    log_success "Site '${domain}' fully removed."
}

# =============================================================================
# site ssl <domain>
# =============================================================================

site_ssl() {
    local domain="${1:-}"
    require_root

    if [[ -z "${domain}" ]]; then
        log_error "Usage: ./lemp.sh site ssl <domain>"
        exit 1
    fi

    if ! site_exists "${domain}"; then
        log_error "Site '${domain}' not found. Create it first with 'site create ${domain}'."
        exit 1
    fi

    print_header "SSL: ${domain}"

    # DNS check — more important here
    if ! check_dns "${domain}"; then
        confirm "DNS doesn't seem to point here yet. Try anyway?" || exit 0
    fi

    certbot_provision "${domain}"

    # Update Nginx vhost to full SSL config
    site_load_state "${domain}"
    nginx_create_ssl_vhost "${domain}"

    # Update state
    site_set_ssl_enabled "${domain}"

    log_success "HTTPS enabled for ${domain}."
}

# =============================================================================
# site list
# =============================================================================

site_list() {
    print_header "Managed Sites"

    if [[ ! -d "${SITES_DIR}" ]] || [[ -z "$(ls -A "${SITES_DIR}" 2>/dev/null)" ]]; then
        echo "  No sites configured yet."
        echo ""
        echo "  Create one: ./lemp.sh site create yourdomain.com"
        echo ""
        return 0
    fi

    printf "  %-35s %-8s %-12s %s\n" "DOMAIN" "SSL" "DB" "CREATED"
    printf "  %-35s %-8s %-12s %s\n" "------" "---" "--" "-------"

    for state_file in "${SITES_DIR}"/*.conf; do
        [[ -f "${state_file}" ]] || continue

        # shellcheck disable=SC1090
        source "${state_file}"

        local ssl_label="no"
        [[ "${SSL_ENABLED}" == "true" ]] && ssl_label="yes"

        printf "  %-35s %-8s %-12s %s\n" \
            "${DOMAIN}" \
            "${ssl_label}" \
            "${DB_NAME:0:12}" \
            "${CREATED_AT}"
    done

    echo ""
}

# =============================================================================
# site info <domain>
# =============================================================================

site_info() {
    local domain="${1:-}"

    if [[ -z "${domain}" ]]; then
        log_error "Usage: ./lemp.sh site info <domain>"
        exit 1
    fi

    if ! site_exists "${domain}"; then
        log_error "Site '${domain}' not found."
        exit 1
    fi

    site_load_state "${domain}"

    print_header "Site info: ${domain}"
    status_line "Domain"    "${DOMAIN}"
    status_line "Web root"  "${WEB_ROOT}/${DOMAIN}"
    status_line "Admin URL" "https://${DOMAIN}/wp-admin/"
    status_line "SSL"       "${SSL_ENABLED}"
    status_line "DB name"   "${DB_NAME}"
    status_line "DB user"   "${DB_USER}"
    status_line "DB pass"   "${DB_PASS}"
    status_line "Created"   "${CREATED_AT}"

    echo ""
    echo "  Nginx vhost : /etc/nginx/sites-available/${DOMAIN}"
    echo "  Access log  : /var/log/nginx/${DOMAIN}.access.log"
    echo "  Error log   : /var/log/nginx/${DOMAIN}.error.log"
    echo ""
}
