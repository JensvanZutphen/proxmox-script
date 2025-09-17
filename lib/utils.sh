#!/bin/bash
# Proxmox Health Monitoring Utilities
# This module contains utility functions for the monitoring system

# Load configuration
# shellcheck disable=SC1091
source "/etc/proxmox-health/proxmox-health.conf"

# Provide defaults for CI/static analysis when config isn't sourced
: "${LOG_LEVEL:=INFO}"
: "${BACKUP_DIR:=/var/lib/vz/dump}"
: "${VZDUMP_LOG_DIR:=/var/log/vzdump}"

# --- Logging Functions ---
# shellcheck disable=SC2034
LOG_LEVELS=("DEBUG" "INFO" "WARNING" "ERROR" "CRITICAL")

log_level_number() {
    local level="$1"
    case "$level" in
        "DEBUG") echo 0 ;;
        "INFO") echo 1 ;;
        "WARNING") echo 2 ;;
        "ERROR") echo 3 ;;
        "CRITICAL") echo 4 ;;
        *) echo 1 ;;
    esac
}

should_log() {
    local message_level="$1"
    local config_level_number
    config_level_number=$(log_level_number "$LOG_LEVEL")
    local message_level_number
    message_level_number=$(log_level_number "$message_level")

    [ "$message_level_number" -ge "$config_level_number" ]
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$
    local hostname
    hostname=$(hostname)

    if should_log "$level"; then
        local formatted_message="[$timestamp] [$level] [PID:$pid] [$hostname] $message"

        # Log to file
        if [ -d "$LOG_DIR" ]; then
            echo "$formatted_message" >> "$LOG_DIR/proxmox-health.log"
        fi

        # Log to console if running interactively
        if [ -t 0 ]; then
            echo "$formatted_message" >&2
        fi

        # Log to system log
        logger -t "proxmox-health" -p "user.$(echo "$level" | tr '[:upper:]' '[:lower:]')" "$message"
    fi
}

log_debug() { log_message "DEBUG" "$1"; }
log_info() { log_message "INFO" "$1"; }
log_warning() { log_message "WARNING" "$1"; }
log_error() { log_message "ERROR" "$1"; }
log_critical() { log_message "CRITICAL" "$1"; }

# --- Error Handling Functions ---
handle_error() {
    local exit_code=$?
    local line_number=$1
    local command="$2"
    local error_message="Error on line $line_number: '$command' exited with status $exit_code"

    log_error "$error_message"
    send_notification "$error_message" "critical" "error"

    # Exit if critical error
    if [ $exit_code -ne 0 ]; then
        exit $exit_code
    fi
}

set_error_handling() {
    set -euo pipefail
    trap 'handle_error $LINENO "$BASH_COMMAND"' ERR
}

