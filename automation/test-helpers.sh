#!/bin/bash
# Automation Test Helpers
# Shared helpers for testing automation scripts safely

set -euo pipefail

# Resolve repo root if available
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load shared libs if present on dev machine
if [ -d "$REPO_ROOT/lib" ]; then
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/utils.sh"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/notifications.sh"
fi

TEST_TMP_DIR="${TEST_TMP_DIR:-/tmp/proxmox-automation-tests}"
mkdir -p "$TEST_TMP_DIR"

# log_test writes its arguments as a test-prefixed message to stderr, prefixing the output with "[TEST]".
log_test() {
    echo "[TEST] $*" >&2
}

# require_root_or_dry_run checks that the current user is root or that dry-run mode is enabled; if not, it prints an error to stderr and returns a non-zero status.
# The optional first argument should be "yes" to allow non-root execution (dry-run).
require_root_or_dry_run() {
    local dry_run_flag="${1:-no}"
    if [ "$(id -u)" -ne 0 ] && [ "$dry_run_flag" != "yes" ]; then
        echo "This test requires root privileges or must be run in --test (dry run) mode." >&2
        return 1
    fi
}

# mock_cmd_if_missing creates an executable mock script for a missing command in TEST_TMP_DIR and prepends TEST_TMP_DIR to PATH.
# The first argument is the command name; any additional arguments are written as the body of the mock script.
mock_cmd_if_missing() {
    local cmd="$1"; shift || true
    local mock_body="$*"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        local mock_path="$TEST_TMP_DIR/$cmd"
        cat > "$mock_path" << EOF
#!/bin/bash
$mock_body
EOF
        chmod +x "$mock_path"
        export PATH="$TEST_TMP_DIR:$PATH"
        log_test "Mocked missing command: $cmd -> $mock_path"
    fi
}

# ensure_config_defaults creates a minimal automation config at /etc/proxmox-health/automation.conf if it does not already exist.
# It is idempotent: attempts to create the directory with sudo and writes default AUTOMATION_* settings to the config file when missing.
ensure_config_defaults() {
    # Create a minimal automation config if not present
    local cfg="/etc/proxmox-health/automation.conf"
    if [ ! -f "$cfg" ]; then
        sudo mkdir -p /etc/proxmox-health 2>/dev/null || true
        sudo tee "$cfg" >/dev/null << 'EOF'
AUTOMATION_ENABLED="yes"
AUTOMATION_LOG_LEVEL="DEBUG"
AUTOMATION_NOTIFY_ON_SUCCESS="no"
AUTOMATION_NOTIFY_ON_FAILURE="critical"
AUTOMATION_ZFS_CLEANUP_ENABLED="no"
AUTOMATION_ZFS_CLEANUP_SCHEDULE="0 2 * * 0"
AUTOMATION_ZFS_CLEANUP_RETENTION="30"
AUTOMATION_DISK_CLEANUP_ENABLED="no"
AUTOMATION_DISK_CLEANUP_SCHEDULE="0 * * * *"
AUTOMATION_DISK_CLEANUP_THRESHOLD="95"
AUTOMATION_MEMORY_RELIEF_ENABLED="no"
AUTOMATION_MEMORY_RELIEF_SCHEDULE="*/15 * * * *"
AUTOMATION_MEMORY_RELIEF_THRESHOLD="90"
AUTOMATION_SYSTEM_REFRESH_ENABLED="no"
AUTOMATION_SYSTEM_REFRESH_SCHEDULE="0 4 * * *"
AUTOMATION_AUTO_UPDATE_ENABLED="no"
AUTOMATION_AUTO_UPDATE_SCHEDULE="0 3 * * 0"
AUTOMATION_AUTO_UPDATE_SECURITY_ONLY="yes"
EOF
        log_test "Wrote default automation config to $cfg"
    fi
}

# cleanup_test_artifacts removes the TEST_TMP_DIR directory and its contents, suppressing errors; safe to call during exit/cleanup.
cleanup_test_artifacts() {
    rm -rf "$TEST_TMP_DIR" 2>/dev/null || true
}

trap cleanup_test_artifacts EXIT


