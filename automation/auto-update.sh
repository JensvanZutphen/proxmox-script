#!/bin/bash
# Auto-Update System Automation
# This script performs system updates with configurable security-only option

set -euo pipefail

# Source utilities and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Safe sourcing with fallback logging
for f in "$SCRIPT_DIR/../lib/utils.sh" "$SCRIPT_DIR/../lib/notifications.sh" "/etc/proxmox-health/automation.conf"; do
    if [ -r "$f" ]; then
        source "$f"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] Optional file not readable: $f" >&2
    fi
done

# --- Configuration ---
DEFAULT_SECURITY_ONLY="yes"
# Note: DEFAULT_EXCLUDE_PACKAGES is currently unused - remove or implement package exclusion
# DEFAULT_EXCLUDE_PACKAGES=("kernel*" "proxmox*" "pve-*")
DEFAULT_LOG_FILE="/var/log/proxmox-health/auto-update.log"

# Set noninteractive frontend to prevent prompts during unattended runs
export DEBIAN_FRONTEND=noninteractive

# log_info logs an informational message with a timestamp to stderr and appends the same entry to $DEFAULT_LOG_FILE.
log_info() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >&2
    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$DEFAULT_LOG_FILE"; } 2>/dev/null || true
}

# log_warning writes a timestamped WARNING message to stderr and appends the same entry to the file specified by DEFAULT_LOG_FILE.
log_warning() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1" >&2
    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1" >> "$DEFAULT_LOG_FILE"; } 2>/dev/null || true
}

# log_error writes a timestamped ERROR message to stderr and appends the same entry to the file referenced by DEFAULT_LOG_FILE.
log_error() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$DEFAULT_LOG_FILE"; } 2>/dev/null || true
}

# log_debug writes a timestamped DEBUG message to stderr and appends it to $DEFAULT_LOG_FILE when AUTOMATION_LOG_LEVEL is set to "DEBUG".
log_debug() {
    local message="$1"
    if [ "${AUTOMATION_LOG_LEVEL:-INFO}" = "DEBUG" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >&2
        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >> "$DEFAULT_LOG_FILE"; } 2>/dev/null || true
    fi
}

# send_automation_notification sends an automation-scoped notification with the given message and level, but only emits info-level notifications if AUTOMATION_NOTIFY_ON_SUCCESS="yes" and only emits warning/error/critical notifications when AUTOMATION_NOTIFY_ON_FAILURE is set to "warning" or "critical".
send_automation_notification() {
    local message="$1"
    local level="${2:-info}"

    # Check if notifications are enabled for this level
    case "$level" in
      info)
        [ "${AUTOMATION_NOTIFY_ON_SUCCESS:-no}" = "yes" ] || return 0
        ;;
      warning|error|critical)
        [ "${AUTOMATION_NOTIFY_ON_FAILURE:-no}" = "warning" ] || [ "${AUTOMATION_NOTIFY_ON_FAILURE:-no}" = "critical" ] || return 0
        ;;
    esac

    if type -t send_notification >/dev/null 2>&1; then
        send_notification "$message" "$level" "automation"
    fi
}

# check_package_manager detects if apt package manager is available and echoes "apt" or "unknown".
# Only checks for apt since Proxmox is Debian-based and uses apt exclusively.
check_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    else
        echo "unknown"
    fi
}

# update_package_lists updates the system package index for the specified package manager.
# If `dry_run` is "yes", it logs the intended action and returns success without making changes.
# Returns non-zero when the provided package manager is unsupported.
update_package_lists() {
    local package_manager="$1"
    local dry_run="$2"

    log_info "Updating package lists"

    if [ "$dry_run" = "yes" ]; then
        log_info "[DRY RUN] Would update package lists"
        return 0
    fi

    case "$package_manager" in
        apt)
            local upd_rc=0
            apt-get -o Acquire::Retries=3 update >/dev/null 2>&1 || upd_rc=$?
            if [ "$upd_rc" -ne 0 ]; then
                log_warning "apt-get update failed (exit code: $upd_rc)"
                return 1
            fi
            ;;
        *)
            log_error "Unsupported package manager: $package_manager"
            return 1
            ;;
    esac

    log_info "Package lists updated successfully"
    return 0
}

# list_available_updates returns the number of available package updates for the specified package manager (apt); when `security_only` is "yes" it attempts to count only security-relevant updates, otherwise it counts all available updates.
list_available_updates() {
    local package_manager="$1"
    local security_only="$2"

    log_debug "Listing available updates (security only: $security_only)"

    case "$package_manager" in
        apt)
            if [ "$security_only" = "yes" ]; then
                # Use dist-upgrade for consistent simulation with actual upgrade command
                apt-get -s dist-upgrade | awk 'BEGIN{IGNORECASE=1} /^Inst/ && /security/ {c++} END{print c+0}'
            else
                apt-get -s dist-upgrade | awk '/^Inst/ {c++} END{print c+0}'
            fi
            ;;
        *)
            echo "0"
            ;;
    esac
}

# perform_updates performs system package updates using the specified package manager; supports a security-only mode and a dry-run mode and returns 0 on success or 1 on failure.
# When not in dry-run mode, it runs the appropriate package manager command for apt, checks the command's exit code to determine success, and returns non-zero for unsupported package managers.
perform_updates() {
    local package_manager="$1"
    local security_only="$2"
    local dry_run="$3"

    log_info "Performing system updates (security only: $security_only, dry run: $dry_run)"

    local update_output=""
    local update_success=true
    local rc=0

    if [ "$dry_run" = "yes" ]; then
        log_info "[DRY RUN] Would perform system updates"
        return 0
    fi

    case "$package_manager" in
        apt)
            if [ "$security_only" = "yes" ]; then
                # Build list of security-updated packages and upgrade only those (consistent with dist-upgrade simulation)
                mapfile -t _sec_pkgs < <(apt-get -s dist-upgrade | awk 'BEGIN{IGNORECASE=1} /^Inst/ && /security/ {print $2}')
                if [ "${#_sec_pkgs[@]}" -gt 0 ]; then
                    update_output=$(apt-get install -y --only-upgrade "${_sec_pkgs[@]}" -o Dpkg::Use-Pty=0 2>&1); rc=$?
                else
                    update_output="No security updates available"; rc=0
                fi
            else
                update_output=$(apt-get dist-upgrade -y -o Dpkg::Use-Pty=0 2>&1); rc=$?
            fi
            ;;
        *)
            log_error "Unsupported package manager: $package_manager"
            return 1
            ;;
    esac

    # Check if updates were successful based on exit code
    if [ "$rc" -ne 0 ]; then
        log_error "Update process encountered errors (exit code: $rc)"
        log_debug "Update output: $update_output"
        return $rc
    else
        log_info "Updates completed successfully"
        log_debug "Update output: $update_output"
        return 0
    fi
}

# cleanup_package_cache removes package manager caches for the given package manager (apt); does nothing for unknown managers.
cleanup_package_cache() {
    local package_manager="$1"

    log_debug "Cleaning package cache"

    case "$package_manager" in
        apt)
            apt-get clean >/dev/null 2>&1 || true
            ;;
        *)
            ;;
    esac
}

# perform_auto_update orchestrates the full system update workflow: it detects the package manager, refreshes package lists, counts and applies available updates (honoring `security_only="yes|no"` and `dry_run="yes|no"`), cleans package caches, sends start/completion notifications, logs progress, and returns 0 on overall success or 1 on failure.
perform_auto_update() {
    local security_only="$1"
    local dry_run="$2"

    log_info "Starting auto-update system (security only: $security_only, dry run: $dry_run)"

    # Send start notification
    local start_message="Auto-update system started (security only: $security_only)"
    if [ "$dry_run" = "yes" ]; then
        start_message="$start_message [DRY RUN]"
    fi
    send_automation_notification "$start_message" "info"

    # Check package manager
    local package_manager
    package_manager=$(check_package_manager)
    if [ "$package_manager" = "unknown" ]; then
        local error_message="Auto-update failed: No supported package manager found"
        send_automation_notification "$error_message" "error"
        return 1
    fi

    log_info "Using package manager: $package_manager"

    # Update package lists
    if ! update_package_lists "$package_manager" "$dry_run"; then
        local error_message="Auto-update failed: Could not update package lists"
        send_automation_notification "$error_message" "error"
        return 1
    fi

    # Count available updates
    local available_updates
    available_updates=$(list_available_updates "$package_manager" "$security_only")
    log_info "Found $available_updates available updates"

    # Perform updates
    local update_success=true
    if perform_updates "$package_manager" "$security_only" "$dry_run"; then
        log_info "Updates completed successfully"
    else
        log_warning "Updates completed with some errors"
        update_success=false
    fi

    # Clean up package cache
    cleanup_package_cache "$package_manager"

    # Send completion notification
    local result_message="Auto-update system completed."
    result_message="$result_message Updates available: $available_updates"
    result_message="$result_message Security only: $security_only"

    if [ "$dry_run" = "yes" ]; then
        result_message="$result_message [DRY RUN]"
        send_automation_notification "$result_message" "info"
    else
        if [ "$update_success" = true ]; then
            if [ "$available_updates" -eq 0 ]; then
                result_message="$result_message No updates were needed."
                send_automation_notification "$result_message" "info"
            else
                result_message="$result_message Updates were applied successfully."
                send_automation_notification "$result_message" "info"
            fi
        else
            result_message="$result_message Updates completed with some errors."
            send_automation_notification "$result_message" "warning"
        fi
    fi

    log_info "$result_message"

    return $([ "$update_success" = true ] && echo 0 || echo 1)
}

