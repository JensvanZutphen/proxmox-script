#!/bin/bash
# Validation smoke tests for installer helper functions
# shellcheck disable=SC1091
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/lib/installer-utils.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

expect_success() {
    if ! "$@"; then
        fail "Expected success for: $*"
    fi
}

expect_failure() {
    if "$@"; then
        fail "Expected failure for: $*"
    fi
}

# Positive integer validator
expect_success is_positive_integer 1
expect_success is_positive_integer 45
expect_failure is_positive_integer 0
expect_failure is_positive_integer "-5"

# Host target sanitization and validation
sanitized_host=$(sanitize_host_target "  example-host ")
[ "$sanitized_host" = "example-host" ] || fail "sanitize_host_target trimming failed"
expect_success is_valid_host_target "$sanitized_host"
expect_success is_valid_host_target "2001:db8::1"
expect_failure is_valid_host_target "bad host"

# Bridge list sanitization and validation
sanitized_bridges=$(sanitize_bridge_list " vmbr0,vmbr1 test ")
[ "$sanitized_bridges" = "vmbr0 vmbr1 test" ] || fail "sanitize_bridge_list failed"
expect_success is_valid_bridge_list "$sanitized_bridges"
expect_failure is_valid_bridge_list "vmbr0 bad!bridge"

# Time validator
expect_success is_valid_time_24h "00:00"
expect_success is_valid_time_24h "23:45"
expect_success is_valid_time_24h "7:05"
expect_failure is_valid_time_24h "24:00"
expect_failure is_valid_time_24h "9:5"

# Ensure summary time padding helper path works
summary_input="7:05"
if is_valid_time_24h "07:05" && [ "$summary_input" != "" ]; then
    padded="$(printf '%02d:%02d' "${summary_input%:*}" "${summary_input#*:}")"
    [ "$padded" = "07:05" ] || fail "Summary time padding failed"
fi

echo "Validation helper tests passed."
