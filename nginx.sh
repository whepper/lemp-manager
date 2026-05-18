#!/usr/bin/env bash
# modules/nginx.sh — Nginx module for lemp-manager

NGINX_PACKAGES=(nginx)

module_install_nginx() {
    log_info "Installing Nginx..."

    apt-get update -qq
    pkg_install "${NGINX_PACKAGES[@]}"

    # Write global performance + security config
    _nginx_write_global_conf

    # Remove default site
    rm -f /etc/nginx/sites-enabled/default

    service_enable_start nginx
    log_info "Nginx installed."
}

module_remove_nginx() {
    log_info "Removing Nginx..."
    systemctl stop nginx 2>/dev/null || true
    pkg_remove "${NGINX_PACKAGES[@]}"
    rm -rf /etc/nginx
    log_success "Nginx removed."
}

module_upgrade_nginx() {
    log_info "Upgrading Nginx..."
    pkg_install "${NGINX_PACKAGES[@]}"
    service_reload nginx
}

module_status_nginx() {
    print_header "Nginx"
    local state
    state=$(service_status nginx)

    if [[ "${state}" == "active" ]]; then
        status_line "Service" "${state}" green
    else
        status_line "Service" "${state}" red
    fi

    if command -v nginx &>/dev/null; then
        local version
        version=$(nginx -v 2>&1 | grep -oP 'nginx/\K[\d.]+' || echo "unknown")
        status_line "Version" "${version}"
    else
        status_line "Version" "not installed" red
    fi

    local site_count=0
    if [[ -d /etc/nginx/sites-enabled ]]; then
        site_count=$(find /etc/nginx/sites-enabled -maxdepth 1 -type l | wc -l)
    fi
    status_line "Active vhosts" "${site_count}"
    status_line "Config dir" "/etc/nginx/"
    echo ""
}

# =============================================================================
# Vhost management (called by site.sh)
# =============================================================================

nginx_create_vhost() {
    local domain="$1"
    local web_root="${WEB_ROOT}/${domain}"

    local vhost_file="/etc/nginx/sites-available/${domain}"

    cat > "${vhost_file}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};

    root ${web_root};
    index index.php index.html;

    # Logging
    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    # WordPress permalinks
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # Block access to sensitive files
    location ~ /\.(ht|git|env) {
        deny all;
    }

    location = /xmlrpc.php {
        deny all;
    }

    # PHP-FPM
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    # Static file caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        log_not_found off;
    }

    # WordPress: don't log favicon/robots
    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { log_not_found off; access_log off; allow all; }

    # Increase upload size (sync with PHP)
    client_max_body_size 64M;
}
EOF

    ln -sf "${vhost_file}" "/etc/nginx/sites-enabled/${domain}"
    nginx -t && service_reload nginx
    log_info "Nginx vhost created for ${domain}."
}

nginx_create_ssl_vhost() {
    local domain="$1"
    local web_root="${WEB_ROOT}/${domain}"
    local vhost_file="/etc/nginx/sites-available/${domain}"

    cat > "${vhost_file}" <<EOF
# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain} www.${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    root ${web_root};
    index index.php index.html;

    # Logging
    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # WordPress permalinks
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # Block access to sensitive files
    location ~ /\.(ht|git|env) {
        deny all;
    }

    location = /xmlrpc.php {
        deny all;
    }

    # PHP-FPM
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    # Static file caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        log_not_found off;
    }

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { log_not_found off; access_log off; allow all; }

    client_max_body_size 64M;
}
EOF

    nginx -t && service_reload nginx
    log_info "SSL vhost configured for ${domain}."
}

nginx_remove_vhost() {
    local domain="$1"
    rm -f "/etc/nginx/sites-enabled/${domain}"
    rm -f "/etc/nginx/sites-available/${domain}"
    nginx -t && service_reload nginx 2>/dev/null || true
    log_info "Nginx vhost removed for ${domain}."
}

# =============================================================================
# Internal helpers
# =============================================================================

_nginx_write_global_conf() {
    cat > /etc/nginx/conf.d/lemp-manager.conf <<'EOF'
# lemp-manager global tuning

# Performance
sendfile            on;
tcp_nopush          on;
tcp_nodelay         on;
keepalive_timeout   65;
types_hash_max_size 2048;
server_tokens       off;

# Gzip
gzip              on;
gzip_vary         on;
gzip_proxied      any;
gzip_comp_level   6;
gzip_types        text/plain text/css text/xml application/json
                  application/javascript application/rss+xml
                  application/atom+xml image/svg+xml;
EOF
}