# show_help prints the help/usage message for the auto-update script, including available options, examples, configuration notes, supported package managers, and default log file.
show_help() {
    cat << EOF
Auto-Update System Automation

Usage: $0 [OPTIONS]

Options:
  -h, --help          Show this help message
  -t, --test         Run in test mode (dry run)
  -v, --verbose      Enable verbose logging
  -c, --config FILE  Use specific configuration file
  -s, --security     Security updates only (default: $DEFAULT_SECURITY_ONLY)
  -a, --all          All updates (not just security)

Examples:
  $0                 # Apply security updates only
  $0 --test          # Show what updates would be applied
  $0 --all           # Apply all updates
  $0 --test --all    # Test applying all updates

Configuration:
  The script reads configuration from /etc/proxmox-health/automation.conf
  Override security_only by setting AUTOMATION_AUTO_UPDATE_SECURITY_ONLY in config.

Package Managers:
  apt (Debian/Ubuntu) - Proxmox is Debian-based and uses apt exclusively

Log File:
  $DEFAULT_LOG_FILE
EOF
}

# main is the CLI entrypoint for the auto-update script; it parses options (‑h/--help, ‑t/--test, ‑v/--verbose, ‑c/--config FILE, ‑s/--security, ‑a/--all), configures dry-run and logging, sources an optional config file, invokes perform_auto_update with the chosen mode, logs the outcome, and exits with that command's exit code.
main() {
    local security_only="${AUTOMATION_AUTO_UPDATE_SECURITY_ONLY:-$DEFAULT_SECURITY_ONLY}"
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
                if [ -z "${1:-}" ]; then
                    log_error "Missing argument for --config"
                    exit 1
                fi
                if [ ! -r "$1" ]; then
                    log_error "Config file not found or not readable: $1"
                    exit 1
                fi
                if command -v stat >/dev/null 2>&1; then
                  owner_uid=$(stat -c '%u' "$1" 2>/dev/null || echo '')
                  perms=$(stat -c '%a' "$1" 2>/dev/null || echo '000')
                  cur_uid=$(id -u)
                  grp_digit=$(( (10#$perms / 10) % 10 ))
                  oth_digit=$(( 10#$perms % 10 ))
                  if { [ "$owner_uid" != "$cur_uid" ] && [ "$owner_uid" != "0" ]; } || \
                     { [ $((grp_digit & 2)) -ne 0 ] || [ $((oth_digit & 2)) -ne 0 ]; }; then
                    log_error "Unsafe config file permissions/owner: $1 (owner_uid=$owner_uid perms=$perms)"
                    exit 1
                  fi
                fi
                source "$1"
                # Ensure log directory exists after potentially updating DEFAULT_LOG_FILE
                mkdir -p "$(dirname "$DEFAULT_LOG_FILE")"
                shift
                ;;
            -s|--security)
                security_only="yes"
                shift
                ;;
            -a|--all)
                security_only="no"
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                shift
                ;;
        esac
    done

    # Enable verbose logging if requested
    if [ "$verbose" = "yes" ]; then
        AUTOMATION_LOG_LEVEL="DEBUG"
    fi

    # Ensure log directory exists before any logging occurs
    mkdir -p "$(dirname "$DEFAULT_LOG_FILE")"

    log_info "Starting auto-update system automation"
    log_debug "Configuration: security_only=$security_only, dry_run=$dry_run, log_level=${AUTOMATION_LOG_LEVEL:-INFO}"

    # Perform auto-update
    perform_auto_update "$security_only" "$dry_run"
    local exit_code=$?

    log_info "Auto-update system automation completed with exit code: $exit_code"
    exit $exit_code
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi