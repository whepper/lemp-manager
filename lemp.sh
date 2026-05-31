#!/usr/bin/env bash
# =============================================================================
# lemp.sh — Modular LEMP stack manager for Debian 13
# Linux · Nginx · MariaDB · PHP
# Usage: ./lemp.sh [command] [options]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
MODULES_DIR="${SCRIPT_DIR}/modules"
STATE_DIR="/var/lib/lemp-manager"
STATE_FILE="${STATE_DIR}/installed.state"
SITES_DIR="${STATE_DIR}/sites"
LOG_FILE="/var/log/lemp-manager.log"
CONFIG_FILE="${SCRIPT_DIR}/lemp.conf"

# Source library functions
source "${LIB_DIR}/core.sh"
source "${LIB_DIR}/ui.sh"

# Require lemp.conf — exit with a helpful message if missing
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: ${CONFIG_FILE} not found."
    echo "Copy the example and edit it before running lemp:"
    echo "  cp ${SCRIPT_DIR}/lemp.conf.example ${CONFIG_FILE}"
    exit 1
fi
source "${CONFIG_FILE}"

# Default config values (overridable in lemp.conf)
PHP_VERSION="${PHP_VERSION:-8.3}"
APACHE_MPM="${APACHE_MPM:-event}"
INSTALL_PHPMYADMIN="${INSTALL_PHPMYADMIN:-false}"
WEB_ROOT="${WEB_ROOT:-/var/www}"

# Available modules (order matters for install/remove)
MODULES=(nginx mariadb php redis certbot firewall cloudflare)

# =============================================================================
# Commands
# =============================================================================

cmd_install() {
    local targets=("${@:-${MODULES[@]}}")
    require_root
    log_info "Starting LEMP installation (targets: ${targets[*]})"

    init_state_dir

    for module in "${targets[@]}"; do
        if is_installed "${module}"; then
            log_warn "Module '${module}' already installed — skipping. Use 'upgrade' to update."
        else
            log_info "Installing module: ${module}"
            load_module "${module}"
            "module_install_${module}"
            mark_installed "${module}"
            log_success "Module '${module}' installed successfully."
        fi
    done

    print_summary
}

cmd_remove() {
    local targets=("${@:-${MODULES[@]}}")
    require_root
    log_warn "Removing: ${targets[*]}"
    confirm "This will remove the selected modules and their data. Continue?" || exit 0

    # Reverse order for clean removal
    local reversed=()
    for (( i=${#targets[@]}-1; i>=0; i-- )); do
        reversed+=("${targets[$i]}")
    done

    for module in "${reversed[@]}"; do
        if ! is_installed "${module}"; then
            log_warn "Module '${module}' not installed — skipping."
        else
            load_module "${module}"
            "module_remove_${module}"
            mark_uninstalled "${module}"
            log_success "Module '${module}' removed."
        fi
    done
}

cmd_status() {
    print_header "LEMP Stack Status"
    for module in "${MODULES[@]}"; do
        load_module "${module}"
        "module_status_${module}"
    done
}

cmd_upgrade() {
    local targets=("${@:-${MODULES[@]}}")
    require_root
    log_info "Upgrading: ${targets[*]}"

    apt-get update -qq

    for module in "${targets[@]}"; do
        if ! is_installed "${module}"; then
            log_warn "Module '${module}' not installed — skipping upgrade."
        else
            load_module "${module}"
            "module_upgrade_${module}"
            log_success "Module '${module}' upgraded."
        fi
    done
}

cmd_site() {
    local subcommand="${1:-help}"
    shift || true

    source "${SCRIPT_DIR}/site.sh"

    case "${subcommand}" in
        create) site_create "$@" ;;
        remove) site_remove "$@" ;;
        list)   site_list        ;;
        ssl)    site_ssl "$@"    ;;
        info)   site_info "$@"   ;;
        *)
            echo ""
            echo "Usage: ./lemp.sh site <subcommand> [domain]"
            echo ""
            echo "Subcommands:"
            echo "  create <domain>   Full WordPress install for domain"
            echo "  remove <domain>   Remove site, DB, and files"
            echo "  list              List all managed sites"
            echo "  ssl    <domain>   Provision Let's Encrypt certificate"
            echo "  info   <domain>   Show site details"
            echo ""
            ;;
    esac
}

cmd_php() {
    local subcommand="${1:-help}"
    shift || true

    load_module "php"

    case "${subcommand}" in
        switch)
            require_root
            if [[ -z "${1:-}" ]]; then
                log_error "Usage: ./lemp.sh php switch <version>"
                exit 1
            fi
            php_switch "$1"
            ;;
        *)
            echo ""
            echo "Usage: ./lemp.sh php <subcommand>"
            echo ""
            echo "Subcommands:"
            echo "  switch <version>   Switch the active PHP-FPM version (e.g. 8.5)"
            echo ""
            ;;
    esac
}

cmd_config() {
    print_header "Current Configuration"
    cat <<EOF
  PHP Version       : ${PHP_VERSION}
  Web root          : ${WEB_ROOT}
  Install phpMyAdmin: ${INSTALL_PHPMYADMIN}
  Config file       : ${CONFIG_FILE}
  State directory   : ${STATE_DIR}
  Sites directory   : ${SITES_DIR}
  Log file          : ${LOG_FILE}
EOF
    echo ""
    log_info "Edit ${CONFIG_FILE} to override defaults."
}

cmd_help() {
    cat <<EOF

$(tput bold 2>/dev/null || true)LEMP Manager — Modular WordPress stack for Debian 13$(tput sgr0 2>/dev/null || true)
Linux · Nginx · MariaDB · PHP

Usage:
  ./lemp.sh <command> [modules/options...]

Stack commands:
  install  [module...]   Install all or specific modules
  remove   [module...]   Remove all or specific modules
  upgrade  [module...]   Upgrade all or specific modules
  status                 Show status of all components
  config                 Show current configuration

Site commands:
  site create <domain>   Full WordPress install
  site remove <domain>   Remove site, DB, and files
  site list              List all managed sites
  site ssl    <domain>   Provision Let's Encrypt SSL
  site info   <domain>   Show site details

PHP commands:
  php switch <version>   Switch active PHP-FPM version (e.g. 8.5)
                         Mirrors installed extensions, rewrites all nginx
                         vhosts, updates lemp.conf, reloads nginx.

Modules:
  nginx, mariadb, php, redis, certbot, firewall
  cloudflare  (optional; auto-activated by nginx when BEHIND_PROXY=true)

Examples:
  ./lemp.sh install
  ./lemp.sh site create example.com
  ./lemp.sh site ssl example.com
  ./lemp.sh site list
  ./lemp.sh upgrade php
  ./lemp.sh php switch 8.5

EOF
}

# =============================================================================
# Main dispatcher
# =============================================================================

main() {
    setup_logging

    local command="${1:-help}"
    shift || true

    case "${command}" in
        install)        cmd_install "$@"  ;;
        remove)         cmd_remove "$@"   ;;
        upgrade)        cmd_upgrade "$@"  ;;
        status)         cmd_status        ;;
        site)           cmd_site "$@"     ;;
        php)            cmd_php "$@"      ;;
        config)         cmd_config        ;;
        help|--help|-h) cmd_help          ;;
        *)
            log_error "Unknown command: '${command}'"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
