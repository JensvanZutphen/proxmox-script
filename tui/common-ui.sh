#!/bin/bash
# Proxmox Health Monitoring - Common UI Functions
# This module contains shared UI functions for the TUI interface

# log_debug writes a timestamped debug-level message to stderr.
log_debug() {
    local message="$1"
    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S'): $message" >&2
}

# log_info writes an info-level log message prefixed with a timestamp to stderr.
# It accepts a single argument: the message string to log.
log_info() {
    local message="$1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S'): $message" >&2
}

# log_warning logs a warning-level message prefixed with a timestamp to stderr.
log_warning() {
    local message="$1"
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S'): $message" >&2
}

# log_error logs an error message to stderr prefixed with `[ERROR]` and a timestamp.
# The message to log is provided as the first positional argument.
log_error() {
    local message="$1"
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $message" >&2
}

# load_automation_config loads the automation configuration from /etc/proxmox-health/automation.conf into the current shell.
# It sources the file (modifying the current shell environment) and logs success; if the file is missing it logs a warning and returns 1.
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

# show_message displays a whiptail message box with a title and message; height and width default to 10 and 60 respectively.
show_message() {
    local title="$1"
    local message="$2"
    local height="${3:-10}"
    local width="${4:-60}"

    whiptail --title "$title" --msgbox "$message" "$height" "$width" 3>&1 1>&2 2>&3
}

# show_yesno displays a whiptail Yes/No dialog with a title and message (optional height and width) and returns whiptail's exit code: 0=yes, 1=no, 255=escape/error.
show_yesno() {
    local title="$1"
    local message="$2"
    local height="${3:-8}"
    local width="${4:-50}"

    whiptail --title "$title" --yesno "$message" "$height" "$width" 3>&1 1>&2 2>&3
    return $?
}

# show_input displays a whiptail input box with a title, message, optional default value and size, outputs the entered value to stdout, and returns whiptail's exit status.
show_input() {
    local title="$1"
    local message="$2"
    local default="${3:-}"
    local height="${4:-10}"
    local width="${5:-60}"

    whiptail --title "$title" --inputbox "$message" "$height" "$width" "$default" 3>&1 1>&2 2>&3
}

# show_password displays a whiptail password box with the given title and message and writes the entered password to stdout; height and width default to 10 and 60.
show_password() {
    local title="$1"
    local message="$2"
    local height="${3:-10}"
    local width="${4:-60}"

    whiptail --title "$title" --passwordbox "$message" "$height" "$width" 3>&1 1>&2 2>&3
}

# show_menu displays a whiptail menu dialog, writes the selected tag to stdout, and returns whiptail's exit status; parameters: title, message, height (default 15), width (default 60), menu_height (default 8), followed by menu item triples (tag, description, status).
show_menu() {
    local title="$1"
    local message="$2"
    local height="${3:-15}"
    local width="${4:-60}"
    local menu_height="${5:-8}"
    shift 5

    whiptail --title "$title" --menu "$message" "$height" "$width" "$menu_height" "$@" 3>&1 1>&2 2>&3
}

# show_checkbox displays a whiptail checklist dialog and writes the selected tag(s) to stdout (while returning whiptail's exit status).
show_checkbox() {
    local title="$1"
    local message="$2"
    local height="${3:-15}"
    local width="${4:-60}"
    local menu_height="${5:-8}"
    shift 5

    whiptail --title "$title" --checklist "$message" "$height" "$width" "$menu_height" "$@" 3>&1 1>&2 2>&3
}

# show_radiolist displays a whiptail radiolist dialog and prints the selected tag to stdout; args: title, message, height (default 15), width (default 60), menu_height (default 8), followed by menu entries as `tag` `item` `on/off`.
show_radiolist() {
    local title="$1"
    local message="$2"
    local height="${3:-15}"
    local width="${4:-60}"
    local menu_height="${5:-8}"
    shift 5

    whiptail --title "$title" --radiolist "$message" "$height" "$width" "$menu_height" "$@" 3>&1 1>&2 2>&3
}

# show_textbox displays the contents of a file in a read-only whiptail textbox (defaults: height=20, width=80) and returns whiptail's exit status; `filename` must be readable.
show_textbox() {
    local title="$1"
    local filename="$2"
    local height="${3:-20}"
    local width="${4:-80}"

    whiptail --title "$title" --textbox "$filename" "$height" "$width" 3>&1 1>&2 2>&3
}

