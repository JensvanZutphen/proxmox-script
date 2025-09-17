#!/bin/bash
# System Cache Refresh Automation
# This script cleans temporary files and refreshes system services

set -euo pipefail

# Source utilities and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/notifications.sh"
source "/etc/proxmox-health/automation.conf"

# --- Configuration ---
DEFAULT_CLEANUP_AGE=7
DEFAULT_RESTART_SERVICES=("systemd-logind" "systemd-journald" "cron")
DEFAULT_CLEANUP_DIRS=("/tmp" "/var/tmp" "/var/cache/apt/archives")

# log_info writes an informational message prefixed with a timestamp and an [INFO] tag to standard error.
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >&2
}

# log_warning outputs a timestamped warning message to standard error.
log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1" >&2
}

# log_error writes a timestamped error message prefixed with [ERROR] to stderr.
log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

# log_debug outputs a timestamped debug message to stderr when AUTOMATION_LOG_LEVEL is set to "DEBUG".
log_debug() {
    if [ "${AUTOMATION_LOG_LEVEL:-INFO}" = "DEBUG" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >&2
    fi
}

# send_automation_notification sends a notification with category "automation", honoring configured gating rules.
#
# The first argument is the message; the optional second argument is the level (default: "info").
# Info-level notifications are sent only when AUTOMATION_NOTIFY_ON_SUCCESS="yes".
# Error or critical notifications are sent only when AUTOMATION_NOTIFY_ON_FAILURE is "critical" or "warning".
# Delegates delivery to send_notification with the resolved message, level, and category "automation".
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

# clean_temp_files removes files older than a given number of days from the directories listed in DEFAULT_CLEANUP_DIRS and echoes the total number of files cleaned.
# If `dry_run` is "yes" no files are deleted; instead it counts and reports how many files would be removed per directory.
clean_temp_files() {
    local age_days="$1"
    local dry_run="$2"
    local total_cleaned=0

    log_info "Cleaning temporary files older than $age_days days"

    # Clean standard temp directories
    for dir in "${DEFAULT_CLEANUP_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            log_debug "Directory not found: $dir"
            continue
        fi

        local cleaned_count=0

        if [ "$dry_run" = "yes" ]; then
            local count
            count=$(find "$dir" -type f -mtime +"$age_days" -print 2>/dev/null | wc -l)
            log_info "[DRY RUN] Would remove $count files from $dir (older than $age_days days)"
            cleaned_count="$count"
        else
            cleaned_count=$(find "$dir" -type f -mtime +"$age_days" -delete 2>/dev/null | wc -l)
            log_info "Cleaned $cleaned_count files from $dir (older than $age_days days)"
        fi

        total_cleaned=$((total_cleaned + cleaned_count))
    done

    echo "$total_cleaned"
}

# clean_package_cache cleans or estimates the system package cache for APT or YUM; when invoked with "yes" (dry run) it reports an approximate freed size (KB) and logs the intended action, otherwise it performs the cleanup and echoes a numeric result or proxy value to stdout.
clean_package_cache() {
    local dry_run="$1"
    local cleaned_size=0

    log_debug "Cleaning package cache"

    if command -v apt-get >/dev/null 2>&1; then
        if [ "$dry_run" = "yes" ]; then
            local size
            size=$(du -sk /var/cache/apt/archives 2>/dev/null | cut -f1)
            log_info "[DRY RUN] Would clean APT cache (approximately ${size}KB)"
            echo "$size"
        else
            cleaned_size=$(apt-get clean 2>&1 | grep -E "(freed|deleted)" | awk '{print $4}' | tr -d '.,' || echo "0")
            log_info "Cleaned APT cache: ${cleaned_size:-0}KB"
            echo "${cleaned_size:-0}"
        fi
    elif command -v yum >/dev/null 2>&1; then
        if [ "$dry_run" = "yes" ]; then
            local size
            size=$(du -sk /var/cache/yum 2>/dev/null | cut -f1)
            log_info "[DRY RUN] Would clean YUM cache (approximately ${size}KB)"
            echo "$size"
        else
            yum clean all >/dev/null 2>&1 || true
            log_info "Cleaned YUM cache"
            echo "1"
        fi
    else
        log_debug "No package manager found, skipping cache cleanup"
        echo "0"
    fi
}

# clean_journal_logs removes old systemd journal logs or reports their size in dry-run mode.
# In dry-run mode (pass "yes") it estimates and echoes the size of /var/log/journal in KB.
# In normal mode it runs `journalctl --vacuum-time=7d` to keep only the last 7 days and echoes "1" on success.
# If journalctl is not available it does nothing and echoes "0".
clean_journal_logs() {
    local dry_run="$1"
    local cleaned_size=0

    log_debug "Cleaning journal logs"

    if command -v journalctl >/dev/null 2>&1; then
        if [ "$dry_run" = "yes" ]; then
            local size
            size=$(du -sk /var/log/journal 2>/dev/null | cut -f1)
            log_info "[DRY RUN] Would clean old journal logs (approximately ${size}KB)"
            echo "$size"
        else
            # Keep only last 7 days of journal logs
            journalctl --vacuum-time=7d >/dev/null 2>&1 || true
            log_info "Cleaned old journal logs"
            echo "1"
        fi
    else
        log_debug "Journalctl not found, skipping journal cleanup"
        echo "0"
    fi
}

# restart_services restarts each service listed in DEFAULT_RESTART_SERVICES if active; in dry-run mode ("yes") it only logs the intended restarts. It echoes the number of services that were (or would be) restarted.
restart_services() {
    local dry_run="$1"
    local restarted_count=0

    log_info "Restarting system services"

    for service in "${DEFAULT_RESTART_SERVICES[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            if [ "$dry_run" = "yes" ]; then
                log_info "[DRY RUN] Would restart service: $service"
                restarted_count=$((restarted_count + 1))
            else
                log_info "Restarting service: $service"
                if systemctl restart "$service" 2>/dev/null; then
                    log_info "Successfully restarted $service"
                    restarted_count=$((restarted_count + 1))
                else
                    log_warning "Failed to restart $service"
                fi
            fi
        else
            log_debug "Service $service is not active, skipping"
        fi
    done

    echo "$restarted_count"
}

# refresh_system orchestrates a full system cache refresh: cleans temp files, package caches, journal logs, restarts configured services, and emits notifications and summary metrics.
#
# refresh_system takes two arguments: the number of days used as the age threshold for cleaning (age_days) and a dry-run flag ("yes" to simulate without making changes). It runs the cleanup steps in sequence, aggregates totals for files removed, size freed (KB), and services restarted, captures disk usage before/after, logs progress, and sends start/completion notifications (completion includes a "[DRY RUN]" tag when applicable). The function always returns 0.
refresh_system() {
    local age_days="$1"
    local dry_run="$2"

    log_info "Starting system cache refresh (age: $age_days days, dry run: $dry_run)"

    # Send start notification
    local start_message="System cache refresh started"
    if [ "$dry_run" = "yes" ]; then
        start_message="$start_message [DRY RUN]"
    fi
    send_automation_notification "$start_message" "info"

    # Initialize counters
    local total_files_cleaned=0
    local total_size_freed=0
    local total_services_restarted=0

    # Clean temporary files
    log_info "Cleaning temporary files..."
    local files_cleaned
    files_cleaned=$(clean_temp_files "$age_days" "$dry_run")
    total_files_cleaned=$((total_files_cleaned + files_cleaned))

    # Clean package cache
    log_info "Cleaning package cache..."
    local size_freed
    size_freed=$(clean_package_cache "$dry_run")
    total_size_freed=$((total_size_freed + size_freed))

    # Clean journal logs
    log_info "Cleaning journal logs..."
    local journal_cleaned
    journal_cleaned=$(clean_journal_logs "$dry_run")
    total_size_freed=$((total_size_freed + journal_cleaned))

    # Restart services
    log_info "Restarting system services..."
    local services_restarted
    services_restarted=$(restart_services "$dry_run")
    total_services_restarted=$((total_services_restarted + services_restarted))

    # Get disk space before and after
    local disk_before
    disk_before=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    local disk_after
    disk_after=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')

    # Send completion notification
    local result_message="System cache refresh completed."
    result_message="$result_message Files cleaned: $total_files_cleaned"
    result_message="$result_message Size freed: ${total_size_freed}KB"
    result_message="$result_message Services restarted: $total_services_restarted"
    result_message="$result_message Disk usage: ${disk_before}% → ${disk_after}%"

    if [ "$dry_run" = "yes" ]; then
        result_message="$result_message [DRY RUN]"
        send_automation_notification "$result_message" "info"
    else
        if [ "$total_files_cleaned" -gt 0 ] || [ "$total_size_freed" -gt 0 ] || [ "$total_services_restarted" -gt 0 ]; then
            send_automation_notification "$result_message" "info"
        else
            result_message="$result_message (no significant changes)"
            send_automation_notification "$result_message" "info"
        fi
    fi

    log_info "$result_message"

    return 0
}

# show_help prints usage and help text for the System Cache Refresh Automation script, detailing options, the optional AGE_DAYS argument, configuration source, and example invocations.
show_help() {
    cat << EOF
System Cache Refresh Automation

Usage: $0 [OPTIONS] [AGE_DAYS]

Options:
  -h, --help          Show this help message
  -t, --test         Run in test mode (dry run)
  -v, --verbose      Enable verbose logging
  -c, --config FILE  Use specific configuration file

Arguments:
  AGE_DAYS           File age threshold in days (default: $DEFAULT_CLEANUP_AGE)

Examples:
  $0                 # Clean files older than $DEFAULT_CLEANUP_AGE days
  $0 3              # Clean files older than 3 days
  $0 --test         # Show what would be cleaned without actually cleaning
  $0 --test 14      # Test cleaning files older than 14 days

Configuration:
  The script reads configuration from /etc/proxmox-health/automation.conf
  Override cleanup age by setting AUTOMATION_SYSTEM_REFRESH_AGE in config.

Services Restarted:
  systemd-logind, systemd-journald, cron
EOF
}

# main parses CLI args, validates input, configures logging/dry-run, and runs refresh_system.
#
# It accepts an optional numeric AGE_DAYS (or uses AUTOMATION_SYSTEM_REFRESH_AGE / DEFAULT_CLEANUP_AGE),
# supports flags: -h|--help (show help), -t|--test (dry-run), -v|--verbose (enable DEBUG logging),
# -c|--config FILE (source alternate config). Exits non‑zero for invalid options or invalid age.
main() {
    local age_days="${1:-${AUTOMATION_SYSTEM_REFRESH_AGE:-$DEFAULT_CLEANUP_AGE}}"
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
                    age_days="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate age_days
    if ! [[ "$age_days" =~ ^[0-9]+$ ]] || [ "$age_days" -lt 1 ]; then
        log_error "Invalid age_days: $age_days. Must be a positive integer."
        exit 1
    fi

    # Enable verbose logging if requested
    if [ "$verbose" = "yes" ]; then
        AUTOMATION_LOG_LEVEL="DEBUG"
    fi

    log_info "Starting system cache refresh automation"
    log_debug "Configuration: age_days=$age_days, dry_run=$dry_run, log_level=${AUTOMATION_LOG_LEVEL:-INFO}"

    # Perform system refresh
    refresh_system "$age_days" "$dry_run"
    local exit_code=$?

    log_info "System cache refresh automation completed with exit code: $exit_code"
    exit $exit_code
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi