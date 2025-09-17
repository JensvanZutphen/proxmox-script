#!/bin/bash
# Memory Pressure Relief Automation
# This script drops disk caches when memory usage exceeds threshold

set -euo pipefail

# Source utilities and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/notifications.sh"
source "/etc/proxmox-health/automation.conf"

# --- Configuration ---
DEFAULT_THRESHOLD=90
DEFAULT_CHECK_INTERVAL=5
DEFAULT_CACHE_LEVEL=3  # 1 = pagecache, 2 = dentries and inodes, 3 = pagecache, dentries and inodes

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

get_memory_usage() {
    # Get memory usage percentage
    free | awk '/Mem:/ {printf "%.0f", $3/$2*100}'
}

get_memory_info() {
    # Get detailed memory information
    free -h
}

get_swap_usage() {
    # Get swap usage percentage
    free | awk '/Swap:/ {
        if ($2 == 0) printf "0";
        else printf "%.0f", $3/$2*100
    }'
}

drop_caches() {
    local cache_level="$1"
    local dry_run="$2"

    log_debug "Attempting to drop caches (level: $cache_level, dry run: $dry_run)"

    if [ "$dry_run" = "yes" ]; then
        log_info "[DRY RUN] Would drop caches with level $cache_level"
        return 0
    fi

    # Check if we have permission to drop caches
    if [ ! -w "/proc/sys/vm/drop_caches" ]; then
        log_error "No permission to drop caches. Run as root."
        return 1
    fi

    # Sync first to ensure data integrity
    sync

    # Drop caches
    if echo "$cache_level" > /proc/sys/vm/drop_caches 2>/dev/null; then
        log_info "Successfully dropped caches (level: $cache_level)"
        return 0
    else
        log_error "Failed to drop caches (level: $cache_level)"
        return 1
    fi
}

check_memory_pressure() {
    local threshold="$1"
    local current_usage
    current_usage=$(get_memory_usage)

    log_debug "Current memory usage: ${current_usage}%, threshold: ${threshold}%"

    if [ "$current_usage" -ge "$threshold" ]; then
        log_warning "Memory usage critical: ${current_usage}% (threshold: ${threshold}%)"
        return 0
    else
        log_debug "Memory usage normal: ${current_usage}%"
        return 1
    fi
}

perform_memory_relief() {
    local threshold="$1"
    local dry_run="$2"

    log_info "Starting memory pressure relief check (threshold: ${threshold}%, dry run: $dry_run)"

    # Get initial memory information
    local initial_usage
    initial_usage=$(get_memory_usage)
    local initial_swap
    initial_swap=$(get_swap_usage)

    log_info "Initial state - Memory: ${initial_usage}%, Swap: ${initial_swap}%"

    # Send initial notification if memory pressure is high
    if check_memory_pressure "$threshold"; then
        local alert_message="Memory pressure relief initiated! Usage: ${initial_usage}% (threshold: ${threshold}%), Swap: ${initial_swap}%"
        if [ "$dry_run" = "yes" ]; then
            alert_message="$alert_message [DRY RUN]"
        fi
        send_automation_notification "$alert_message" "warning"
    else
        send_automation_notification "Memory pressure check completed. Usage: ${initial_usage}%, Swap: ${initial_swap}%" "info"
        return 0
    fi

    # Drop caches
    local cache_level="$DEFAULT_CACHE_LEVEL"
    if ! drop_caches "$cache_level" "$dry_run"; then
        local error_message="Failed to drop caches. Memory usage remains high: ${initial_usage}%"
        send_automation_notification "$error_message" "error"
        return 1
    fi

    # Wait a moment for system to stabilize
    sleep 2

    # Get final memory information
    local final_usage
    final_usage=$(get_memory_usage)
    local final_swap
    final_swap=$(get_swap_usage)

    # Send completion notification
    local result_message="Memory pressure relief completed."
    result_message="$result_message Memory usage: ${initial_usage}% → ${final_usage}%"
    result_message="$result_message Swap usage: ${initial_swap}% → ${final_swap}%"

    if [ "$dry_run" = "yes" ]; then
        result_message="$result_message [DRY RUN]"
        send_automation_notification "$result_message" "info"
    else
        if [ "$final_usage" -lt "$initial_usage" ]; then
            local improvement=$((initial_usage - final_usage))
            result_message="$result_message (improved by ${improvement}%)"
            send_automation_notification "$result_message" "info"
        else
            result_message="$result_message (no significant improvement)"
            send_automation_notification "$result_message" "warning"
        fi
    fi

    log_info "$result_message"

    return 0
}

monitor_memory_pressure() {
    local threshold="$1"
    local interval="$2"
    local dry_run="$3"

    log_info "Starting memory pressure monitoring (threshold: ${threshold}%, interval: ${interval}s, dry run: $dry_run)"

    # Check memory pressure once
    if check_memory_pressure "$threshold"; then
        perform_memory_relief "$threshold" "$dry_run"
    else
        log_info "Memory pressure is normal. No action needed."
    fi

    return 0
}

show_help() {
    cat << EOF
Memory Pressure Relief Automation

Usage: $0 [OPTIONS] [THRESHOLD]

Options:
  -h, --help          Show this help message
  -t, --test         Run in test mode (dry run)
  -v, --verbose      Enable verbose logging
  -c, --config FILE  Use specific configuration file
  -i, --interval SEC Set check interval in seconds (default: $DEFAULT_CHECK_INTERVAL)

Arguments:
  THRESHOLD          Memory usage threshold percentage (default: $DEFAULT_THRESHOLD)

Examples:
  $0                 # Check and relieve if memory usage > $DEFAULT_THRESHOLD%
  $0 85             # Check and relieve if memory usage > 85%
  $0 --test         # Show what would be done without actually dropping caches
  $0 --test 80      # Test with 80% threshold

Configuration:
  The script reads configuration from /etc/proxmox-health/automation.conf
  Override threshold by setting AUTOMATION_MEMORY_RELIEF_THRESHOLD in config.

Cache Levels:
  1 - Page cache only
  2 - Dentries and inodes
  3 - Page cache, dentries and inodes (default)
EOF
}

# --- Main Execution ---
main() {
    local threshold="${1:-${AUTOMATION_MEMORY_RELIEF_THRESHOLD:-$DEFAULT_THRESHOLD}}"
    local dry_run="no"
    local verbose="no"
    local interval="$DEFAULT_CHECK_INTERVAL"

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
            -i|--interval)
                shift
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    interval="$1"
                fi
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

    # Validate interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ]; then
        log_error "Invalid interval: $interval. Must be a positive integer."
        exit 1
    fi

    # Enable verbose logging if requested
    if [ "$verbose" = "yes" ]; then
        AUTOMATION_LOG_LEVEL="DEBUG"
    fi

    log_info "Starting memory pressure relief automation"
    log_debug "Configuration: threshold=$threshold, interval=$interval, dry_run=$dry_run, log_level=${AUTOMATION_LOG_LEVEL:-INFO}"

    # Show current memory information
    if [ "$verbose" = "yes" ]; then
        echo "Current Memory Information:"
        get_memory_info
        echo ""
    fi

    # Perform memory monitoring and relief
    monitor_memory_pressure "$threshold" "$interval" "$dry_run"
    local exit_code=$?

    log_info "Memory pressure relief automation completed with exit code: $exit_code"
    exit $exit_code
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi