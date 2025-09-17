#!/bin/bash
# Proxmox Health Monitoring System - Installer
# This script installs and configures the complete monitoring system

set -euo pipefail

# --- Variables ---
SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/proxmox-health.conf"
INSTALL_DIR="/etc/proxmox-health"
LIB_DIR="/usr/local/lib/proxmox-health"
BIN_DIR="/usr/local/bin"
CRON_FILE="/etc/cron.d/proxmox-health"
LOGROTATE_FILE="/etc/logrotate.d/proxmox-health"
SYSTEMD_SERVICE="/etc/systemd/system/proxmox-health.service"
SYSTEMD_TIMER="/etc/systemd/system/proxmox-health.timer"
SYSTEMD_SUMMARY_SERVICE="/etc/systemd/system/proxmox-health-summary.service"
SYSTEMD_SUMMARY_TIMER="/etc/systemd/system/proxmox-health-summary.timer"
WEBHOOK_SECRET_FILE="/etc/proxmox-health/webhook-secret"

# Load defaults from the bundled configuration so TUI prompts and installers
# reuse the same baseline values as a fresh install.
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Ensure critical values are available even when sourcing fails (e.g., during CI)
: "${HEALTH_CHECK_INTERVAL_MINUTES:=5}"
: "${PING_TEST_HOST:=1.1.1.1}"
: "${MONITORED_BRIDGES:=vmbr0}"
: "${DAILY_SUMMARY_TIME:=08:00}"

# --- TUI selection defaults (can be changed by TUI) ---
SELECT_DEPS=1
SELECT_CONFIG=1
SELECT_LIBS=1
SELECT_BINS=1
SELECT_CRON=1
SELECT_LOGROTATE=1
SELECT_SYSTEMD=1
SELECT_EXAMPLES=1
SELECT_INIT=1

# --- TUI inputs ---
TUI_WEBHOOK_URL=""
TUI_USED=0

TUI_HEALTH_INTERVAL="$HEALTH_CHECK_INTERVAL_MINUTES"
TUI_PING_HOST="$PING_TEST_HOST"
TUI_MONITORED_BRIDGES="$MONITORED_BRIDGES"
TUI_SUMMARY_TIME="$DAILY_SUMMARY_TIME"

# Per-category selections (1=yes,0=no)
TUI_CHECK_SERVICES=1
TUI_CHECK_DISK=1
TUI_CHECK_ZFS=1
TUI_CHECK_MEMORY=1
TUI_CHECK_LOAD=1
TUI_CHECK_IOWAIT=1
TUI_CHECK_NETWORK=1
TUI_CHECK_IFACE_ERRORS=1
TUI_CHECK_SSH=1
TUI_CHECK_SYS_EVENTS=1
TUI_CHECK_TEMPS=1
TUI_CHECK_BACKUPS=1
TUI_CHECK_UPDATES=1
TUI_CHECK_VMS=1

TUI_NOTIFY_SERVICES=1
TUI_NOTIFY_DISK=1
TUI_NOTIFY_ZFS=1
TUI_NOTIFY_MEMORY=1
TUI_NOTIFY_LOAD=1
TUI_NOTIFY_IOWAIT=1
TUI_NOTIFY_NETWORK=1
TUI_NOTIFY_IFACE_ERRORS=1
TUI_NOTIFY_SSH=1
TUI_NOTIFY_SYS_EVENTS=1
TUI_NOTIFY_TEMPS=1
TUI_NOTIFY_BACKUPS=1
TUI_NOTIFY_UPDATES=1
TUI_NOTIFY_VMS=1

# --- CLI flags ---
USE_TUI="auto"  # values: auto|yes|no
MODE="install" # values: install|configure

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

INSTALLER_UTILS_FILE="$SCRIPT_DIR/lib/installer-utils.sh"
if [ -f "$INSTALLER_UTILS_FILE" ]; then
    # shellcheck disable=SC1090
    source "$INSTALLER_UTILS_FILE"
else
    echo "Installer helpers missing: $INSTALLER_UTILS_FILE" >&2
    exit 1
fi

usage() {
    cat << EOF
Proxmox Health Installer v$SCRIPT_VERSION

Usage: $0 [--tui|--no-tui]
       $0 --configure [--tui|--no-tui]

  --tui      Force interactive TUI wizard
  --no-tui   Disable TUI and install with defaults
  --configure Re-apply configuration only (no reinstall)

EOF
}

parse_args() {
    while [ "${1:-}" != "" ]; do
        case "$1" in
            --tui)
                USE_TUI="yes"
                ;;
            --no-tui)
                USE_TUI="no"
                ;;
            --configure)
                MODE="configure"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_warning "Unknown argument: $1"
                ;;
        esac
        shift || true
    done
}

ensure_whiptail() {
    if command -v whiptail >/dev/null 2>&1; then
        return 0
    fi
    print_info "Installing whiptail for TUI..."
    apt-get update -qq || true
    apt-get install -y whiptail >/dev/null 2>&1 || {
        print_warning "Could not install whiptail; continuing without TUI"
        return 1
    }
}

