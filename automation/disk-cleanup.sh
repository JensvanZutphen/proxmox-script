#!/bin/bash
# Emergency Disk Cleanup Automation
# This script performs emergency cleanup when disk space exceeds threshold

set -euo pipefail

# Source utilities and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/notifications.sh"
source "/etc/proxmox-health/automation.conf"

# --- Configuration ---
DEFAULT_THRESHOLD=95
DEFAULT_MIN_FREE_SPACE_GB=5
DEFAULT_CLEANUP_DIRS=("/tmp" "/var/tmp" "/var/log" "/var/cache/apt/archives")

# log_info writes an informational, timestamped message to stderr; the first argument is the message.
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >&2
}

# log_warning writes a timestamped WARNING message to stderr using the first argument as the message.
log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1" >&2
}

# log_error writes a timestamped error message to stderr; takes one argument (the message).
log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# log_debug prints a timestamped debug message to stderr when AUTOMATION_LOG_LEVEL is set to "DEBUG".
log_debug() {
    if [ "${AUTOMATION_LOG_LEVEL:-INFO}" = "DEBUG" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >&2
    fi
}

# send_automation_notification sends a notification via `send_notification` with the given message and level (default "info"), gating info messages by AUTOMATION_NOTIFY_ON_SUCCESS and error/critical messages by AUTOMATION_NOTIFY_ON_FAILURE, and tags the notification channel as "automation".
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

# get_disk_usage prints the filesystem usage percentage for the given path (default "/") as an integer with the trailing '%' removed.
get_disk_usage() {
    local path="${1:-/}"
    df "$path" | awk 'NR==2 {gsub("%","",$5); print $5}'
}

# get_disk_free_space returns the available disk space (in kilobytes) for the specified path (defaults to /).
get_disk_free_space() {
    local path="${1:-/}"
    df "$path" | awk 'NR==2 {print $4}'
}

# clean_old_files removes files older than a specified number of days from a directory and echoes the number of files removed (or that would be removed).
# If `dry_run` is "yes" no deletion is performed; instead the function counts and echoes matching files and logs a dry-run message.
clean_old_files() {
    local dir="$1"
    local days="$2"
    local dry_run="$3"
    local cleaned_count=0

    if [ ! -d "$dir" ]; then
        log_debug "Directory not found: $dir"
        return 0
    fi

    log_debug "Cleaning files older than $days days in $dir"

    if [ "$dry_run" = "yes" ]; then
        local count
        count=$(find "$dir" -type f -mtime +"$days" -print 2>/dev/null | wc -l)
        log_info "[DRY RUN] Would remove $count files from $dir (older than $days days)"
        echo "$count"
        return 0
    fi

    # Count files to be deleted
    cleaned_count=$(find "$dir" -type f -mtime +"$days" -print 2>/dev/null | wc -l)

    # Remove the files
    find "$dir" -type f -mtime +"$days" -delete 2>/dev/null

    log_info "Cleaned $cleaned_count files from $dir (older than $days days)"
    echo "$cleaned_count"
}

# clean_old_logs removes compressed/rotated log files under /var/log and echoes the number removed. When called with "yes" as the first argument it performs a dry run and echoes the count it would remove without deleting files.
clean_old_logs() {
    local dry_run="$1"
    local cleaned_count=0

    log_debug "Cleaning old log files"

    if [ "$dry_run" = "yes" ]; then
        local count
        count=$(find /var/log -name "*.gz" -o -name "*.old" -o -name "*.1" -o -name "*.2" | wc -l)
        log_info "[DRY RUN] Would remove $count compressed/rotated log files"
        echo "$count"
        return 0
    fi

    # Remove compressed log files
    cleaned_count=$(find /var/log -name "*.gz" -print -delete 2>/dev/null | wc -l)
    cleaned_count=$((cleaned_count + $(find /var/log -name "*.old" -print -delete 2>/dev/null | wc -l))
    cleaned_count=$((cleaned_count + $(find /var/log -name "*.1" -print -delete 2>/dev/null | wc -l))
    cleaned_count=$((cleaned_count + $(find /var/log -name "*.2" -print -delete 2>/dev/null | wc -l))

    log_info "Cleaned $cleaned_count old log files"
    echo "$cleaned_count"
}

# clean_apt_cache cleans the APT package cache and echoes the approximate freed size in kilobytes.
# When called with "yes" as the first argument (dry run) it only estimates the current size of
# /var/cache/apt/archives and echoes that size (KB) without deleting anything. On systems without
# apt-get available the function echoes "0". On a real run it invokes `apt-get clean`, parses the
# command output for the reported freed size (KB) and echoes that value (or "0" if none found).
clean_apt_cache() {
    local dry_run="$1"
    local cleaned_size=0

    log_debug "Cleaning APT cache"

    if [ "$dry_run" = "yes" ]; then
        if command -v apt-get >/dev/null 2>&1; then
            local size
            size=$(du -sk /var/cache/apt/archives 2>/dev/null | cut -f1)
            log_info "[DRY RUN] Would clean APT cache (approximately ${size}KB)"
            echo "$size"
        else
            log_debug "APT not available, skipping cache cleanup"
            echo "0"
        fi
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        local before after
        before=$(du -sk /var/cache/apt/archives 2>/dev/null | awk '{print $1}')
        apt-get clean >/dev/null 2>&1 || true
        after=$(du -sk /var/cache/apt/archives 2>/dev/null | awk '{print $1}')
        cleaned_size=$(( before - after ))
        [ "$cleaned_size" -lt 0 ] && cleaned_size=0
        log_info "Cleaned APT cache: ${cleaned_size}KB"
        echo "$cleaned_size"
    else
        log_debug "APT not available, skipping cache cleanup"
        echo "0"
    fi
}

# perform_emergency_cleanup checks root disk usage against a threshold and, if needed, performs (or simulates) emergency cleanup, then reports the results.
# 
# When usage is at or above the provided threshold or free space is below DEFAULT_MIN_FREE_SPACE_GB, this function notifies, runs cleanup actions (old files in DEFAULT_CLEANUP_DIRS with per-directory age policies, rotated/compressed logs, and APT cache), rechecks disk state, and sends a completion notification. The first argument is the threshold percentage (1–100); the second is a dry-run flag ("yes" to only simulate, otherwise perform deletions).
perform_emergency_cleanup() {
    local threshold="$1"
    local dry_run="$2"

    log_info "Checking disk space (threshold: ${threshold}%, dry run: $dry_run)"

    # Get current disk usage
    local usage
    usage=$(get_disk_usage "/")
    local free_space_kb
    free_space_kb=$(get_disk_free_space "/")
    local free_space_gb
    free_space_gb=$((free_space_kb / 1024 / 1024))

    log_info "Current disk usage: ${usage}%, Free space: ${free_space_gb}GB"

    # Check if cleanup is needed
    if [ "$usage" -lt "$threshold" ] && [ "$free_space_gb" -ge "$DEFAULT_MIN_FREE_SPACE_GB" ]; then
        log_info "Disk space is within acceptable limits. No cleanup needed."
        send_automation_notification "Disk space check completed. Usage: ${usage}%, Free: ${free_space_gb}GB" "info"
        return 0
    fi

    # Send alert notification
    local alert_message="Emergency disk cleanup initiated! Usage: ${usage}% (threshold: ${threshold}%), Free: ${free_space_gb}GB"
    if [ "$dry_run" = "yes" ]; then
        alert_message="$alert_message [DRY RUN]"
    fi
    send_automation_notification "$alert_message" "warning"

    # Perform cleanup operations
    local total_cleaned_files=0
    local total_cleaned_size=0

    # Clean old files from standard directories
    for dir in "${DEFAULT_CLEANUP_DIRS[@]}"; do
        local days=7
        case "$dir" in
            "/tmp") days=3 ;;          # Clean temp files older than 3 days
            "/var/tmp") days=7 ;;      # Clean var/tmp older than 7 days
            "/var/log") days=30 ;;     # Clean old logs older than 30 days
            "/var/cache/apt/archives") days=14 ;;  # Clean apt archives older than 14 days
        esac

        local cleaned_files
        cleaned_files=$(clean_old_files "$dir" "$days" "$dry_run")
        total_cleaned_files=$((total_cleaned_files + cleaned_files))
    done

    # Clean old log files
    local cleaned_logs
    cleaned_logs=$(clean_old_logs "$dry_run")
    total_cleaned_files=$((total_cleaned_files + cleaned_logs))

    # Clean APT cache
    local cleaned_apt
    cleaned_apt=$(clean_apt_cache "$dry_run")
    total_cleaned_size=$((total_cleaned_size + cleaned_apt))

    # Get final disk usage
    local final_usage
    final_usage=$(get_disk_usage "/")
    local final_free_kb
    final_free_kb=$(get_disk_free_space "/")
    local final_free_gb
    final_free_gb=$((final_free_kb / 1024 / 1024))

    # Send completion notification
    local result_message="Emergency disk cleanup completed."
    result_message="$result_message Files cleaned: $total_cleaned_files"
    result_message="$result_message Size freed: ${total_cleaned_size}KB"
    result_message="$result_message Disk usage: ${usage}% → ${final_usage}%"
    result_message="$result_message Free space: ${free_space_gb}GB → ${final_free_gb}GB"

    if [ "$dry_run" = "yes" ]; then
        result_message="$result_message [DRY RUN]"
        send_automation_notification "$result_message" "info"
    else
        if [ "$final_usage" -lt "$usage" ]; then
            send_automation_notification "$result_message" "info"
        else
            result_message="$result_message WARNING: Disk usage still high!"
            send_automation_notification "$result_message" "warning"
        fi
    fi

    log_info "$result_message"

    return 0
}