# --- Configuration Management Functions ---
validate_configuration() {
    local errors=0

    # Check required directories
    required_dirs=("$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$BACKUP_DIR" "$VZDUMP_LOG_DIR")
    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            log_warning "Directory does not exist: $dir"
        fi
    done

    # Validate numeric thresholds
    numeric_thresholds=(
        "MEMORY_WARNING_THRESHOLD" "MEMORY_CRITICAL_THRESHOLD"
        "SWAP_WARNING_THRESHOLD" "SWAP_CRITICAL_THRESHOLD"
        "DISK_ROOT_WARNING_THRESHOLD" "DISK_ROOT_CRITICAL_THRESHOLD"
        "ZFS_CAPACITY_WARNING_THRESHOLD" "ZFS_CAPACITY_CRITICAL_THRESHOLD"
        "IOWAIT_WARNING_THRESHOLD" "IOWAIT_CRITICAL_THRESHOLD"
        "PACKET_LOSS_WARNING_THRESHOLD" "PACKET_LOSS_CRITICAL_THRESHOLD"
        "SSH_FAILED_LOGIN_THRESHOLD" "SSH_CONNECTION_WARNING_THRESHOLD"
        "CPU_TEMPERATURE_WARNING_THRESHOLD" "CPU_TEMPERATURE_CRITICAL_THRESHOLD"
        "HDD_TEMPERATURE_WARNING_THRESHOLD" "HDD_TEMPERATURE_CRITICAL_THRESHOLD"
        "SSD_TEMPERATURE_WARNING_THRESHOLD" "SSD_TEMPERATURE_CRITICAL_THRESHOLD"
        "INTERFACE_ERROR_DELTA_THRESHOLD"
        "BACKUP_MAX_AGE_DAYS" "HEALTH_CHECK_INTERVAL_MINUTES"
        "ALERT_COOLDOWN_MINUTES" "ALERT_MAX_RETRIES" "ALERT_RETRY_DELAY_SECONDS"
        "LOG_MAX_SIZE_MB" "LOG_ROTATION_COUNT" "STATE_RETENTION_DAYS"
    )

    for threshold in "${numeric_thresholds[@]}"; do
        if [ -n "${!threshold}" ]; then
            if ! [[ "${!threshold}" =~ ^[0-9]+$ ]]; then
                log_error "Invalid numeric value for $threshold: ${!threshold}"
                errors=$((errors + 1))
            fi
        fi
    done

    # Validate boolean values
    boolean_vars=(
        "LOAD_AUTO_DETECT" "PARALLEL_CHECKS" "CACHE_ENABLED"
        "EMAIL_NOTIFICATIONS_ENABLED" "LOG_TO_CONSOLE" "LOG_TO_FILE"
    )

    for var in "${boolean_vars[@]}"; do
        if [ -n "${!var}" ]; then
            if [[ "${!var}" != "yes" && "${!var}" != "no" ]]; then
                log_error "Invalid boolean value for $var: ${!var} (must be 'yes' or 'no')"
                errors=$((errors + 1))
            fi
        fi
    done

    # Validate that critical < warning thresholds
    if [ "$MEMORY_CRITICAL_THRESHOLD" -le "$MEMORY_WARNING_THRESHOLD" ]; then
        log_error "Memory critical threshold must be greater than warning threshold"
        errors=$((errors + 1))
    fi

    if [ "$DISK_ROOT_CRITICAL_THRESHOLD" -le "$DISK_ROOT_WARNING_THRESHOLD" ]; then
        log_error "Disk critical threshold must be greater than warning threshold"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        log_critical "Configuration validation failed with $errors errors"
        return 1
    fi

    log_info "Configuration validation passed"
    return 0
}

reload_configuration() {
    log_info "Reloading configuration..."
    if [ -f "/etc/proxmox-health/proxmox-health.conf" ]; then
        source "/etc/proxmox-health/proxmox-health.conf"
        validate_configuration
        log_info "Configuration reloaded successfully"
    else
        log_error "Configuration file not found"
        return 1
    fi
}

# --- File Management Functions ---
setup_directories() {
    local dirs=("$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$CUSTOM_CHECKS_DIR" "$PLUGIN_DIR")

    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            log_info "Creating directory: $dir"
            mkdir -p "$dir"
            chmod 755 "$dir"
        fi
    done

    # Set up secure directory for secrets
    local secret_dir
    secret_dir=$(dirname "$WEBHOOK_SECRET_FILE")
    if [ ! -d "$secret_dir" ]; then
        mkdir -p "$secret_dir"
        chmod 700 "$secret_dir"
    fi

    # Ensure runtime directory exists for manual runs
    if [ ! -d "/run/proxmox-health" ]; then
        mkdir -p "/run/proxmox-health"
        chmod 755 "/run/proxmox-health"
    fi
}

cleanup_old_files() {
    # Clean up old state files
    find "$STATE_DIR" -name "*.state" -mtime +"$STATE_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$STATE_DIR" -name "*.notify" -mtime +"$STATE_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$STATE_DIR" -name "*.prev" -mtime +"$STATE_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$STATE_DIR" -name "*.now" -mtime +"$STATE_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$STATE_DIR" -name "*.err" -mtime +"$STATE_RETENTION_DAYS" -delete 2>/dev/null || true

    # Clean up old log files
    find "$LOG_DIR" -name "*.log.*" -mtime +"$STATE_RETENTION_DAYS" -delete 2>/dev/null || true
}

