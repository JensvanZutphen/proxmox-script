#!/bin/bash
# ZFS Snapshot Cleanup Automation
# This script removes old automated ZFS snapshots based on retention settings

set -euo pipefail

# Source utilities and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTILS_FILE="$SCRIPT_DIR/../lib/utils.sh"
NOTIFICATIONS_FILE="$SCRIPT_DIR/../lib/notifications.sh"

if [ -f "$UTILS_FILE" ]; then
    source "$UTILS_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Required file $UTILS_FILE not found." >&2
    exit 1
fi

if [ -f "$NOTIFICATIONS_FILE" ]; then
    source "$NOTIFICATIONS_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Required file $NOTIFICATIONS_FILE not found." >&2
    exit 1
fi
source "/etc/proxmox-health/automation.conf"

# --- Configuration ---
DEFAULT_RETENTION_DAYS=30
DEFAULT_SNAPSHOT_PATTERN="@auto-[0-9]{4}-[0-9]{2}-[0-9]{2}"

# --- Functions ---
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >&2
}

log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

log_debug() {
    if [ "${AUTOMATION_LOG_LEVEL:-INFO}" = "DEBUG" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >&2
    fi
}

send_automation_notification() {
    local message="$1"
    local level="${2:-info}"

    # Check if notifications are enabled for this level
    if [ "$level" = "info" ] && [ "$AUTOMATION_NOTIFY_ON_SUCCESS" != "yes" ]; then
        return 0
    fi

    if [ "$level" = "error" ] || [ "$level" = "critical" ]; then
        if [ "$AUTOMATION_NOTIFY_ON_FAILURE" != "critical" ] && [ "$AUTOMATION_NOTIFY_ON_FAILURE" != "warning" ]; then
            return 0
        fi
    fi

    send_notification "$message" "$level" "automation"
}

check_dependencies() {
    if ! command -v zfs >/dev/null 2>&1; then
        log_error "ZFS command not found. Please install ZFS utilities."
        return 1
    fi
    return 0
}

find_old_snapshots() {
    local retention_days="$1"
    local snapshot_pattern="${2:-$DEFAULT_SNAPSHOT_PATTERN}"

    log_debug "Searching for snapshots older than $retention days with pattern: $snapshot_pattern"

    # Find all snapshots that match the auto pattern
    zfs list -t snapshot -o name -H | grep -E "$snapshot_pattern" | while read -r snapshot; do
        local snapshot_date
        snapshot_date=$(echo "$snapshot" | sed -E 's/.*@auto-([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/')

        if [ -n "$snapshot_date" ]; then
            local snapshot_epoch
            snapshot_epoch=$(date -d "$snapshot_date" +%s 2>/dev/null || echo 0)
            local cutoff_epoch
            cutoff_epoch=$(date -d "$retention_days days ago" +%s)

            if [ "$snapshot_epoch" -lt "$cutoff_epoch" ]; then
                echo "$snapshot"
            fi
        fi
    done
}

remove_snapshot() {
    local snapshot="$1"
    local dry_run="$2"

    if [ "$dry_run" = "yes" ]; then
        log_info "[DRY RUN] Would remove snapshot: $snapshot"
        return 0
    fi

    log_info "Removing snapshot: $snapshot"
    if zfs destroy "$snapshot" 2>/dev/null; then
        log_debug "Successfully removed snapshot: $snapshot"
        return 0
    else
        log_warning "Failed to remove snapshot: $snapshot"
        return 1
    fi
}

cleanup_snapshots() {
    local retention_days="$1"
    local dry_run="$2"

    log_info "Starting ZFS snapshot cleanup (retention: $retention_days days, dry run: $dry_run)"

    # Send start notification
    local start_message="ZFS snapshot cleanup started (retention: $retention_days days)"
    if [ "$dry_run" = "yes" ]; then
        start_message="$start_message [DRY RUN]"
    fi
    send_automation_notification "$start_message" "info"

    # Check if ZFS is available
    if ! check_dependencies; then
        send_automation_notification "ZFS snapshot cleanup failed: ZFS utilities not found" "error"
        return 1
    fi

    # Find and remove old snapshots
    local removed_count=0
    local failed_count=0
    local total_count=0

    while IFS= read -r snapshot; do
        total_count=$((total_count + 1))
        if remove_snapshot "$snapshot" "$dry_run"; then
            removed_count=$((removed_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
    done < <(find_old_snapshots "$retention_days")

    # Send completion notification
    local result_message="ZFS snapshot cleanup completed."
    result_message="$result_message Total snapshots considered: $total_count"
    result_message="$result_message Removed: $removed_count"

    if [ "$failed_count" -gt 0 ]; then
        result_message="$result_message Failed: $failed_count"
        send_automation_notification "$result_message" "warning"
    else
        result_message="$result_message All snapshots removed successfully."
        send_automation_notification "$result_message" "info"
    fi

    if [ "$dry_run" = "yes" ]; then
        log_info "DRY RUN completed. No snapshots were actually removed."
    fi

    log_info "$result_message"

    return $failed_count
}

show_help() {
    cat << EOF
ZFS Snapshot Cleanup Automation

Usage: $0 [OPTIONS] [RETENTION_DAYS]

Options:
  -h, --help          Show this help message
  -t, --test         Run in test mode (dry run)
  -v, --verbose      Enable verbose logging
  -c, --config FILE  Use specific configuration file

Arguments:
  RETENTION_DAYS     Number of days to retain snapshots (default: $DEFAULT_RETENTION_DAYS)

Examples:
  $0                 # Clean snapshots older than 30 days
  $0 7              # Clean snapshots older than 7 days
  $0 --test         # Show what would be cleaned without actually cleaning
  $0 --test 14      # Test cleaning snapshots older than 14 days

Configuration:
  The script reads configuration from /etc/proxmox-health/automation.conf
  Override retention days by setting AUTOMATION_ZFS_CLEANUP_RETENTION in config.
EOF
}

# --- Main Execution ---
main() {
    local retention_days="${1:-${AUTOMATION_ZFS_CLEANUP_RETENTION:-$DEFAULT_RETENTION_DAYS}}"
    local dry_run="no"
    local verbose="no"

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -t|--test)
                dry_run="yes"
                shift
                ;;
            -v|--verbose)
                verbose="yes"
                AUTOMATION_LOG_LEVEL="DEBUG"
                shift
                ;;
            -c|--config)
                shift
                source "$1"
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    retention_days="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate retention days
    if ! [[ "$retention_days" =~ ^[0-9]+$ ]] || [ "$retention_days" -lt 1 ]; then
        log_error "Invalid retention days: $retention_days. Must be a positive integer."
        exit 1
    fi

    # Enable verbose logging if requested
    if [ "$verbose" = "yes" ]; then
        AUTOMATION_LOG_LEVEL="DEBUG"
    fi

    log_info "Starting ZFS snapshot cleanup automation"
    log_debug "Configuration: retention_days=$retention_days, dry_run=$dry_run, log_level=${AUTOMATION_LOG_LEVEL:-INFO}"

    # Perform cleanup
    cleanup_snapshots "$retention_days" "$dry_run"
    local exit_code=$?

    log_info "ZFS snapshot cleanup automation completed with exit code: $exit_code"
    exit $exit_code
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi