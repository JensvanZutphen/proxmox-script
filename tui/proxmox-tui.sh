#!/bin/bash

# Proxmox Health Monitoring - TUI Interface
# This script provides a text-based user interface for managing the Proxmox Health Monitoring System

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUI_DIR="$SCRIPT_DIR/tui"
CONFIG_DIR="/etc/proxmox-health"
LIB_DIR="/usr/local/lib/proxmox-health"

# Source common functions
if [[ -f "$TUI_DIR/common-ui.sh" ]]; then
    source "$TUI_DIR/common-ui.sh"
else
    echo "Error: Common UI functions not found. Please install the system first."
    exit 1
fi

# Check if system is installed
if [[ ! -f "$CONFIG_DIR/proxmox-health.conf" ]]; then
    whiptail --title "Proxmox Health Monitor" --msgbox \
        "The Proxmox Health Monitoring System is not installed.\n\nPlease run the installer first:\nsudo ./install-proxmox-health.sh" \
        12 60
    exit 1
fi

# Main menu function
show_main_menu() {
    while true; do
        CHOICE=$(whiptail --title "Proxmox Health Monitor TUI" --menu "Select an option:" 15 70 6 \
            "1" "Health Status" \
            "2" "Configuration" \
            "3" "Monitoring" \
            "4" "Maintenance" \
            "5" "Automation" \
            "6" "Exit" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) show_health_status ;;
            2) show_configuration ;;
            3) show_monitoring ;;
            4) show_maintenance ;;
            5) show_automation ;;
            6) exit 0 ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

# Health Status Tab
show_health_status() {
    while true; do
        CHOICE=$(whiptail --title "Health Status" --menu "Select health information:" 15 60 5 \
            "1" "View Current Health Summary" \
            "2" "View System Metrics" \
            "3" "View Recent Alerts" \
            "4" "Run Health Check Now" \
            "5" "Back to Main Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) view_health_summary ;;
            2) view_system_metrics ;;
            3) view_recent_alerts ;;
            4) run_health_check ;;
            5) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

# Configuration Tab
show_configuration() {
    while true; do
        CHOICE=$(whiptail --title "Configuration" --menu "Select configuration option:" 15 60 5 \
            "1" "View Current Configuration" \
            "2" "Edit Configuration" \
            "3" "Test Notifications" \
            "4" "View Configuration Files" \
            "5" "Back to Main Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) view_current_config ;;
            2) edit_configuration ;;
            3) test_notifications ;;
            4) view_config_files ;;
            5) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

# Monitoring Tab
show_monitoring() {
    while true; do
        CHOICE=$(whiptail --title "Monitoring" --menu "Select monitoring option:" 15 60 5 \
            "1" "View Monitoring Status" \
            "2" "Toggle Monitoring" \
            "3" "View Check History" \
            "4" "View Log Files" \
            "5" "Back to Main Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) view_monitoring_status ;;
            2) toggle_monitoring ;;
            3) view_check_history ;;
            4) view_log_files ;;
            5) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

# Maintenance Tab
show_maintenance() {
    while true; do
        CHOICE=$(whiptail --title "Maintenance" --menu "Select maintenance option:" 15 60 5 \
            "1" "Toggle Maintenance Mode" \
            "2" "View Maintenance Status" \
            "3" "Schedule Maintenance" \
            "4" "View Maintenance History" \
            "5" "Back to Main Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) toggle_maintenance_mode ;;
            2) view_maintenance_status ;;
            3) schedule_maintenance ;;
            4) view_maintenance_history ;;
            5) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

# Automation Tab
show_automation() {
    while true; do
        CHOICE=$(whiptail --title "Automation Management" --menu "Select automation task:" 20 70 8 \
            "1" "ZFS Snapshot Cleanup [$(get_automation_status zfs_cleanup)]" \
            "2" "Emergency Disk Cleanup [$(get_automation_status disk_cleanup)]" \
            "3" "Memory Pressure Relief [$(get_automation_status memory_relief)]" \
            "4" "System Cache Refresh [$(get_automation_status system_refresh)]" \
            "5" "Auto-Update System [$(get_automation_status auto_update)]" \
            "6" "View Automation Logs" \
            "7" "Test Automation Functions" \
            "8" "Back to Main Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) configure_zfs_cleanup ;;
            2) configure_disk_cleanup ;;
            3) configure_memory_relief ;;
            4) configure_system_refresh ;;
            5) configure_auto_update ;;
            6) view_automation_logs ;;
            7) test_automation_functions ;;
            8) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

# Health Status Functions
view_health_summary() {
    if [[ -f "$LIB_DIR/proxmox-health-summary.sh" ]]; then
        "$LIB_DIR/proxmox-health-summary.sh" | whiptail --title "Health Summary" --textbox - 20 80
    else
        whiptail --title "Error" --msgbox "Health summary script not found." 8 40
    fi
}

view_system_metrics() {
    # Create temporary file with system metrics
    temp_file=$(mktemp)
    {
        echo "=== System Information ==="
        uname -a
        echo ""
        echo "=== Uptime ==="
        uptime
        echo ""
        echo "=== Memory Usage ==="
        free -h
        echo ""
        echo "=== Disk Usage ==="
        df -h
        echo ""
        echo "=== Process Count ==="
        ps aux | wc -l
    } > "$temp_file"

    whiptail --title "System Metrics" --textbox "$temp_file" 25 80
    rm -f "$temp_file"
}

view_recent_alerts() {
    if [[ -f "/var/log/proxmox-health/proxmox-health.log" ]]; then
        tail -n 50 "/var/log/proxmox-health/proxmox-health.log" | grep -E "(WARNING|ERROR|CRITICAL)" | whiptail --title "Recent Alerts" --textbox - 20 80
    else
        whiptail --title "Error" --msgbox "Alert log file not found." 8 40
    fi
}

run_health_check() {
    if whiptail --title "Run Health Check" --yesno "Run a full health check now? This may take a few moments." 8 40; then
        if [[ -f "$LIB_DIR/proxmox-healthcheck.sh" ]]; then
            temp_file=$(mktemp)
            "$LIB_DIR/proxmox-healthcheck.sh" > "$temp_file" 2>&1
            whiptail --title "Health Check Results" --textbox "$temp_file" 25 80
            rm -f "$temp_file"
        else
            whiptail --title "Error" --msgbox "Health check script not found." 8 40
        fi
    fi
}

# Configuration Functions
view_current_config() {
    if [[ -f "$CONFIG_DIR/proxmox-health.conf" ]]; then
        whiptail --title "Current Configuration" --textbox "$CONFIG_DIR/proxmox-health.conf" 20 80
    else
        whiptail --title "Error" --msgbox "Configuration file not found." 8 40
    fi
}

edit_configuration() {
    whiptail --title "Edit Configuration" --msgbox \
        "To edit configuration:\n\n1. Edit /etc/proxmox-health/proxmox-health.conf.local\n2. For global settings, edit /etc/proxmox-health/proxmox-health.conf\n3. Restart the monitoring service after changes" \
        12 60
}

test_notifications() {
    if [[ -f "$LIB_DIR/proxmox-notify.sh" ]]; then
        if whiptail --title "Test Notifications" --yesno "Send a test notification to verify the notification system is working?" 8 50; then
            temp_file=$(mktemp)
            "$LIB_DIR/proxmox-notify.sh" "Test notification from TUI" "info" "test" > "$temp_file" 2>&1
            whiptail --title "Test Results" --textbox "$temp_file" 15 60
            rm -f "$temp_file"
        fi
    else
        whiptail --title "Error" --msgbox "Notification script not found." 8 40
    fi
}

view_config_files() {
    temp_file=$(mktemp)
    {
        echo "=== Configuration Files ==="
        ls -la "$CONFIG_DIR/" 2>/dev/null || echo "Configuration directory not found"
        echo ""
        echo "=== Cron Jobs ==="
        ls -la /etc/cron.d/proxmox* 2>/dev/null || echo "No cron jobs found"
        echo ""
        echo "=== Systemd Services ==="
        systemctl list-unit-files | grep proxmox || echo "No systemd services found"
    } > "$temp_file"

    whiptail --title "Configuration Files" --textbox "$temp_file" 20 80
    rm -f "$temp_file"
}

