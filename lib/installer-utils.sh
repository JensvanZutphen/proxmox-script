#!/bin/bash
# Helper functions for installer input validation.

# shellcheck disable=SC2317
if [[ -n "${INSTALLER_UTILS_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
INSTALLER_UTILS_SOURCED=1

is_positive_integer() {
    local value="${1-}"
    [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

sanitize_host_target() {
    local host="${1-}"
    host=$(printf '%s' "$host" | tr -d '[:space:]')
    host=$(printf '%s' "$host" | tr -d "\"'")
    printf '%s' "$host"
}

is_valid_host_target() {
    local host="${1-}"
    [[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]]
}

sanitize_bridge_list() {
    local input="${1-}"
    local bridges=""
    bridges=$(printf '%s' "$input" | tr ',' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    bridges=$(printf '%s' "$bridges" | tr -d "\"'")
    printf '%s' "$bridges"
}

is_valid_bridge_list() {
    local list="${1-}"
    local bridge=""
    for bridge in $list; do
        [[ "$bridge" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
    done
    return 0
}

is_valid_time_24h() {
    local value="${1-}"
    [[ "$value" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]
}