# --- Process Management Functions ---
is_running() {
    local pid_file="$1"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            rm -f "$pid_file"
        fi
    fi
    return 1
}

create_pid_file() {
    local pid_file="$1"
    local pid=$$

    if is_running "$pid_file"; then
        log_error "Process already running with PID $(cat "$pid_file")"
        return 1
    fi

    echo "$pid" > "$pid_file"
    log_debug "Created PID file: $pid_file"
}

remove_pid_file() {
    local pid_file="$1"
    if [ -f "$pid_file" ]; then
        rm -f "$pid_file"
        log_debug "Removed PID file: $pid_file"
    fi
}

# --- Performance and Caching Functions ---
get_cache_value() {
    local cache_key="$1"
    local cache_file="$STATE_DIR/cache_$cache_key"

    if [ "$CACHE_ENABLED" = "yes" ] && [ -f "$cache_file" ]; then
        local cache_time
        cache_time=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        local current_time
        current_time=$(date +%s)
        local cache_age=$((current_time - cache_time))
        local cache_ttl_seconds=$((CACHE_TTL_MINUTES * 60))

        if [ $cache_age -lt $cache_ttl_seconds ]; then
            cat "$cache_file"
            return 0
        else
            rm -f "$cache_file"
        fi
    fi

    return 1
}

set_cache_value() {
    local cache_key="$1"
    local value="$2"
    local cache_file="$STATE_DIR/cache_$cache_key"

    if [ "$CACHE_ENABLED" = "yes" ]; then
        echo "$value" > "$cache_file"
        log_debug "Cached value for $cache_key"
    fi
}

clear_cache() {
    find "$STATE_DIR" -name "cache_*" -delete 2>/dev/null || true
    log_info "Cache cleared"
}

# --- Network Utilities Functions ---
test_connectivity() {
    local host="$1"
    local timeout="${2:-5}"

    if ping -c1 -w"$timeout" "$host" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

get_network_interface_info() {
    local interface="$1"

    if [ -z "$interface" ]; then
        log_error "No interface specified"
        return 1
    fi

    ip addr show "$interface" 2>/dev/null || {
        log_error "Interface $interface not found"
        return 1
    }
}

# --- System Information Functions ---
get_system_info() {
    # Check if we have cached info
    if get_cache_value "system_info" > /dev/null; then
        get_cache_value "system_info"
        return 0
    fi

    # Collect system information
    local system_info=""
    system_info+="Hostname: $(hostname)\n"
    system_info+="Kernel: $(uname -r)\n"
    system_info+="Uptime: $(uptime -p)\n"
    system_info+="CPU Cores: $(nproc)\n"
    system_info+="Memory Total: $(free -h | awk '/Mem:/ {print $2}')\n"
    system_info+="Disk Total: $(df -h / | awk 'NR==2 {print $2}')\n"

    # Add Proxmox version if available
    if [ -f "/etc/version" ]; then
        system_info+="Proxmox Version: $(cat /etc/version)\n"
    fi

    # Add ZFS info if available
    if command -v zpool >/dev/null 2>&1; then
        system_info+="ZFS Pools: $(zpool list -H -o name 2>/dev/null | tr '\n' ' ')\n"
    fi

    set_cache_value "system_info" "$system_info"
    echo -e "$system_info"
}

get_load_average() {
    awk '{print $1}' /proc/loadavg
}

get_memory_usage() {
    free | awk '/Mem:/ {printf "%.1f", $3/$2*100}'
}

get_disk_usage() {
    local path="${1:-/}"
    df -P "$path" | awk 'NR==2{gsub("%","",$5);print $5}'
}

# --- Time and Date Functions ---
is_business_hours() {
    local current_hour
    current_hour=$(date +%H)
    local current_day
    current_day=$(date +%u) # 1-7 (Monday-Sunday)

    # Define business hours (9 AM to 6 PM, Monday to Friday)
    if [ "$current_day" -ge 1 ] && [ "$current_day" -le 5 ] && \
       [ "$current_hour" -ge 9 ] && [ "$current_hour" -lt 18 ]; then
        return 0
    fi
    return 1
}

get_next_business_day() {
    local current_day
    current_day=$(date +%u)
    local days_ahead=1

    case "$current_day" in
        5) days_ahead=3 ;; # Friday -> Monday
        6) days_ahead=2 ;; # Saturday -> Monday
        *) days_ahead=1 ;;
    esac

    date -d "+$days_ahead days" +%Y-%m-%d
}