# show_help displays the script usage, available CLI options and examples, and notes that THRESHOLD defaults to $DEFAULT_THRESHOLD and can be overridden via /etc/proxmox-health/automation.conf by setting AUTOMATION_DISK_CLEANUP_THRESHOLD.
show_help() {
    cat << EOF
Emergency Disk Cleanup Automation

Usage: $0 [OPTIONS] [THRESHOLD]

Options:
  -h, --help          Show this help message
  -t, --test         Run in test mode (dry run)
  -v, --verbose      Enable verbose logging
  -c, --config FILE  Use specific configuration file

Arguments:
  THRESHOLD          Disk usage threshold percentage (default: $DEFAULT_THRESHOLD)

Examples:
  $0                 # Check and clean if usage > $DEFAULT_THRESHOLD%
  $0 90             # Check and clean if usage > 90%
  $0 --test         # Show what would be cleaned without actually cleaning
  $0 --test 80      # Test with 80% threshold

Configuration:
  The script reads configuration from /etc/proxmox-health/automation.conf
  Override threshold by setting AUTOMATION_DISK_CLEANUP_THRESHOLD in config.
EOF
}

# main parses command-line options (help, test/dry-run, verbose, config, or numeric threshold), validates the threshold (1–100), configures logging and dry-run flags, invokes perform_emergency_cleanup, and exits with its return code.
main() {
    local threshold="${1:-${AUTOMATION_DISK_CLEANUP_THRESHOLD:-$DEFAULT_THRESHOLD}}"
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
                    threshold="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate threshold
    if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -lt 1 ] || [ "$threshold" -gt 100 ]; then
        log_error "Invalid threshold: $threshold. Must be between 1 and 100."
        exit 1
    fi

    # Enable verbose logging if requested
    if [ "$verbose" = "yes" ]; then
        AUTOMATION_LOG_LEVEL="DEBUG"
    fi

    log_info "Starting emergency disk cleanup automation"
    log_debug "Configuration: threshold=$threshold, dry_run=$dry_run, log_level=${AUTOMATION_LOG_LEVEL:-INFO}"

    # Perform cleanup
    perform_emergency_cleanup "$threshold" "$dry_run"
    local exit_code=$?

    log_info "Emergency disk cleanup automation completed with exit code: $exit_code"
    exit $exit_code
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi