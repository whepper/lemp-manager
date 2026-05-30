#!/usr/bin/env bash
# lib/ui.sh — Terminal UI helpers

print_header() {
    local title="$1"
    local width=50
    local line
    line=$(printf '%*s' "${width}" '' | tr ' ' '=')
    echo ""
    echo "${line}"
    printf "  %s\n" "${title}"
    echo "${line}"
    echo ""
}

status_line() {
    local label="$1"
    local value="$2"
    local color="${3:-reset}"

    local reset="\033[0m"
    local green="\033[32m"
    local red="\033[31m"
    local yellow="\033[33m"

    local code="${reset}"
    case "${color}" in
        green)  code="${green}" ;;
        red)    code="${red}" ;;
        yellow) code="${yellow}" ;;
    esac

    printf "  %-22s %b%s%b\n" "${label}:" "${code}" "${value}" "${reset}"
}
