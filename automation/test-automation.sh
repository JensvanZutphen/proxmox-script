#!/bin/bash
# Test automation functions end-to-end in safe dry-run mode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

ensure_config_defaults

PASS=0
FAIL=0

run_case() {
    local name="$1"; shift
    echo "[CASE] $name" >&2
    if "$@"; then
        echo "  -> PASS" >&2
        PASS=$((PASS+1))
    else
        local rc=$?
        echo "  -> FAIL (rc=$rc)" >&2
        FAIL=$((FAIL+1))
    fi
}

# Mocks where needed
mock_cmd_if_missing zfs "echo 'mock zfs \$@' >&2; exit 0"
mock_cmd_if_missing apt-get "echo 'mock apt-get \$@' >&2; exit 0"
mock_cmd_if_missing yum "echo 'mock yum \$@' >&2; exit 0"
mock_cmd_if_missing dnf "echo 'mock dnf \$@' >&2; exit 0"

echo "=== Proxmox Automation Test Runner (dry-run) ==="

# ZFS cleanup (dry run)
run_case "ZFS cleanup --test" \
    "$SCRIPT_DIR/zfs-cleanup.sh" --test

# Disk cleanup (dry run)
run_case "Disk cleanup --test" \
    "$SCRIPT_DIR/disk-cleanup.sh" --test 95

# Memory relief (dry run)
run_case "Memory relief --test" \
    "$SCRIPT_DIR/memory-relief.sh" --test 90

# System refresh (exposes --test, do not delete)
if [ -x "$SCRIPT_DIR/system-refresh.sh" ]; then
    run_case "System refresh --test" \
        "$SCRIPT_DIR/system-refresh.sh" --test
fi

# Auto-update (dry run)
run_case "Auto-update --test (security only)" \
    "$SCRIPT_DIR/auto-update.sh" --test --security

echo "=== Results: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -eq 0 ]; then
    exit 0
else
    exit 1
fi


