#!/usr/bin/env bash
# modules/mariadb.sh — MariaDB module for lemp-manager

MARIADB_PACKAGES=(mariadb-server mariadb-client)
MARIADB_SERVICE="mariadb"

module_install_mariadb() {
    log_info "Installing MariaDB..."

    apt-get update -qq
    pkg_install "${MARIADB_PACKAGES[@]}"

    service_enable_start "${MARIADB_SERVICE}"

    _mariadb_secure_install
    _mariadb_tune

    log_info "MariaDB installed. Connect: mariadb -u root"
}

module_remove_mariadb() {
    log_warn "This will delete ALL databases and data!"
    confirm "Really remove MariaDB and all data?" || return 0

    systemctl stop "${MARIADB_SERVICE}" 2>/dev/null || true
    pkg_remove "${MARIADB_PACKAGES[@]}"
    rm -rf /var/lib/mysql /etc/mysql
    log_success "MariaDB removed."
}

module_upgrade_mariadb() {
    log_info "Upgrading MariaDB..."
    pkg_install "${MARIADB_PACKAGES[@]}"
    mariadb-upgrade 2>/dev/null || true
    service_restart "${MARIADB_SERVICE}"
}

module_status_mariadb() {
    print_header "MariaDB"
    local state
    state=$(service_status "${MARIADB_SERVICE}")

    if [[ "${state}" == "active" ]]; then
        status_line "Service" "${state}" green
    else
        status_line "Service" "${state}" red
    fi

    if command -v mariadb &>/dev/null; then
        local version
        version=$(mariadb --version 2>/dev/null | grep -oP 'Distrib \K[\d.]+' || echo "unknown")
        status_line "Version" "${version}"
    else
        status_line "Version" "not installed" red
    fi

    status_line "Data dir" "/var/lib/mysql"
    status_line "Config dir" "/etc/mysql/"

    # Count databases (excluding system ones)
    if systemctl is-active --quiet "${MARIADB_SERVICE}"; then
        local db_count
        db_count=$(mariadb -u root -se "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys');" 2>/dev/null || echo "?")
        status_line "User databases" "${db_count}"
    fi
    echo ""
}

# =============================================================================
# Per-site DB management (called by site.sh)
# =============================================================================

mariadb_create_site_db() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"

    mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL

    log_info "MariaDB: database '${db_name}' and user '${db_user}' created."
}

mariadb_remove_site_db() {
    local db_name="$1"
    local db_user="$2"

    mariadb -u root <<SQL 2>/dev/null || true
DROP DATABASE IF EXISTS \`${db_name}\`;
DROP USER IF EXISTS '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL

    log_info "MariaDB: database '${db_name}' and user '${db_user}' removed."
}

# =============================================================================
# Internal helpers
# =============================================================================

_mariadb_secure_install() {
    log_info "Applying MariaDB secure defaults..."

    mariadb -u root <<'SQL' 2>/dev/null || true
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

    log_warn "Set a root password: ALTER USER 'root'@'localhost' IDENTIFIED BY 'yourpassword';"
}

_mariadb_tune() {
    local tune_file="/etc/mysql/mariadb.conf.d/99-lemp-manager.cnf"
    cat > "${tune_file}" <<'EOF'
# lemp-manager WordPress tuning
[mysqld]
# InnoDB — set to ~50-70% of total RAM for production
# 256M is fine for personal/low-traffic sites
innodb_buffer_pool_size         = 256M
innodb_buffer_pool_instances    = 1
innodb_log_file_size            = 64M
innodb_flush_log_at_trx_commit  = 2
innodb_flush_method             = O_DIRECT

# Disable query cache (deprecated, bottleneck under WordPress write patterns)
query_cache_type    = 0
query_cache_size    = 0

# Connections
max_connections     = 50
wait_timeout        = 300
interactive_timeout = 300

# Character set
character-set-server  = utf8mb4
collation-server      = utf8mb4_unicode_ci
EOF

    service_restart "${MARIADB_SERVICE}"
    log_info "MariaDB tuning applied."
}