run_tui() {
    # Decide whether to run TUI
    if [ "$USE_TUI" = "no" ]; then
        return 0
    fi
    if [ "$USE_TUI" = "auto" ]; then
        if [ ! -t 0 ] || [ ! -t 1 ]; then
            # Non-interactive environment
            return 0
        fi
    fi

    # Ensure whiptail present (best-effort)
    ensure_whiptail || return 0
    TUI_USED=1
    local interval_input
    local ping_input
    local bridges_input
    local summary_input

    # Checklist for components
    local checklist_output
    if ! checklist_output=$(whiptail --title "Proxmox Health Installer" \
        --checklist "Select components to install" 20 78 10 \
        deps "Install system dependencies" ON \
        config "Install configuration files" ON \
        libs "Install library files" ON \
        bins "Install binaries (CLI scripts)" ON \
        cron "Install cron schedule" ON \
        logrotate "Install logrotate configuration" ON \
        systemd "Install systemd service + timer" ON \
        examples "Create example configs" ON \
        init "Setup initial configuration" ON 3>&1 1>&2 2>&3); then
        print_warning "Installation cancelled by user"
        exit 1
    fi

    # Reset all to 0 then set selected to 1
    SELECT_DEPS=0; SELECT_CONFIG=0; SELECT_LIBS=0; SELECT_BINS=0; SELECT_CRON=0; SELECT_LOGROTATE=0; SELECT_SYSTEMD=0; SELECT_EXAMPLES=0; SELECT_INIT=0
    for tag in $checklist_output; do
        case "$tag" in
            "\"deps\"") SELECT_DEPS=1 ;;
            "\"config\"") SELECT_CONFIG=1 ;;
            "\"libs\"") SELECT_LIBS=1 ;;
            "\"bins\"") SELECT_BINS=1 ;;
            "\"cron\"") SELECT_CRON=1 ;;
            "\"logrotate\"") SELECT_LOGROTATE=1 ;;
            "\"systemd\"") SELECT_SYSTEMD=1 ;;
            "\"examples\"") SELECT_EXAMPLES=1 ;;
            "\"init\"") SELECT_INIT=1 ;;
        esac
    done

    # Scheduler choice (systemd vs cron)
    local sched_choice
    sched_choice=$(whiptail --title "Scheduler" --radiolist "Choose how to schedule health checks" 12 78 2 \
        systemd "Use systemd timer (recommended)" ON \
        cron "Use cron" OFF 3>&1 1>&2 2>&3) || true
    case "$sched_choice" in
        "systemd") SELECT_SYSTEMD=1; SELECT_CRON=0 ;;
        "cron") SELECT_SYSTEMD=0; SELECT_CRON=1 ;;
        *) : ;; # keep previous selections
    esac

    # Health check interval input
    while true; do
        if interval_input=$(whiptail --title "Health Check Interval" \
            --inputbox "How often should the health checks run? (minutes)" 10 78 "$TUI_HEALTH_INTERVAL" 3>&1 1>&2 2>&3); then
            if is_positive_integer "$interval_input"; then
                TUI_HEALTH_INTERVAL="$interval_input"
                break
            fi
            whiptail --title "Invalid Interval" --msgbox "Enter a positive integer value (minutes)." 10 78
        else
            break
        fi
    done

    # Ping host input
    while true; do
        if ping_input=$(whiptail --title "Ping Test Host" \
            --inputbox "Which host should be used for connectivity checks?" 10 78 "$TUI_PING_HOST" 3>&1 1>&2 2>&3); then
            local sanitized_host
            sanitized_host=$(sanitize_host_target "$ping_input")
            if [ -n "$sanitized_host" ] && is_valid_host_target "$sanitized_host"; then
                TUI_PING_HOST="$sanitized_host"
                break
            fi
            whiptail --title "Invalid Host" --msgbox "Use a hostname or IP without spaces." 10 78
        else
            break
        fi
    done

    # Bridge list input (allow empty to disable bridge monitoring)
    while true; do
        if bridges_input=$(whiptail --title "Network Bridges" \
            --inputbox "Space-separated list of network bridges to monitor" 10 78 "$TUI_MONITORED_BRIDGES" 3>&1 1>&2 2>&3); then
            local sanitized_bridges
            sanitized_bridges=$(sanitize_bridge_list "$bridges_input")
            if [ -z "$sanitized_bridges" ] || is_valid_bridge_list "$sanitized_bridges"; then
                TUI_MONITORED_BRIDGES="$sanitized_bridges"
                break
            fi
            whiptail --title "Invalid Bridges" --msgbox "Bridge names may contain letters, numbers, '.', '-', '_' or ':'." 10 78
        else
            break
        fi
    done

    # Summary time input
    while true; do
        if summary_input=$(whiptail --title "Daily Summary Time" \
            --inputbox "When should the daily summary run? (HH:MM, 24-hour)" 10 78 "$TUI_SUMMARY_TIME" 3>&1 1>&2 2>&3); then
            if is_valid_time_24h "$summary_input"; then
                local summary_hour_dec=$((10#${summary_input%:*}))
                local summary_min_dec=$((10#${summary_input#*:}))
                TUI_SUMMARY_TIME=$(printf '%02d:%02d' "$summary_hour_dec" "$summary_min_dec")
                break
            fi
            whiptail --title "Invalid Time" --msgbox "Enter time as HH:MM using 24-hour format." 10 78
        else
            break
        fi
    done

    # Optional: webhook URL
    if whiptail --title "Notifications" --yesno "Do you want to configure a Discord webhook URL now?" 10 78; then
        local url
        while true; do
            url=$(whiptail --title "Discord Webhook" --inputbox "Enter Discord webhook URL" 10 78 "${TUI_WEBHOOK_URL:-}" 3>&1 1>&2 2>&3) || {
                # user cancelled input; keep existing value
                break
            }

            if [ -z "${url:-}" ]; then
                # Blank input clears the stored URL
                TUI_WEBHOOK_URL=""
                break
            fi

            TUI_WEBHOOK_URL="$url"

            if ! echo "$TUI_WEBHOOK_URL" | grep -Eq '^https://(discord|discordapp)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_\-]+'; then
                whiptail --title "Webhook Warning" --yesno "The URL doesn't look like a Discord webhook. Keep it anyway?" 10 78 || {
                    # try again
                    continue
                }
            else
                if whiptail --title "Send Test" --yesno "Send a test message to the webhook now?" 10 78; then
                    if curl -s -H "Content-Type: application/json" -X POST -d "{\"content\":\"Proxmox Health: webhook test successful\"}" "$TUI_WEBHOOK_URL" >/dev/null 2>&1; then
                        whiptail --title "Webhook Test" --msgbox "Test message sent successfully." 8 60
                    else
                        whiptail --title "Webhook Test" --msgbox "Failed to send test message. Check the URL or network." 8 60
                    fi
                fi
            fi
            break
        done
    fi

    # Checklist: what should the cron job do (which checks to run)
    local checks_output
    if checks_output=$(whiptail --title "Cron Tasks" \
        --checklist "Select which health checks cron should run" 22 78 14 \
        services "Check Proxmox services" ON \
        disk "Check disk usage" ON \
        zfs "Check ZFS pools" ON \
        memory "Check memory/swap" ON \
        load "Check load average" ON \
        iowait "Check I/O wait" ON \
        network "Check network & bridges" ON \
        iface_errors "Track NIC error deltas" ON \
        ssh "Check SSH security" ON \
        sys_events "Check OOM & system events" ON \
        temps "Check CPU/drive temperatures" ON \
        backups "Check backups & recency" ON \
        updates "Check security updates" ON \
        vms "Monitor VM/CT start/stop" ON 3>&1 1>&2 2>&3); then
        # Reset all to 0 then set selected to 1
        TUI_CHECK_SERVICES=0; TUI_CHECK_DISK=0; TUI_CHECK_ZFS=0; TUI_CHECK_MEMORY=0; TUI_CHECK_LOAD=0; TUI_CHECK_IOWAIT=0; TUI_CHECK_NETWORK=0; TUI_CHECK_IFACE_ERRORS=0; TUI_CHECK_SSH=0; TUI_CHECK_SYS_EVENTS=0; TUI_CHECK_TEMPS=0; TUI_CHECK_BACKUPS=0; TUI_CHECK_UPDATES=0; TUI_CHECK_VMS=0
        for tag in $checks_output; do
            case "$tag" in
                "\"services\"") TUI_CHECK_SERVICES=1 ;;
                "\"disk\"") TUI_CHECK_DISK=1 ;;
                "\"zfs\"") TUI_CHECK_ZFS=1 ;;
                "\"memory\"") TUI_CHECK_MEMORY=1 ;;
                "\"load\"") TUI_CHECK_LOAD=1 ;;
                "\"iowait\"") TUI_CHECK_IOWAIT=1 ;;
                "\"network\"") TUI_CHECK_NETWORK=1 ;;
                "\"iface_errors\"") TUI_CHECK_IFACE_ERRORS=1 ;;
                "\"ssh\"") TUI_CHECK_SSH=1 ;;
                "\"sys_events\"") TUI_CHECK_SYS_EVENTS=1 ;;
                "\"temps\"") TUI_CHECK_TEMPS=1 ;;
                "\"backups\"") TUI_CHECK_BACKUPS=1 ;;
                "\"updates\"") TUI_CHECK_UPDATES=1 ;;
                "\"vms\"") TUI_CHECK_VMS=1 ;;
            esac
        done
    fi

    # Checklist: what should it notify about (topics)
    local notify_output
    if notify_output=$(whiptail --title "Notification Topics" \
        --checklist "Select topics that should send Discord/Email notifications" 22 78 14 \
        services "Service status" ON \
        disk "Disk usage" ON \
        zfs "ZFS health/capacity" ON \
        memory "Memory/swap" ON \
        load "Load average" ON \
        iowait "I/O wait" ON \
        network "Network & bridges" ON \
        iface_errors "NIC error deltas" ON \
        ssh "SSH anomalies" ON \
        sys_events "OOM & system events" ON \
        temps "CPU/drive temperatures" ON \
        backups "Backup jobs & recency" ON \
        updates "Security updates" ON \
        vms "VM/CT state changes" ON 3>&1 1>&2 2>&3); then
        # Reset all to 0 then set selected to 1
        TUI_NOTIFY_SERVICES=0; TUI_NOTIFY_DISK=0; TUI_NOTIFY_ZFS=0; TUI_NOTIFY_MEMORY=0; TUI_NOTIFY_LOAD=0; TUI_NOTIFY_IOWAIT=0; TUI_NOTIFY_NETWORK=0; TUI_NOTIFY_IFACE_ERRORS=0; TUI_NOTIFY_SSH=0; TUI_NOTIFY_SYS_EVENTS=0; TUI_NOTIFY_TEMPS=0; TUI_NOTIFY_BACKUPS=0; TUI_NOTIFY_UPDATES=0; TUI_NOTIFY_VMS=0
        for tag in $notify_output; do
            case "$tag" in
                "\"services\"") TUI_NOTIFY_SERVICES=1 ;;
                "\"disk\"") TUI_NOTIFY_DISK=1 ;;
                "\"zfs\"") TUI_NOTIFY_ZFS=1 ;;
                "\"memory\"") TUI_NOTIFY_MEMORY=1 ;;
                "\"load\"") TUI_NOTIFY_LOAD=1 ;;
                "\"iowait\"") TUI_NOTIFY_IOWAIT=1 ;;
                "\"network\"") TUI_NOTIFY_NETWORK=1 ;;
                "\"iface_errors\"") TUI_NOTIFY_IFACE_ERRORS=1 ;;
                "\"ssh\"") TUI_NOTIFY_SSH=1 ;;
                "\"sys_events\"") TUI_NOTIFY_SYS_EVENTS=1 ;;
                "\"temps\"") TUI_NOTIFY_TEMPS=1 ;;
                "\"backups\"") TUI_NOTIFY_BACKUPS=1 ;;
                "\"updates\"") TUI_NOTIFY_UPDATES=1 ;;
                "\"vms\"") TUI_NOTIFY_VMS=1 ;;
            esac
        done
    fi

    HEALTH_CHECK_INTERVAL_MINUTES="$TUI_HEALTH_INTERVAL"
    PING_TEST_HOST="$TUI_PING_HOST"
    MONITORED_BRIDGES="$TUI_MONITORED_BRIDGES"
    DAILY_SUMMARY_TIME="$TUI_SUMMARY_TIME"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