# Monitoring Functions
view_monitoring_status() {
    temp_file=$(mktemp)
    {
        echo "=== Monitoring Status ==="
        systemctl is-active proxmox-healthcheck.timer 2>/dev/null && echo "Timer: Active" || echo "Timer: Inactive"
        systemctl is-enabled proxmox-healthcheck.timer 2>/dev/null && echo "Timer: Enabled" || echo "Timer: Disabled"
        echo ""
        echo "=== Recent Health Checks ==="
        journalctl -u proxmox-healthcheck.service --no-pager -n 10 2>/dev/null || echo "No journal entries found"
    } > "$temp_file"

    whiptail --title "Monitoring Status" --textbox "$temp_file" 20 80
    rm -f "$temp_file"
}

toggle_monitoring() {
    if systemctl is-active --quiet proxmox-healthcheck.timer; then
        if whiptail --title "Toggle Monitoring" --yesno "Monitoring is currently active. Do you want to stop it?" 8 50; then
            sudo systemctl stop proxmox-healthcheck.timer
            whiptail --title "Success" --msgbox "Monitoring has been stopped." 8 40
        fi
    else
        if whiptail --title "Toggle Monitoring" --yesno "Monitoring is currently stopped. Do you want to start it?" 8 50; then
            sudo systemctl start proxmox-healthcheck.timer
            whiptail --title "Success" --msgbox "Monitoring has been started." 8 40
        fi
    fi
}

view_check_history() {
    if [[ -f "/var/log/proxmox-health/proxmox-health.log" ]]; then
        tail -n 100 "/var/log/proxmox-health/proxmox-health.log" | whiptail --title "Check History" --textbox - 20 80
    else
        whiptail --title "Error" --msgbox "Check history log not found." 8 40
    fi
}

view_log_files() {
    if [[ -d "/var/log/proxmox-health" ]]; then
        temp_file=$(mktemp)
        {
            echo "=== Log Files ==="
            ls -la /var/log/proxmox-health/
            echo ""
            echo "=== Recent Log Entries ==="
            tail -n 20 /var/log/proxmox-health/proxmox-health.log 2>/dev/null || echo "No recent log entries"
        } > "$temp_file"

        whiptail --title "Log Files" --textbox "$temp_file" 20 80
        rm -f "$temp_file"
    else
        whiptail --title "Error" --msgbox "Log directory not found." 8 40
    fi
}

# Automation Configuration Functions
configure_zfs_cleanup() {
    load_automation_config

    while true; do
        CHOICE=$(whiptail --title "ZFS Snapshot Cleanup" --menu "Configure ZFS snapshot cleanup:" 15 60 4 \
            "1" "Enable/Disable [$(get_automation_status zfs_cleanup)]" \
            "2" "Set Schedule [${AUTOMATION_ZFS_CLEANUP_SCHEDULE:-Not configured}]" \
            "3" "Set Retention Days [${AUTOMATION_ZFS_CLEANUP_RETENTION:-Not configured}]" \
            "4" "Back to Automation Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1)
                if [ "$AUTOMATION_ZFS_CLEANUP_ENABLED" = "yes" ]; then
                    AUTOMATION_ZFS_CLEANUP_ENABLED="no"
                    show_message "ZFS Cleanup" "ZFS snapshot cleanup has been disabled."
                else
                    AUTOMATION_ZFS_CLEANUP_ENABLED="yes"
                    show_message "ZFS Cleanup" "ZFS snapshot cleanup has been enabled."
                fi
                save_automation_config
                ;;
            2)
                new_schedule=$(show_input "ZFS Cleanup Schedule" "Enter cron schedule (format: min hour day month weekday):" "$AUTOMATION_ZFS_CLEANUP_SCHEDULE")
                if [ $? -eq 0 ] && [ -n "$new_schedule" ]; then
                    AUTOMATION_ZFS_CLEANUP_SCHEDULE="$new_schedule"
                    save_automation_config
                    show_message "Success" "Schedule updated successfully."
                fi
                ;;
            3)
                new_retention=$(show_input "ZFS Cleanup Retention" "Enter retention days (1-365):" "$AUTOMATION_ZFS_CLEANUP_RETENTION")
                if [ $? -eq 0 ] && validate_number "$new_retention" 1 365; then
                    AUTOMATION_ZFS_CLEANUP_RETENTION="$new_retention"
                    save_automation_config
                    show_message "Success" "Retention updated successfully."
                else
                    show_message "Error" "Please enter a valid number between 1 and 365."
                fi
                ;;
            4) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

configure_disk_cleanup() {
    load_automation_config

    while true; do
        CHOICE=$(whiptail --title "Emergency Disk Cleanup" --menu "Configure emergency disk cleanup:" 15 60 4 \
            "1" "Enable/Disable [$(get_automation_status disk_cleanup)]" \
            "2" "Set Schedule [${AUTOMATION_DISK_CLEANUP_SCHEDULE:-Not configured}]" \
            "3" "Set Threshold (%) [${AUTOMATION_DISK_CLEANUP_THRESHOLD:-Not configured}]" \
            "4" "Back to Automation Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1)
                if [ "$AUTOMATION_DISK_CLEANUP_ENABLED" = "yes" ]; then
                    AUTOMATION_DISK_CLEANUP_ENABLED="no"
                    show_message "Disk Cleanup" "Emergency disk cleanup has been disabled."
                else
                    AUTOMATION_DISK_CLEANUP_ENABLED="yes"
                    show_message "Disk Cleanup" "Emergency disk cleanup has been enabled."
                fi
                save_automation_config
                ;;
            2)
                new_schedule=$(show_input "Disk Cleanup Schedule" "Enter cron schedule (format: min hour day month weekday):" "$AUTOMATION_DISK_CLEANUP_SCHEDULE")
                if [ $? -eq 0 ] && [ -n "$new_schedule" ]; then
                    AUTOMATION_DISK_CLEANUP_SCHEDULE="$new_schedule"
                    save_automation_config
                    show_message "Success" "Schedule updated successfully."
                fi
                ;;
            3)
                new_threshold=$(show_input "Disk Cleanup Threshold" "Enter disk usage threshold (1-100):" "$AUTOMATION_DISK_CLEANUP_THRESHOLD")
                if [ $? -eq 0 ] && validate_percentage "$new_threshold"; then
                    AUTOMATION_DISK_CLEANUP_THRESHOLD="$new_threshold"
                    save_automation_config
                    show_message "Success" "Threshold updated successfully."
                else
                    show_message "Error" "Please enter a valid percentage between 1 and 100."
                fi
                ;;
            4) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

configure_memory_relief() {
    load_automation_config

    while true; do
        CHOICE=$(whiptail --title "Memory Pressure Relief" --menu "Configure memory pressure relief:" 15 60 4 \
            "1" "Enable/Disable [$(get_automation_status memory_relief)]" \
            "2" "Set Schedule [${AUTOMATION_MEMORY_RELIEF_SCHEDULE:-Not configured}]" \
            "3" "Set Threshold (%) [${AUTOMATION_MEMORY_RELIEF_THRESHOLD:-Not configured}]" \
            "4" "Back to Automation Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1)
                if [ "$AUTOMATION_MEMORY_RELIEF_ENABLED" = "yes" ]; then
                    AUTOMATION_MEMORY_RELIEF_ENABLED="no"
                    show_message "Memory Relief" "Memory pressure relief has been disabled."
                else
                    AUTOMATION_MEMORY_RELIEF_ENABLED="yes"
                    show_message "Memory Relief" "Memory pressure relief has been enabled."
                fi
                save_automation_config
                ;;
            2)
                new_schedule=$(show_input "Memory Relief Schedule" "Enter cron schedule (format: min hour day month weekday):" "$AUTOMATION_MEMORY_RELIEF_SCHEDULE")
                if [ $? -eq 0 ] && [ -n "$new_schedule" ]; then
                    AUTOMATION_MEMORY_RELIEF_SCHEDULE="$new_schedule"
                    save_automation_config
                    show_message "Success" "Schedule updated successfully."
                fi
                ;;
            3)
                new_threshold=$(show_input "Memory Relief Threshold" "Enter memory usage threshold (1-100):" "$AUTOMATION_MEMORY_RELIEF_THRESHOLD")
                if [ $? -eq 0 ] && validate_percentage "$new_threshold"; then
                    AUTOMATION_MEMORY_RELIEF_THRESHOLD="$new_threshold"
                    save_automation_config
                    show_message "Success" "Threshold updated successfully."
                else
                    show_message "Error" "Please enter a valid percentage between 1 and 100."
                fi
                ;;
            4) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

configure_system_refresh() {
    load_automation_config

    while true; do
        CHOICE=$(whiptail --title "System Cache Refresh" --menu "Configure system cache refresh:" 15 60 3 \
            "1" "Enable/Disable [$(get_automation_status system_refresh)]" \
            "2" "Set Schedule [${AUTOMATION_SYSTEM_REFRESH_SCHEDULE:-Not configured}]" \
            "3" "Back to Automation Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1)
                if [ "$AUTOMATION_SYSTEM_REFRESH_ENABLED" = "yes" ]; then
                    AUTOMATION_SYSTEM_REFRESH_ENABLED="no"
                    show_message "System Refresh" "System cache refresh has been disabled."
                else
                    AUTOMATION_SYSTEM_REFRESH_ENABLED="yes"
                    show_message "System Refresh" "System cache refresh has been enabled."
                fi
                save_automation_config
                ;;
            2)
                new_schedule=$(show_input "System Refresh Schedule" "Enter cron schedule (format: min hour day month weekday):" "$AUTOMATION_SYSTEM_REFRESH_SCHEDULE")
                if [ $? -eq 0 ] && [ -n "$new_schedule" ]; then
                    AUTOMATION_SYSTEM_REFRESH_SCHEDULE="$new_schedule"
                    save_automation_config
                    show_message "Success" "Schedule updated successfully."
                fi
                ;;
            3) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

configure_auto_update() {
    load_automation_config

    while true; do
        CHOICE=$(whiptail --title "Auto-Update System" --menu "Configure auto-update system:" 15 60 4 \
            "1" "Enable/Disable [$(get_automation_status auto_update)]" \
            "2" "Set Schedule [${AUTOMATION_AUTO_UPDATE_SCHEDULE:-Not configured}]" \
            "3" "Security Only [${AUTOMATION_AUTO_UPDATE_SECURITY_ONLY:-Not configured}]" \
            "4" "Back to Automation Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1)
                if [ "$AUTOMATION_AUTO_UPDATE_ENABLED" = "yes" ]; then
                    AUTOMATION_AUTO_UPDATE_ENABLED="no"
                    show_message "Auto-Update" "Auto-update system has been disabled."
                else
                    AUTOMATION_AUTO_UPDATE_ENABLED="yes"
                    show_message "Auto-Update" "Auto-update system has been enabled."
                fi
                save_automation_config
                ;;
            2)
                new_schedule=$(show_input "Auto-Update Schedule" "Enter cron schedule (format: min hour day month weekday):" "$AUTOMATION_AUTO_UPDATE_SCHEDULE")
                if [ $? -eq 0 ] && [ -n "$new_schedule" ]; then
                    AUTOMATION_AUTO_UPDATE_SCHEDULE="$new_schedule"
                    save_automation_config
                    show_message "Success" "Schedule updated successfully."
                fi
                ;;
            3)
                if show_yesno "Security Only Updates" "Apply security updates only?\n(No for full system updates)"; then
                    AUTOMATION_AUTO_UPDATE_SECURITY_ONLY="yes"
                else
                    AUTOMATION_AUTO_UPDATE_SECURITY_ONLY="no"
                fi
                save_automation_config
                show_message "Success" "Update preference saved."
                ;;
            4) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