# show_gauge displays a whiptail gauge dialog to indicate progress.
# It accepts a title, a message, and a percentage (0–100); height and width default to 8 and 60 respectively.
# Returns the exit status from whiptail (0 on OK/Cancel depending on dialog behavior).
show_gauge() {
    local title="$1"
    local message="$2"
    local percentage="$3"
    local height="${4:-8}"
    local width="${5:-60}"

    whiptail --title "$title" --gauge "$message" "$height" "$width" "$percentage" 3>&1 1>&2 2>&3
}

# create_temp_file creates a secure temporary file using mktemp with the pattern /tmp/proxmox-tui.XXXXXX and echoes its path.
create_temp_file() {
    mktemp /tmp/proxmox-tui.XXXXXX
}

# cleanup_temp_file removes the specified temporary file if it exists and suppresses any errors.
cleanup_temp_file() {
    local temp_file="$1"
    rm -f "$temp_file" 2>/dev/null || true
}

# get_automation_status reports whether automation for a given service is enabled according to /etc/proxmox-health/automation.conf.
# Prints "Enabled" or "Disabled" (or "Not Configured" if the config file is missing) and returns 0 when enabled, non-zero otherwise.
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

# get_service_status prints "Active" and returns 0 if the given systemd service is active; otherwise prints "Inactive" and returns 1.
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

# get_file_status outputs "Exists" and returns 0 if the specified file exists; otherwise outputs "Missing" and returns 1.
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

# validate_number validates that a string is a non-negative integer within an optional inclusive range and returns 0 on success, 1 otherwise.
# It accepts: value (required), min (optional, default 0), and max (optional, default 999999).
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

# validate_percentage validates that a numeric value is an integer percentage in the range 0–100.
validate_percentage() {
    local value="$1"

    validate_number "$value" 0 100
}

# validate_cron_schedule validates that a string is a basic 5-field cron schedule (fields may contain digits and the characters `* / - ,`) and returns 0 on success or 1 on failure.
# This performs a syntactic check for five space-separated fields only; it does not validate numeric ranges, named months/days, or more complex cron expressions.
validate_cron_schedule() {
    local schedule="$1"

    # Basic validation for cron schedule (5 fields)
    if [[ "$schedule" =~ ^[0-9*/,-]+\s+[0-9*/,-]+\s+[0-9*/,-]+\s+[0-9*/,-]+\s+[0-9*/,-]+$ ]]; then
        return 0
    fi
    return 1
}

# save_automation_config writes current AUTOMATION_* variables to /etc/proxmox-health/automation.conf.
# It generates a temporary file with a header, appends any non-empty AUTOMATION_* variables, performs security checks
# (file exists, not a symlink, owned by root), sets restrictive permissions on the temp file, then atomically moves it
# into place and sets final permissions. Logs success on completion and returns non-zero on verification or write failures.
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

    # Validate temp file before moving
    if [ ! -f "$temp_file" ]; then
        log_error "Temp file $temp_file does not exist or is not a regular file."
        return 1
    fi
    if [ -L "$temp_file" ]; then
        log_error "Temp file $temp_file is a symlink. Aborting for security."
        return 1
    fi
    if [ "$(stat -c %U "$temp_file")" != "root" ]; then
        log_error "Temp file $temp_file is not owned by root. Aborting for security."
        return 1
    fi
    chmod 600 "$temp_file"
    # Move temp file to final location atomically
    mv -f "$temp_file" "$config_file"
    chmod 644 "$config_file"

    log_info "Automation configuration saved to $config_file"
}

# handle_error logs an error, displays it in a whiptail error dialog, and exits the script.
# 
# Arguments:
#   error_message — human-readable error text to log and display.
#   exit_code (optional) — numeric exit code to use when exiting; defaults to 1.
handle_error() {
    local error_message="$1"
    local exit_code="${2:-1}"

    log_error "$error_message"
    show_message "Error" "$error_message" 10 60
    exit "$exit_code"
}

# init_ui verifies that `whiptail` is available and that the script is running as root; it shows an error or permission dialog and exits if either check fails.
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