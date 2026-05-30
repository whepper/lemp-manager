#!/usr/bin/env bash
# lib/core.sh — Core utilities for lemp-manager

# =============================================================================
# Logging
# =============================================================================

setup_logging() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    exec > >(tee -a "${LOG_FILE}") 2>&1
}

log_info()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
log_warn()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" >&2; }
log_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }
log_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK]    $*"; }

# =============================================================================
# Guards
# =============================================================================

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

confirm() {
    local prompt="${1:-Are you sure?}"
    read -rp "${prompt} [y/N] " response
    [[ "${response}" =~ ^[Yy]$ ]]
}

# =============================================================================
# State management
# =============================================================================

init_state_dir() {
    mkdir -p "${STATE_DIR}" "${SITES_DIR}"
    touch "${STATE_FILE}"
}

is_installed() {
    local module="$1"
    grep -qx "${module}" "${STATE_FILE}" 2>/dev/null
}

mark_installed() {
    local module="$1"
    echo "${module}" >> "${STATE_FILE}"
}

mark_uninstalled() {
    local module="$1"
    sed -i "/^${module}$/d" "${STATE_FILE}"
}

# =============================================================================
# Site state
# =============================================================================

site_state_file() {
    local domain="$1"
    echo "${SITES_DIR}/${domain}.conf"
}

site_exists() {
    local domain="$1"
    [[ -f "$(site_state_file "${domain}")" ]]
}

site_save_state() {
    local domain="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local web_root="${WEB_ROOT}/${domain}"
    local created_at
    created_at=$(date '+%Y-%m-%d %H:%M:%S')

    cat > "$(site_state_file "${domain}")" <<EOF
DOMAIN="${domain}"
DB_NAME="${db_name}"
DB_USER="${db_user}"
DB_PASS="${db_pass}"
WEB_ROOT="${web_root}"
CREATED_AT="${created_at}"
SSL_ENABLED="false"
EOF
}

site_load_state() {
    local domain="$1"
    local state_file
    state_file="$(site_state_file "${domain}")"

    if [[ ! -f "${state_file}" ]]; then
        log_error "Site '${domain}' not found."
        exit 1
    fi

    # shellcheck disable=SC1090
    source "${state_file}"
}

site_set_ssl_enabled() {
    local domain="$1"
    local state_file
    state_file="$(site_state_file "${domain}")"
    sed -i 's/SSL_ENABLED="false"/SSL_ENABLED="true"/' "${state_file}"
}

# =============================================================================
# Module loader
# =============================================================================

load_module() {
    local module="$1"
    local module_file="${MODULES_DIR}/${module}.sh"

    if [[ ! -f "${module_file}" ]]; then
        log_error "Module not found: ${module_file}"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "${module_file}"
}

# =============================================================================
# Package helpers
# =============================================================================

pkg_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

pkg_remove() {
    apt-get purge -y "$@" 2>/dev/null || true
    apt-get autoremove -y
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

service_enable_start() {
    systemctl enable --now "$1"
}

service_restart() {
    systemctl restart "$1"
}

service_reload() {
    systemctl reload "$1"
}

service_status() {
    systemctl is-active "$1" 2>/dev/null || echo "inactive"
}

# =============================================================================
# Helpers
# =============================================================================

generate_password() {
    tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 24; true;
}

sanitize_domain() {
    # Convert domain to safe identifier: example.com → example_com
    echo "$1" | tr '.' '_' | tr '-' '_'
}

check_dns() {
    local domain="$1"
    local server_ip
    server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")
    local domain_ip
    domain_ip=$(dig +short "${domain}" A 2>/dev/null | tail -1 || echo "")

    if [[ -z "${domain_ip}" ]]; then
        log_warn "DNS: No A record found for '${domain}'. SSL provisioning will fail until DNS is set."
        return 1
    elif [[ "${domain_ip}" != "${server_ip}" ]]; then
        log_warn "DNS: '${domain}' resolves to ${domain_ip}, but this server's IP appears to be ${server_ip}."
        log_warn "SSL provisioning may fail. Continuing anyway."
        return 1
    else
        log_info "DNS: '${domain}' correctly resolves to ${server_ip}."
        return 0
    fi
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    echo ""
    log_success "=========================================="
    log_success " LEMP stack installation complete!"
    log_success "=========================================="
    echo ""
    echo "  Nginx cfg : /etc/nginx/"
    echo "  PHP cfg   : /etc/php/${PHP_VERSION}/"
    echo "  MariaDB   : /var/lib/mysql/"
    echo "  Web root  : ${WEB_ROOT}/"
    echo ""
    echo "  Next step : ./lemp.sh site create yourdomain.com"
    echo ""
}
