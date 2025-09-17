#!/bin/bash
# Proxmox Health Monitoring - Common UI Functions
# This module contains shared UI functions for the TUI interface

# --- Logging Functions ---
log_debug() {
    local message="$1"
    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S'): $message" >&2
}

log_info() {
    local message="$1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S'): $message" >&2
}

log_warning() {
    local message="$1"
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S'): $message" >&2
}

log_error() {
    local message="$1"
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $message" >&2
}

# --- Configuration Loading ---
load_automation_config() {
    local config_file="/etc/proxmox-health/automation.conf"

    if [ -f "$config_file" ]; then
        source "$config_file"
        log_info "Automation configuration loaded from $config_file"
    else
        log_warning "Automation configuration file not found: $config_file"
        return 1
    fi
}

# --- UI Helper Functions ---
show_message() {
    local title="$1"
    local message="$2"
    local height="${3:-10}"
    local width="${4:-60}"

    whiptail --title "$title" --msgbox "$message" "$height" "$width" 3>&1 1>&2 2>&3
}

show_yesno() {
    local title="$1"
    local message="$2"
    local height="${3:-8}"
    local width="${4:-50}"

    whiptail --title "$title" --yesno "$message" "$height" "$width" 3>&1 1>&2 2>&3
    return $?
}

show_input() {
    local title="$1"
    local message="$2"
    local default="${3:-}"
    local height="${4:-10}"
    local width="${5:-60}"

    whiptail --title "$title" --inputbox "$message" "$height" "$width" "$default" 3>&1 1>&2 2>&3
}

show_password() {
    local title="$1"
    local message="$2"
    local height="${3:-10}"
    local width="${4:-60}"

    whiptail --title "$title" --passwordbox "$message" "$height" "$width" 3>&1 1>&2 2>&3
}

show_menu() {
    local title="$1"
    local message="$2"
    local height="${3:-15}"
    local width="${4:-60}"
    local menu_height="${5:-8}"
    shift 5

    whiptail --title "$title" --menu "$message" "$height" "$width" "$menu_height" "$@" 3>&1 1>&2 2>&3
}

show_checkbox() {
    local title="$1"
    local message="$2"
    local height="${3:-15}"
    local width="${4:-60}"
    local menu_height="${5:-8}"
    shift 5

    whiptail --title "$title" --checklist "$message" "$height" "$width" "$menu_height" "$@" 3>&1 1>&2 2>&3
}

show_radiolist() {
    local title="$1"
    local message="$2"
    local height="${3:-15}"
    local width="${4:-60}"
    local menu_height="${5:-8}"
    shift 5

    whiptail --title "$title" --radiolist "$message" "$height" "$width" "$menu_height" "$@" 3>&1 1>&2 2>&3
}

show_textbox() {
    local title="$1"
    local filename="$2"
    local height="${3:-20}"
    local width="${4:-80}"

    whiptail --title "$title" --textbox "$filename" "$height" "$width" 3>&1 1>&2 2>&3
}

show_gauge() {
    local title="$1"
    local message="$2"
    local percentage="$3"
    local height="${4:-8}"
    local width="${5:-60}"

    whiptail --title "$title" --gauge "$message" "$height" "$width" "$percentage" 3>&1 1>&2 2>&3
}

# --- File Operations ---
create_temp_file() {
    mktemp /tmp/proxmox-tui.XXXXXX
}

cleanup_temp_file() {
    local temp_file="$1"
    rm -f "$temp_file" 2>/dev/null || true
}

# --- Status Functions ---
get_automation_status() {
    local service="$1"
    local config_file="/etc/proxmox-health/automation.conf"

    if [ ! -f "$config_file" ]; then
        echo "Not Configured"
        return 1
    fi

    source "$config_file"

    local config_var="AUTOMATION_${service^^}_ENABLED"
    local config_value="${!config_var:-no}"

    if [ "$config_value" = "yes" ]; then
        echo "Enabled"
        return 0
    else
        echo "Disabled"
        return 1
    fi
}

get_service_status() {
    local service="$1"

    if systemctl is-active --quiet "$service"; then
        echo "Active"
        return 0
    else
        echo "Inactive"
        return 1
    fi
}

get_file_status() {
    local file="$1"

    if [ -f "$file" ]; then
        echo "Exists"
        return 0
    else
        echo "Missing"
        return 1
    fi
}

# --- Validation Functions ---
validate_number() {
    local value="$1"
    local min="${2:-0}"
    local max="${3:-999999}"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        if [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
            return 0
        fi
    fi
    return 1
}

validate_percentage() {
    local value="$1"

    validate_number "$value" 0 100
}

validate_cron_schedule() {
    local schedule="$1"

    # Basic validation for cron schedule (5 fields)
    if [[ "$schedule" =~ ^[0-9*/,-]+\s+[0-9*/,-]+\s+[0-9*/,-]+\s+[0-9*/,-]+\s+[0-9*/,-]+$ ]]; then
        return 0
    fi
    return 1
}

# --- Configuration Functions ---
save_automation_config() {
    local config_file="/etc/proxmox-health/automation.conf"
    local temp_file

    temp_file=$(create_temp_file)

    # Create configuration file header
    cat > "$temp_file" << 'EOF'
# Proxmox Health Monitoring - Automation Configuration
# This file contains all automation-related settings
# Generated by Proxmox Health Monitor TUI

# --- General Automation Settings ---
AUTOMATION_ENABLED="yes"
AUTOMATION_LOG_LEVEL="INFO"
AUTOMATION_NOTIFY_ON_SUCCESS="yes"
AUTOMATION_NOTIFY_ON_FAILURE="critical"

EOF

    # Save all automation variables
    local vars=(
        "AUTOMATION_ZFS_CLEANUP_ENABLED"
        "AUTOMATION_ZFS_CLEANUP_SCHEDULE"
        "AUTOMATION_ZFS_CLEANUP_RETENTION"
        "AUTOMATION_DISK_CLEANUP_ENABLED"
        "AUTOMATION_DISK_CLEANUP_SCHEDULE"
        "AUTOMATION_DISK_CLEANUP_THRESHOLD"
        "AUTOMATION_MEMORY_RELIEF_ENABLED"
        "AUTOMATION_MEMORY_RELIEF_SCHEDULE"
        "AUTOMATION_MEMORY_RELIEF_THRESHOLD"
        "AUTOMATION_SYSTEM_REFRESH_ENABLED"
        "AUTOMATION_SYSTEM_REFRESH_SCHEDULE"
        "AUTOMATION_AUTO_UPDATE_ENABLED"
        "AUTOMATION_AUTO_UPDATE_SCHEDULE"
        "AUTOMATION_AUTO_UPDATE_SECURITY_ONLY"
    )

    for var in "${vars[@]}"; do
        local value="${!var:-}"
        if [ -n "$value" ]; then
            echo "$var=\"$value\"" >> "$temp_file"
        fi
    done

    # Move temp file to final location
    mv "$temp_file" "$config_file"
    chmod 644 "$config_file"

    log_info "Automation configuration saved to $config_file"
}

# --- Error Handling ---
handle_error() {
    local error_message="$1"
    local exit_code="${2:-1}"

    log_error "$error_message"
    show_message "Error" "$error_message" 10 60
    exit "$exit_code"
}

# --- Initialization ---
init_ui() {
    # Check for whiptail
    if ! command -v whiptail >/dev/null 2>&1; then
        echo "Error: whiptail is not installed. Please install it with:"
        echo "sudo apt-get install whiptail"
        exit 1
    fi

    # Check if we're running as root
    if [ "$(id -u)" -ne 0 ]; then
        show_message "Permission Error" "This script must be run as root. Please use sudo." 8 60
        exit 1
    fi

    log_info "UI initialized successfully"
}

# --- Export Functions ---
export -f log_debug log_info log_warning log_error
export -f load_automation_config
export -f show_message show_yesno show_input show_password show_menu show_checkbox show_radiolist show_textbox show_gauge
export -f create_temp_file cleanup_temp_file
export -f get_automation_status get_service_status get_file_status
export -f validate_number validate_percentage validate_cron_schedule
export -f save_automation_config
export -f handle_error init_ui