view_automation_logs() {
    temp_file=$(create_temp_file)
    {
        echo "=== Automation Status ==="
        load_automation_config
        echo "General Automation: $AUTOMATION_ENABLED"
        echo "ZFS Cleanup: $AUTOMATION_ZFS_CLEANUP_ENABLED"
        echo "Disk Cleanup: $AUTOMATION_DISK_CLEANUP_ENABLED"
        echo "Memory Relief: $AUTOMATION_MEMORY_RELIEF_ENABLED"
        echo "System Refresh: $AUTOMATION_SYSTEM_REFRESH_ENABLED"
        echo "Auto-Update: $AUTOMATION_AUTO_UPDATE_ENABLED"
        echo ""
        echo "=== Recent Automation Activity ==="
        if [ -f "/var/log/proxmox-health/proxmox-health.log" ]; then
            grep -i "automation\|auto.*clean\|memory.*relief\|system.*refresh\|auto.*update" "/var/log/proxmox-health/proxmox-health.log" | tail -n 20
        else
            echo "No automation activity found in logs"
        fi
        echo ""
        echo "=== Cron Jobs ==="
        if [ -f "/etc/cron.d/proxmox-automation" ]; then
            cat /etc/cron.d/proxmox-automation
        else
            echo "No automation cron jobs found"
        fi
    } > "$temp_file"

    show_textbox "Automation Logs" "$temp_file" 25 80
    cleanup_temp_file "$temp_file"
}

test_automation_functions() {
    while true; do
        CHOICE=$(whiptail --title "Test Automation Functions" --menu "Select function to test:" 15 60 6 \
            "1" "Test ZFS Cleanup" \
            "2" "Test Disk Cleanup" \
            "3" "Test Memory Relief" \
            "4" "Test System Refresh" \
            "5" "Test Auto-Update" \
            "6" "Back to Automation Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1)
                if show_yesno "Test ZFS Cleanup" "Run ZFS cleanup test?\n(Will show what would be cleaned, but won't actually delete)"; then
                    temp_file=$(create_temp_file)
                    if [ -f "/usr/local/lib/proxmox-health/automation/zfs-cleanup.sh" ]; then
                        /usr/local/lib/proxmox-health/automation/zfs-cleanup.sh --test 2>&1 | head -n 50 > "$temp_file"
                        show_textbox "ZFS Cleanup Test" "$temp_file" 20 80
                    else
                        echo "ZFS cleanup script not found. Please install automation features first." > "$temp_file"
                        show_textbox "ZFS Cleanup Test" "$temp_file" 10 60
                    fi
                    cleanup_temp_file "$temp_file"
                fi
                ;;
            2)
                if show_yesno "Test Disk Cleanup" "Run disk cleanup test?\n(Will show what would be cleaned, but won't actually delete)"; then
                    temp_file=$(create_temp_file)
                    if [ -f "/usr/local/lib/proxmox-health/automation/disk-cleanup.sh" ]; then
                        /usr/local/lib/proxmox-health/automation/disk-cleanup.sh --test 2>&1 | head -n 50 > "$temp_file"
                        show_textbox "Disk Cleanup Test" "$temp_file" 20 80
                    else
                        echo "Disk cleanup script not found. Please install automation features first." > "$temp_file"
                        show_textbox "Disk Cleanup Test" "$temp_file" 10 60
                    fi
                    cleanup_temp_file "$temp_file"
                fi
                ;;
            3)
                if show_yesno "Test Memory Relief" "Run memory relief test?\n(Will show current memory usage but won't drop caches)"; then
                    temp_file=$(create_temp_file)
                    if [ -f "/usr/local/lib/proxmox-health/automation/memory-relief.sh" ]; then
                        /usr/local/lib/proxmox-health/automation/memory-relief.sh --test 2>&1 | head -n 50 > "$temp_file"
                        show_textbox "Memory Relief Test" "$temp_file" 20 80
                    else
                        echo "Memory relief script not found. Please install automation features first." > "$temp_file"
                        show_textbox "Memory Relief Test" "$temp_file" 10 60
                    fi
                    cleanup_temp_file "$temp_file"
                fi
                ;;
            4)
                if show_yesno "Test System Refresh" "Run system refresh test?\n(Will show what would be cleaned but won't actually delete)"; then
                    temp_file=$(create_temp_file)
                    if [ -f "/usr/local/lib/proxmox-health/automation/system-refresh.sh" ]; then
                        /usr/local/lib/proxmox-health/automation/system-refresh.sh --test 2>&1 | head -n 50 > "$temp_file"
                        show_textbox "System Refresh Test" "$temp_file" 20 80
                    else
                        echo "System refresh script not found. Please install automation features first." > "$temp_file"
                        show_textbox "System Refresh Test" "$temp_file" 10 60
                    fi
                    cleanup_temp_file "$temp_file"
                fi
                ;;
            5)
                if show_yesno "Test Auto-Update" "Run auto-update test?\n(Will show available updates but won't install)"; then
                    temp_file=$(create_temp_file)
                    if [ -f "/usr/local/lib/proxmox-health/automation/auto-update.sh" ]; then
                        /usr/local/lib/proxmox-health/automation/auto-update.sh --test 2>&1 | head -n 50 > "$temp_file"
                        show_textbox "Auto-Update Test" "$temp_file" 20 80
                    else
                        echo "Auto-update script not found. Please install automation features first." > "$temp_file"
                        show_textbox "Auto-Update Test" "$temp_file" 10 60
                    fi
                    cleanup_temp_file "$temp_file"
                fi
                ;;
            6) break ;;
            *) whiptail --title "Error" --msgbox "Invalid option selected." 8 40 ;;
        esac
    done
}

