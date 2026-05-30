#!/usr/bin/env bash
# modules/wordpress.sh — WordPress install helpers via WP-CLI

WPCLI_PATH="/usr/local/bin/wp"

wordpress_install_wpcli() {
    if [[ -f "${WPCLI_PATH}" ]]; then
        log_info "WP-CLI already installed."
        return 0
    fi

    log_info "Installing WP-CLI..."
    curl -sS -o "${WPCLI_PATH}" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x "${WPCLI_PATH}"

    # Verify
    wp --info --allow-root &>/dev/null || {
        log_error "WP-CLI installation failed."
        exit 1
    }

    log_info "WP-CLI installed at ${WPCLI_PATH}."
}

wordpress_install_site() {
    local domain="$1"
    local web_root="$2"
    local db_name="$3"
    local db_user="$4"
    local db_pass="$5"

    # Prompt for site details
    read -rp "  WordPress site title: " wp_title
    read -rp "  Admin username [admin]: " wp_admin
    wp_admin="${wp_admin:-admin}"
    read -rp "  Admin email: " wp_email

    local wp_admin_pass
    wp_admin_pass=$(generate_password)

    local wp_url
    if [[ "${BEHIND_PROXY:-false}" == "true" ]]; then
        wp_url="https://${domain}"
    else
        wp_url="http://${domain}"
    fi

    log_info "Downloading WordPress to ${web_root}..."
    wp core download \
        --path="${web_root}" \
        --allow-root \
        --quiet

    log_info "Creating wp-config.php..."
    wp config create \
        --path="${web_root}" \
        --dbname="${db_name}" \
        --dbuser="${db_user}" \
        --dbpass="${db_pass}" \
        --dbhost="localhost" \
        --dbcharset="utf8mb4" \
        --dbcollate="utf8mb4_unicode_ci" \
        --allow-root \
        --quiet

    # Bake in Redis object cache constants
    wp config set WP_REDIS_SCHEME unix \
        --path="${web_root}" --allow-root --quiet
    wp config set WP_REDIS_PATH /run/redis/redis.sock \
        --path="${web_root}" --allow-root --quiet
    wp config set WP_CACHE true --raw \
        --path="${web_root}" --allow-root --quiet

    # Disable file editing from WP admin (security)
    wp config set DISALLOW_FILE_EDIT true --raw \
        --path="${web_root}" --allow-root --quiet

    # Behind a TLS-terminating proxy (e.g. Cloudflare Tunnel): inject a shim
    # so WordPress sees HTTPS and avoids redirect loops.
    if [[ "${BEHIND_PROXY:-false}" == "true" ]]; then
        log_info "Injecting X-Forwarded-Proto shim into wp-config.php..."
        python3 - "${web_root}/wp-config.php" <<'PYEOF'
import sys
path = sys.argv[1]
shim = (
    "/** X-Forwarded-Proto shim — handles HTTPS behind a reverse proxy */\n"
    "if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && 'https' === $_SERVER['HTTP_X_FORWARDED_PROTO'] ) {\n"
    "    $_SERVER['HTTPS'] = 'on';\n"
    "}\n\n"
)
with open(path, 'r') as f:
    content = f.read()
sentinel = "/* That's all, stop editing!"
content = content.replace(sentinel, shim + sentinel, 1)
with open(path, 'w') as f:
    f.write(content)
PYEOF
    fi

    log_info "Running WordPress install..."
    wp core install \
        --path="${web_root}" \
        --url="${wp_url}" \
        --title="${wp_title}" \
        --admin_user="${wp_admin}" \
        --admin_password="${wp_admin_pass}" \
        --admin_email="${wp_email}" \
        --skip-email \
        --allow-root \
        --quiet

    # Install Redis Object Cache plugin
    log_info "Installing Redis Object Cache plugin..."
    wp plugin install redis-cache \
        --activate \
        --path="${web_root}" \
        --allow-root \
        --quiet

    wp redis enable \
        --path="${web_root}" \
        --allow-root \
        --quiet 2>/dev/null || true

    # Set correct file ownership
    chown -R www-data:www-data "${web_root}"
    find "${web_root}" -type d -exec chmod 755 {} \;
    find "${web_root}" -type f -exec chmod 644 {} \;
    # wp-config.php should be more restrictive
    chmod 640 "${web_root}/wp-config.php"

    # Print credentials
    echo ""
    log_success "================================================="
    log_success " WordPress installed: ${domain}"
    log_success "================================================="
    echo ""
    echo "  URL          : ${wp_url}"
    echo "  Admin URL    : ${wp_url}/wp-admin/"
    echo "  Admin user   : ${wp_admin}"
    echo "  Admin pass   : ${wp_admin_pass}"
    echo ""
    echo "  DB name      : ${db_name}"
    echo "  DB user      : ${db_user}"
    echo "  DB pass      : ${db_pass}"
    echo ""
    log_warn "Save these credentials — they won't be shown again."
    echo ""
}

wordpress_remove_site() {
    local web_root="$1"
    log_warn "Deleting web root: ${web_root}"
    rm -rf "${web_root}"
    log_info "WordPress files removed."
}
