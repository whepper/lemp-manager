#!/usr/bin/env bash
# modules/redis.sh — Redis module for lemp-manager

REDIS_PACKAGES=(redis-server)
REDIS_SERVICE="redis-server"

module_install_redis() {
    log_info "Installing Redis..."

    apt-get update -qq
    pkg_install "${REDIS_PACKAGES[@]}"

    _redis_configure

    service_enable_start "${REDIS_SERVICE}"
    log_info "Redis installed (Unix socket: /run/redis/redis.sock)."
}

module_remove_redis() {
    log_info "Removing Redis..."
    systemctl stop "${REDIS_SERVICE}" 2>/dev/null || true
    pkg_remove "${REDIS_PACKAGES[@]}"
    rm -rf /etc/redis
    log_success "Redis removed."
}

module_upgrade_redis() {
    log_info "Upgrading Redis..."
    pkg_install "${REDIS_PACKAGES[@]}"
    service_restart "${REDIS_SERVICE}"
}

module_status_redis() {
    print_header "Redis"
    local state
    state=$(service_status "${REDIS_SERVICE}")

    if [[ "${state}" == "active" ]]; then
        status_line "Service" "${state}" green
    else
        status_line "Service" "${state}" red
    fi

    if command -v redis-cli &>/dev/null && [[ "${state}" == "active" ]]; then
        local version
        version=$(redis-cli -s /run/redis/redis.sock INFO server 2>/dev/null | grep redis_version | cut -d: -f2 | tr -d '[:space:]' || echo "unknown")
        status_line "Version" "${version}"

        local used_mem
        used_mem=$(redis-cli -s /run/redis/redis.sock INFO memory 2>/dev/null | grep used_memory_human | cut -d: -f2 | tr -d '[:space:]' || echo "?")
        status_line "Memory used" "${used_mem}"
    else
        status_line "Version" "not installed" red
    fi

    status_line "Socket" "/run/redis/redis.sock"
    status_line "Max memory" "128M (allkeys-lru)"
    echo ""
}

# =============================================================================
# Internal helpers
# =============================================================================

_redis_configure() {
    local conf="/etc/redis/redis.conf"

    # Switch from TCP to Unix socket (more secure, faster for local PHP)
    sed -i 's/^port 6379/port 0/' "${conf}"
    sed -i 's|^# unixsocket .*|unixsocket /run/redis/redis.sock|' "${conf}"
    sed -i 's/^# unixsocketperm .*/unixsocketperm 770/' "${conf}"

    # Memory limits — safe for personal low-traffic sites
    sed -i 's/^# maxmemory .*/maxmemory 128mb/' "${conf}"
    sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' "${conf}"

    # Add www-data to redis group so PHP-FPM can access the socket
    usermod -aG redis www-data 2>/dev/null || true

    service_restart "${REDIS_SERVICE}" 2>/dev/null || true
}