# Maintenance Functions
toggle_maintenance_mode() {
    if [[ -f "$LIB_DIR/proxmox-maintenance.sh" ]]; then
        if whiptail --title "Toggle Maintenance Mode" --yesno "Do you want to toggle maintenance mode? This will silence alerts during maintenance." 8 60; then
            temp_file=$(mktemp)
            "$LIB_DIR/proxmox-maintenance.sh" > "$temp_file" 2>&1
            whiptail --title "Maintenance Mode" --textbox "$temp_file" 15 60
            rm -f "$temp_file"
        fi
    else
        whiptail --title "Error" --msgbox "Maintenance script not found." 8 40
    fi
}

view_maintenance_status() {
    if [[ -f "$CONFIG_DIR/maintenance.schedule" ]]; then
        whiptail --title "Maintenance Status" --textbox "$CONFIG_DIR/maintenance.schedule" 15 60
    else
        whiptail --title "Maintenance Status" --msgbox "No maintenance schedule found." 8 40
    fi
}

schedule_maintenance() {
    whiptail --title "Schedule Maintenance" --msgbox \
        "To schedule maintenance:\n\n1. Edit /etc/proxmox-health/maintenance.schedule\n2. Use the format: YYYY-MM-DD HH:MM YYYY-MM-DD HH:MM\n3. Or use the proxmox-maintenance.sh script" \
        12 60
}

view_maintenance_history() {
    if [[ -f "/var/log/proxmox-health/proxmox-health.log" ]]; then
        grep -i "maintenance" "/var/log/proxmox-health/proxmox-health.log" | tail -n 20 | whiptail --title "Maintenance History" --textbox - 15 60
    else
        whiptail --title "Error" --msgbox "Maintenance history not found." 8 40
    fi
}

# Main execution
main() {
    # Check for whiptail
    if ! command -v whiptail &> /dev/null; then
        echo "Error: whiptail is not installed. Please install it with:"
        echo "sudo apt-get install whiptail"
        exit 1
    fi

    # Show welcome message
    whiptail --title "Proxmox Health Monitor TUI" --msgbox \
        "Welcome to the Proxmox Health Monitoring System TUI\n\nThis interface allows you to manage health monitoring, configuration, and automation features." \
        10 60

    # Start main menu
    show_main_menu
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Proxmox Health Monitor TUI"
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h      Show this help message"
        echo "  --version, -v   Show version information"
        echo ""
        echo "This TUI provides a text-based interface for managing the Proxmox Health Monitoring System."
        ;;
    --version|-v)
        echo "Proxmox Health Monitor TUI v1.0.0"
        echo "Part of Proxmox Health Monitoring Suite"
        ;;
    *)
        main
        ;;
esac