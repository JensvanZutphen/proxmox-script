#!/bin/bash
# Automation smoke tests

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail outputs a failure message to stderr and exits the script with status 1.
fail() { echo "FAIL: $*" >&2; exit 1; }

# expect_success runs the provided command and exits with a standardized failure message if the command returns a non-zero status.
expect_success() {
    if ! "$@"; then
        fail "Expected success for: $*"
    fi
}

# Ensure scripts are executable
chmod +x "$REPO_ROOT/automation/"*.sh

# Run dry-run tests to avoid system modifications
expect_success "$REPO_ROOT/automation/zfs-cleanup.sh" --test
expect_success "$REPO_ROOT/automation/disk-cleanup.sh" --test 95
expect_success "$REPO_ROOT/automation/memory-relief.sh" --test 90
expect_success "$REPO_ROOT/automation/system-refresh.sh" --test
expect_success "$REPO_ROOT/automation/auto-update.sh" --test --security

echo "Automation tests passed."