# --- Version Management Functions ---
get_script_version() {
    echo "2.0.0"
}

check_dependencies() {
    local missing_deps=()
    local required_commands=("awk" "grep" "sed" "curl" "ping" "df" "free" "ip" "ss" "journalctl")

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done

    # Optional dependencies
    local optional_commands=("smartctl" "sensors" "zpool" "pct" "qm" "logger" "mail" "sendmail")
    local missing_optional=()

    for cmd in "${optional_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_optional+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi

    if [ ${#missing_optional[@]} -gt 0 ]; then
        log_warning "Missing optional dependencies: ${missing_optional[*]}"
    fi

    log_info "All required dependencies are available"
    return 0
}

# --- Backup and Restore Functions ---
backup_configuration() {
    local backup_dir="$STATE_DIR/backups"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/proxmox-health-config_$timestamp.tar.gz"

    mkdir -p "$backup_dir"

    tar -czf "$backup_file" \
        "$CONFIG_DIR/" \
        "$STATE_DIR/"*.state \
        "$STATE_DIR/"*.notify 2>/dev/null || true

    log_info "Configuration backed up to $backup_file"
    echo "$backup_file"
}

restore_configuration() {
    local backup_file="$1"

    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    # Create backup of current configuration
    local current_backup
    current_backup=$(backup_configuration)

    # Extract backup
    tar -xzf "$backup_file" -C / || {
        log_error "Failed to extract backup file"
        return 1
    }

    log_info "Configuration restored from $backup_file"
    log_info "Previous configuration backed up to $current_backup"
}

# --- Main Utility Functions ---
initialize_system() {
    log_info "Initializing Proxmox Health Monitoring System..."

    # Set up error handling
    set_error_handling

    # Set up directories
    setup_directories

    # Validate configuration
    validate_configuration

    # Check dependencies
    check_dependencies

    # Clean up old files
    cleanup_old_files

    # Initialize notification system
    initialize_notifications

    log_info "System initialization completed"
}

cleanup_system() {
    log_info "Cleaning up Proxmox Health Monitoring System..."
    cleanup_old_files
    clear_cache
    cleanup_old_notifications
    log_info "System cleanup completed"
}

# --- Signal Handlers ---
setup_signal_handlers() {
    trap 'log_info "Received SIGINT - shutting down gracefully..."; cleanup_system; exit 0' INT
    trap 'log_info "Received SIGTERM - shutting down gracefully..."; cleanup_system; exit 0' TERM
    trap 'log_info "Received SIGHUP - reloading configuration..."; reload_configuration' HUP
}

# --- Export Functions ---
export -f log_debug log_info log_warning log_error log_critical
export -f handle_error set_error_handling
export -f validate_configuration reload_configuration
export -f setup_directories cleanup_old_files
export -f is_running create_pid_file remove_pid_file
export -f get_cache_value set_cache_value clear_cache
export -f test_connectivity get_network_interface_info
export -f get_system_info get_load_average get_memory_usage get_disk_usage
export -f is_business_hours get_next_business_day
export -f get_script_version check_dependencies
export -f backup_configuration restore_configuration
export -f initialize_system cleanup_system setup_signal_handlers