check_proxmox() {
    if [ ! -f "/etc/debian_version" ] || [ ! -d "/etc/pve" ]; then
        print_warning "This doesn't appear to be a Proxmox system. Continue anyway? [y/N]"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

backup_existing_installation() {
    if [ -d "$INSTALL_DIR" ] || [ -f "$CRON_FILE" ]; then
        print_info "Backing up existing installation..."
        local backup_dir
        backup_dir="/tmp/proxmox-health-backup-$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"

        if [ -d "$INSTALL_DIR" ]; then
            cp -r "$INSTALL_DIR" "$backup_dir/"
        fi

        if [ -f "$CRON_FILE" ]; then
            cp "$CRON_FILE" "$backup_dir/"
        fi

        for unit in "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER" "$SYSTEMD_SUMMARY_SERVICE" "$SYSTEMD_SUMMARY_TIMER"; do
            if [ -f "$unit" ]; then
                cp "$unit" "$backup_dir/"
            fi
        done

        print_status "Backup saved to $backup_dir"
    fi
}

install_dependencies() {
    print_info "Installing required dependencies..."

    # Update package lists
    apt-get update -qq

    # Install required packages
    local packages=("smartmontools" "lm-sensors" "curl" "ipmitool" "systemd" "logrotate" "whiptail")

    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            print_info "Installing $package..."
            apt-get install -y "$package" >/dev/null 2>&1
        else
            print_info "$package is already installed"
        fi
    done

    print_status "Dependencies installed successfully"
}

install_configuration() {
    print_info "Installing configuration files..."

    # Create main configuration directory
    mkdir -p "$INSTALL_DIR"

    # Copy configuration file
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$INSTALL_DIR/proxmox-health.conf"
    else
        print_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    # Create webhook secret file (from TUI if provided) or template
    mkdir -p "$(dirname "$WEBHOOK_SECRET_FILE")"
    chmod 700 "$(dirname "$WEBHOOK_SECRET_FILE")"
    if [ -n "${TUI_WEBHOOK_URL:-}" ]; then
        echo "$TUI_WEBHOOK_URL" > "$WEBHOOK_SECRET_FILE"
        chmod 600 "$WEBHOOK_SECRET_FILE"
        chown root:root "$WEBHOOK_SECRET_FILE" 2>/dev/null || true
        print_status "Saved Discord webhook URL to $WEBHOOK_SECRET_FILE"
    else
        if [ ! -f "$WEBHOOK_SECRET_FILE" ]; then
            print_warning "Webhook secret file not found. Please create it with your Discord webhook URL."
            print_info "Create file: $WEBHOOK_SECRET_FILE"
            print_info "Content: your_discord_webhook_url"
            touch "$WEBHOOK_SECRET_FILE"
            chmod 600 "$WEBHOOK_SECRET_FILE"
            chown root:root "$WEBHOOK_SECRET_FILE" 2>/dev/null || true
        fi
    fi

    # Create directories
    mkdir -p "$LIB_DIR"
    mkdir -p "/var/tmp/proxmox-health"
    mkdir -p "/var/log/proxmox-health"
    mkdir -p "$INSTALL_DIR/custom-checks"
    mkdir -p "$INSTALL_DIR/plugins"

    # Set permissions
    chmod 755 "$INSTALL_DIR"
    chmod 755 "$LIB_DIR"
    chmod 755 "/var/tmp/proxmox-health"
    chmod 755 "/var/log/proxmox-health"
    chmod 755 "$INSTALL_DIR/custom-checks"
    chmod 755 "$INSTALL_DIR/plugins"
    chmod 600 "$WEBHOOK_SECRET_FILE"

    # Apply TUI preferences into conf.local (idempotent)
    if [ "$TUI_USED" -eq 1 ]; then
        local local_conf="$INSTALL_DIR/proxmox-health.conf.local"
        [ -f "$local_conf" ] || {
            echo "# Local overrides generated by installer" > "$local_conf"
            chmod 644 "$local_conf"
        }
        update_conf_kv() {
            local file="$1" key="$2" value="$3"
            if grep -q "^$key=" "$file"; then
                sed -i "s|^$key=.*|$key=$value|" "$file"
            else
                echo "$key=$value" >> "$file"
            fi
        }
        update_conf_kv "$local_conf" HEALTH_CHECK_INTERVAL_MINUTES "$TUI_HEALTH_INTERVAL"
        update_conf_kv "$local_conf" PING_TEST_HOST "\"$TUI_PING_HOST\""
        update_conf_kv "$local_conf" MONITORED_BRIDGES "\"$TUI_MONITORED_BRIDGES\""
        update_conf_kv "$local_conf" DAILY_SUMMARY_TIME "\"$TUI_SUMMARY_TIME\""
        update_conf_kv "$local_conf" ENABLE_CHECK_SERVICES "$( [ "$TUI_CHECK_SERVICES" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_DISK "$( [ "$TUI_CHECK_DISK" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_ZFS "$( [ "$TUI_CHECK_ZFS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_MEMORY "$( [ "$TUI_CHECK_MEMORY" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_LOAD "$( [ "$TUI_CHECK_LOAD" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_IOWAIT "$( [ "$TUI_CHECK_IOWAIT" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_NETWORK "$( [ "$TUI_CHECK_NETWORK" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_INTERFACE_ERRORS "$( [ "$TUI_CHECK_IFACE_ERRORS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_SSH "$( [ "$TUI_CHECK_SSH" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_SYSTEM_EVENTS "$( [ "$TUI_CHECK_SYS_EVENTS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_TEMPS "$( [ "$TUI_CHECK_TEMPS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_BACKUPS "$( [ "$TUI_CHECK_BACKUPS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_UPDATES "$( [ "$TUI_CHECK_UPDATES" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" ENABLE_CHECK_VMS "$( [ "$TUI_CHECK_VMS" -eq 1 ] && echo yes || echo no )"

        update_conf_kv "$local_conf" NOTIFY_SERVICES "$( [ "$TUI_NOTIFY_SERVICES" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_DISK "$( [ "$TUI_NOTIFY_DISK" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_ZFS "$( [ "$TUI_NOTIFY_ZFS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_MEMORY "$( [ "$TUI_NOTIFY_MEMORY" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_LOAD "$( [ "$TUI_NOTIFY_LOAD" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_IOWAIT "$( [ "$TUI_NOTIFY_IOWAIT" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_NETWORK "$( [ "$TUI_NOTIFY_NETWORK" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_INTERFACE_ERRORS "$( [ "$TUI_NOTIFY_IFACE_ERRORS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_SSH "$( [ "$TUI_NOTIFY_SSH" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_SYSTEM_EVENTS "$( [ "$TUI_NOTIFY_SYS_EVENTS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_TEMPS "$( [ "$TUI_NOTIFY_TEMPS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_BACKUPS "$( [ "$TUI_NOTIFY_BACKUPS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_UPDATES "$( [ "$TUI_NOTIFY_UPDATES" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_VMS "$( [ "$TUI_NOTIFY_VMS" -eq 1 ] && echo yes || echo no )"
        update_conf_kv "$local_conf" NOTIFY_MIN_LEVEL "${TUI_NOTIFY_MIN_LEVEL:-info}"

        print_status "Applied TUI preferences to $local_conf"
    fi

    print_status "Configuration files installed successfully"
}

install_libraries() {
    print_info "Installing library files..."

    # Copy library files
    if [ -d "$SCRIPT_DIR/lib" ]; then
        cp "$SCRIPT_DIR/lib/"*.sh "$LIB_DIR/"
        chmod 644 "$LIB_DIR/"*.sh
        print_status "Library files installed successfully"
    else
        print_error "Library directory not found: $SCRIPT_DIR/lib"
        exit 1
    fi
}

install_binaries() {
    print_info "Installing binary files..."

    # Create main health check script
    cat > "$BIN_DIR/proxmox-healthcheck.sh" << 'EOF'
#!/bin/bash
# Proxmox Health Check Main Script
# This is the main script that runs all health checks

# Load configuration and libraries
source "/etc/proxmox-health/proxmox-health.conf"
source "/usr/local/lib/proxmox-health/utils.sh"
source "/usr/local/lib/proxmox-health/notifications.sh"
source "/usr/local/lib/proxmox-health/health-checks.sh"

# Main function
main() {
    # Acquire global lock to prevent overlapping runs
    local lock_file="/run/proxmox-health/health.lock"
    mkdir -p "/run/proxmox-health" 2>/dev/null || true
    exec 9>"$lock_file"
    if ! flock -n 9; then
        log_info "Another health check run is in progress; exiting."
        exit 0
    fi

    # Initialize system
    initialize_system

    # Set up signal handlers
    setup_signal_handlers

    # Create PID file (use runtime directory under /run)
    local pid_file="/run/proxmox-health/proxmox-healthcheck.pid"
    mkdir -p "/run/proxmox-health" 2>/dev/null || true
    create_pid_file "$pid_file"

    # Log startup
    log_info "Starting Proxmox Health Check (version $(get_script_version))"

    # Check maintenance mode
    if check_maintenance_mode; then
        log_info "Maintenance mode active - skipping health checks"
        exit 0
    fi

    # Run health checks
    local exit_code=0
    if ! run_all_health_checks; then
        exit_code=1
    fi

    # Clean up
    remove_pid_file "$pid_file"

    log_info "Health check completed with exit code: $exit_code"
    exit $exit_code
}

# Run main function
main "$@"
EOF

    # Create notification test script
    cat > "$BIN_DIR/proxmox-notify.sh" << 'EOF'
#!/bin/bash
# Proxmox Notification Script
# This script sends notifications

# Load configuration and libraries
source "/etc/proxmox-health/proxmox-health.conf"
source "/usr/local/lib/proxmox-health/utils.sh"
source "/usr/local/lib/proxmox-health/notifications.sh"

# Main function
main() {
    local message="${1:-Test message}"
    local level="${2:-info}"

    # Initialize system
    initialize_system

    # Send notification
    send_notification "$message" "$level" "manual"
}

# Run main function
main "$@"
EOF

    # Create daily summary script
    cat > "$BIN_DIR/proxmox-health-summary.sh" << 'EOF'
#!/bin/bash
# Proxmox Health Daily Summary
# Generates and sends the daily alert summary

# Load configuration and libraries
source "/etc/proxmox-health/proxmox-health.conf"
source "/usr/local/lib/proxmox-health/utils.sh"
source "/usr/local/lib/proxmox-health/notifications.sh"

main() {
    initialize_system
    send_alert_summary
}

main "$@"
EOF

    # Create maintenance mode script
    cat > "$BIN_DIR/proxmox-maintenance.sh" << 'EOF'
#!/bin/bash
# Proxmox Maintenance Mode Script
# This script manages maintenance mode

# Load configuration and libraries
source "/etc/proxmox-health/proxmox-health.conf"
source "/usr/local/lib/proxmox-health/utils.sh"
source "/usr/local/lib/proxmox-health/notifications.sh"

# Show usage
show_usage() {
    cat << USAGE
Usage: $0 <command> [options]

Commands:
  enable  [duration] [reason]  Enable maintenance mode
  disable                      Disable maintenance mode
  status                       Show maintenance mode status
  help                         Show this help message

Duration examples:
  1h, 2h30m, 1d, 1w (0 for indefinite)

Examples:
  $0 enable 2h "System maintenance"
  $0 enable 0 "Indefinite maintenance"
  $0 disable
  $0 status
USAGE
}

# Main function
main() {
    local command="${1:-help}"

    case "$command" in
        "enable")
            local duration="${2:-1h}"
            local reason="${3:-Scheduled maintenance}"
            enable_maintenance_mode "$duration" "$reason"
            ;;
        "disable")
            disable_maintenance_mode
            ;;
        "status")
            if check_maintenance_mode; then
                echo "Maintenance mode is ACTIVE"
                if [ -f "$MAINTENANCE_MODE_FILE" ]; then
                    echo "Reason: $(cat "$MAINTENANCE_MODE_FILE")"
                fi
            else
                echo "Maintenance mode is INACTIVE"
            fi
            ;;
        "help"|*)
            show_usage
            ;;
    esac
}

# Run main function
main "$@"
EOF

    # Set permissions
    chmod 755 "$BIN_DIR/proxmox-healthcheck.sh"
    chmod 755 "$BIN_DIR/proxmox-notify.sh"
    chmod 755 "$BIN_DIR/proxmox-health-summary.sh"
    chmod 755 "$BIN_DIR/proxmox-maintenance.sh"

    print_status "Binary scripts installed successfully"
}

install_cron() {
    print_info "Installing cron configuration..."

    local summary_hour="${DAILY_SUMMARY_TIME%:*}"
    local summary_minute="${DAILY_SUMMARY_TIME#*:}"

    cat > "$CRON_FILE" << EOF
# Proxmox Health Monitoring System
# Health check every $HEALTH_CHECK_INTERVAL_MINUTES minutes
*/$HEALTH_CHECK_INTERVAL_MINUTES * * * * root $BIN_DIR/proxmox-healthcheck.sh

# ZFS scrub monthly (if ZFS installed)
0 3 $ZFS_SCRUB_DAY_OF_MONTH * * root command -v zpool >/dev/null 2>/dev/null && zpool scrub rpool

# Logrotate daily
0 $LOGROTATE_HOUR * * * root /usr/sbin/logrotate /etc/logrotate.d/proxmox-health

# System cleanup weekly
$APT_HOUSEKEEPING_MINUTE $APT_HOUSEKEEPING_HOUR * * $APT_HOUSEKEEPING_DAY_OF_WEEK root apt-get update -qq && apt-get -y autoremove -qq && apt-get clean -qq

# Daily summary report
$summary_minute $summary_hour * * * root $BIN_DIR/proxmox-health-summary.sh

# Cache cleanup
0 2 * * * root find /var/tmp/proxmox-health -name "cache_*" -mtime +1 -delete 2>/dev/null || true
EOF

    chmod 644 "$CRON_FILE"

    print_status "Cron configuration installed successfully"
}

install_logrotate() {
    print_info "Installing logrotate configuration..."

    cat > "$LOGROTATE_FILE" << EOF
/var/log/proxmox-health/*.log {
    daily
    missingok
    rotate $LOG_ROTATION_COUNT
    compress
    delaycompress
    notifempty
    create 644 root root
    size $LOG_MAX_SIZE_MB
    postrotate
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}
EOF

    chmod 644 "$LOGROTATE_FILE"

    print_status "Logrotate configuration installed successfully"
}

install_systemd() {
    print_info "Installing systemd service..."

    cat > "$SYSTEMD_SERVICE" << EOF
[Unit]
Description=Proxmox Health Monitoring Service
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/proxmox-healthcheck.sh
User=root
Group=root
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RuntimeDirectory=proxmox-health
ReadWritePaths=/etc/proxmox-health /var/tmp/proxmox-health /var/log/proxmox-health /run/proxmox-health
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=proxmox-health

[Install]
WantedBy=multi-user.target
EOF

    cat > "$SYSTEMD_TIMER" << EOF
[Unit]
Description=Run Proxmox Health Check Periodically
Requires=proxmox-health.service

[Timer]
OnCalendar=*:0/$HEALTH_CHECK_INTERVAL_MINUTES
Persistent=true
RandomizedDelaySec=90s
AccuracySec=1m

[Install]
WantedBy=timers.target
EOF

    cat > "$SYSTEMD_SUMMARY_SERVICE" << EOF
[Unit]
Description=Proxmox Health Daily Summary
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/proxmox-health-summary.sh
User=root
Group=root
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RuntimeDirectory=proxmox-health
ReadWritePaths=/etc/proxmox-health /var/tmp/proxmox-health /var/log/proxmox-health /run/proxmox-health /var/lib/apt /var/cache/apt
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=proxmox-health-summary

[Install]
WantedBy=multi-user.target
EOF

    cat > "$SYSTEMD_SUMMARY_TIMER" << EOF
[Unit]
Description=Send Proxmox Health Daily Summary
Requires=proxmox-health-summary.service

[Timer]
OnCalendar=*-*-* $DAILY_SUMMARY_TIME
Persistent=true
RandomizedDelaySec=2m
AccuracySec=1m

[Install]
WantedBy=timers.target
EOF

    chmod 644 "$SYSTEMD_SERVICE"
    chmod 644 "$SYSTEMD_TIMER"
    chmod 644 "$SYSTEMD_SUMMARY_SERVICE"
    chmod 644 "$SYSTEMD_SUMMARY_TIMER"

    # Clean up legacy filenames (from versions that wrote *.service.timer)
    rm -f "${SYSTEMD_SERVICE}.timer" "${SYSTEMD_SUMMARY_SERVICE}.timer" 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable proxmox-health.timer
    systemctl start proxmox-health.timer
    systemctl enable proxmox-health-summary.timer
    systemctl start proxmox-health-summary.timer

    print_status "Systemd services installed and started"
}

create_example_configs() {
    print_info "Creating example configuration files..."

    # Create example custom check
    cat > "$INSTALL_DIR/custom-checks/example-custom-check.sh" << 'EOF'
#!/bin/bash
# Example Custom Health Check
# This is an example of how to create custom health checks

# Load configuration
source "/etc/proxmox-health/proxmox-health.conf"
source "/usr/local/lib/proxmox-health/utils.sh"
source "/usr/local/lib/proxmox-health/notifications.sh"

# Custom check function
check_custom_service() {
    local service_name="example-service"

    if systemctl is-active --quiet "$service_name"; then
        alert_clear "custom-$service_name" "Custom service $service_name is running"
        return 0
    else
        alert_once "custom-$service_name" "warning" "Custom service $service_name is down" "Custom service $service_name restored"
        return 1
    fi
}

# Run the check
check_custom_service
EOF

    chmod 755 "$INSTALL_DIR/custom-checks/example-custom-check.sh"

    # Create example plugin
    cat > "$INSTALL_DIR/plugins/example-plugin.sh" << 'EOF'
#!/bin/bash
# Example Plugin
# This is an example of how to create plugins

# Plugin information
PLUGIN_NAME="example"
PLUGIN_VERSION="1.0.0"
PLUGIN_DESCRIPTION="Example plugin for demonstration"

# Plugin function
plugin_example_check() {
    log_info "Running example plugin check"

    # Example: Check disk I/O performance
    local io_wait=$(iostat -c 1 2 | awk 'NR==4 {print $4}')

    if [ "${io_wait:-0}" -gt 50 ]; then
        alert_once "plugin-$PLUGIN_NAME-io-wait" "warning" "High I/O wait detected: ${io_wait}%" "I/O wait restored"
        return 1
    else
        alert_clear "plugin-$PLUGIN_NAME-io-wait" "I/O wait normal: ${io_wait}%"
        return 0
    fi
}

# Plugin initialization
plugin_init() {
    log_info "Initializing $PLUGIN_NAME plugin"
}

# Plugin cleanup
plugin_cleanup() {
    log_info "Cleaning up $PLUGIN_NAME plugin"
}

# Export functions
export -f plugin_example_check plugin_init plugin_cleanup
EOF

    chmod 644 "$INSTALL_DIR/plugins/example-plugin.sh"

    print_status "Example configuration files created"
}

setup_initial_configuration() {
    print_info "Setting up initial configuration..."

    # Detect and set some sensible defaults
    local total_memory
    total_memory=$(free -m | awk '/Mem:/ {print $2}')
    local memory_warn=$((total_memory * 90 / 100))
    local memory_crit=$((total_memory * 95 / 100))

    # Create initial configuration based on system specs
    cat > "$INSTALL_DIR/proxmox-health.conf.local" << EOF
# Local configuration overrides
# This file contains system-specific settings

# Memory thresholds adjusted for this system
MEMORY_WARNING_THRESHOLD=$memory_warn
MEMORY_CRITICAL_THRESHOLD=$memory_crit

# CPU cores detected
CPU_CORES=$(nproc)

# Disk usage detected
ROOT_DISK_SIZE=$(df -h / | awk 'NR==2 {print $2}')

# System information
SYSTEM_HOSTNAME=$(hostname)
SYSTEM_KERNEL=$(uname -r)
SYSTEM_UPTIME="$(uptime -p)"

# Detection timestamp
CONFIG_GENERATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    chmod 644 "$INSTALL_DIR/proxmox-health.conf.local"

    print_status "Initial configuration set up"
}

test_installation() {
    print_info "Testing installation..."

    local rc

    if [ -x "$BIN_DIR/proxmox-healthcheck.sh" ]; then
        if "$BIN_DIR/proxmox-healthcheck.sh" --help >/dev/null 2>&1; then
            print_status "Main health check script is working"
        else
            rc=$?
            print_warning "Health check self-test exited with $rc (continuing)"
        fi
    else
        print_warning "Main health check script not found at $BIN_DIR/proxmox-healthcheck.sh"
    fi

    if [ -x "$BIN_DIR/proxmox-notify.sh" ]; then
        if "$BIN_DIR/proxmox-notify.sh" "Test notification" "info" >/dev/null 2>&1; then
            print_status "Notification script is working"
        else
            rc=$?
            print_warning "Notification test exited with $rc (continuing)"
        fi
    else
        print_warning "Notification script not found at $BIN_DIR/proxmox-notify.sh"
    fi

    if [ -x "$BIN_DIR/proxmox-maintenance.sh" ]; then
        if "$BIN_DIR/proxmox-maintenance.sh" enable 1m "Installation test" >/dev/null 2>&1; then
            if "$BIN_DIR/proxmox-maintenance.sh" status 2>/dev/null | grep -q "ACTIVE"; then
                print_status "Maintenance mode script is working"
                "$BIN_DIR/proxmox-maintenance.sh" disable >/dev/null 2>&1 || true
            else
                print_warning "Maintenance status check did not report ACTIVE (continuing)"
            fi
        else
            rc=$?
            print_warning "Maintenance mode enable exited with $rc (continuing)"
        fi
    else
        print_warning "Maintenance script not found at $BIN_DIR/proxmox-maintenance.sh"
    fi

    print_status "Installation smoke tests completed"
}

show_completion_message() {
    cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Proxmox Health Monitoring System v$SCRIPT_VERSION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ Installation completed successfully

⚙️ Configuration
  • Main config:            $INSTALL_DIR/proxmox-health.conf
  • Webhook secret:         $WEBHOOK_SECRET_FILE
  • Local overrides:        $INSTALL_DIR/proxmox-health.conf.local

🧰 Installed Scripts
  • $BIN_DIR/proxmox-healthcheck.sh
  • $BIN_DIR/proxmox-notify.sh
  • $BIN_DIR/proxmox-health-summary.sh
  • $BIN_DIR/proxmox-maintenance.sh

📁 Example Assets
  • Custom check: $INSTALL_DIR/custom-checks/example-custom-check.sh
  • Plugin:       $INSTALL_DIR/plugins/example-plugin.sh

🚀 Suggested Next Steps
  1. Review cluster-specific overrides in $INSTALL_DIR/proxmox-health.conf.local
  2. Trigger a manual health check:
       $BIN_DIR/proxmox-healthcheck.sh
  3. Verify notifications in your Discord channel
  4. Tail logs as needed:
       tail -f /var/log/proxmox-health/proxmox-health.log

🛠 Useful Commands
  • Maintenance status:   $BIN_DIR/proxmox-maintenance.sh status
  • Enable maintenance:   $BIN_DIR/proxmox-maintenance.sh enable 2h "Reason"
  • Disable maintenance:  $BIN_DIR/proxmox-maintenance.sh disable
  • Manual health check:  $BIN_DIR/proxmox-healthcheck.sh

Logs and timers are active—monitoring starts now. 🌐
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

# --- Main Installation Process ---
main() {
    print_info "Starting Proxmox Health Monitoring System installation..."
    print_info "Version: $SCRIPT_VERSION"

    # Check prerequisites
    check_root
    check_proxmox

    # Parse CLI args and optionally run TUI
    parse_args "$@"
    run_tui

    # Reconfigure-only flow
    if [ "$MODE" = "configure" ]; then
        install_configuration
        # Ensure chosen scheduler exists
        if [ "$SELECT_SYSTEMD" -eq 1 ] && [ ! -f "$SYSTEMD_SERVICE" ]; then
            install_systemd
        fi
        if [ "$SELECT_CRON" -eq 1 ] && [ ! -f "$CRON_FILE" ]; then
            install_cron
        fi
        configure_scheduler_selection
        print_status "Reconfiguration completed"
        exit 0
    fi

    # Backup existing installation
    backup_existing_installation

    # Install components (based on TUI selections)
    if [ "$SELECT_DEPS" -eq 1 ]; then install_dependencies; else print_info "Skipped dependencies"; fi
    if [ "$SELECT_CONFIG" -eq 1 ]; then install_configuration; else print_info "Skipped configuration files"; fi
    if [ "$SELECT_LIBS" -eq 1 ]; then install_libraries; else print_info "Skipped libraries"; fi
    if [ "$SELECT_BINS" -eq 1 ]; then install_binaries; else print_info "Skipped binaries"; fi
    if [ "$SELECT_CRON" -eq 1 ]; then install_cron; else print_info "Skipped cron"; fi
    if [ "$SELECT_LOGROTATE" -eq 1 ]; then install_logrotate; else print_info "Skipped logrotate"; fi
    if [ "$SELECT_SYSTEMD" -eq 1 ]; then install_systemd; else print_info "Skipped systemd"; fi
    if [ "$SELECT_EXAMPLES" -eq 1 ]; then create_example_configs; else print_info "Skipped example configs"; fi
    if [ "$SELECT_INIT" -eq 1 ]; then setup_initial_configuration; else print_info "Skipped initial configuration"; fi

    # Apply scheduler selection
    configure_scheduler_selection

    # Test installation (only if core components were installed)
    if [ "$SELECT_BINS" -eq 1 ] && [ "$SELECT_LIBS" -eq 1 ] && [ "$SELECT_CONFIG" -eq 1 ]; then
        test_installation
    else
        print_info "Skipping tests because core components were not fully installed"
    fi

    # Show completion message
    show_completion_message

    print_status "Installation completed successfully!"
}

configure_scheduler_selection() {
    # If systemd selected, remove cron entry; if cron selected, disable systemd timer
    if [ "$SELECT_SYSTEMD" -eq 1 ] && [ "$SELECT_CRON" -eq 0 ]; then
        if [ -f "$CRON_FILE" ]; then
            rm -f "$CRON_FILE"
            print_info "Removed cron schedule in favor of systemd timer"
        fi
        systemctl enable proxmox-health.timer >/dev/null 2>&1 || true
        systemctl start proxmox-health.timer >/dev/null 2>&1 || true
        systemctl enable proxmox-health-summary.timer >/dev/null 2>&1 || true
        systemctl start proxmox-health-summary.timer >/dev/null 2>&1 || true
    fi
    if [ "$SELECT_CRON" -eq 1 ] && [ "$SELECT_SYSTEMD" -eq 0 ]; then
        systemctl disable --now proxmox-health.timer >/dev/null 2>&1 || true
        systemctl disable --now proxmox-health-summary.timer >/dev/null 2>&1 || true
        print_info "Disabled systemd timer in favor of cron"
    fi
}

# Run main function when executed directly
# shellcheck disable=SC2317
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0 2>/dev/null || exit 0
fi

main "$@"
