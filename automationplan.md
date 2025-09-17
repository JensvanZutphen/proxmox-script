# Proxmox Health Monitoring - Automation Implementation Plan

## Overview
This document outlines the implementation of automation features for the Proxmox Health Monitoring Suite. The automation system will add optional cron jobs for self-healing, cleanup, and system maintenance tasks with configurable scheduling and notification policies.

## System Architecture

### Key Findings
- **No existing TUI interface** - Need to create a new TUI framework
- **Existing systems** to leverage: logging, notifications, configuration, state management
- **Integration points** with existing health monitoring infrastructure

### Target Features
1. **ZFS Snapshot Cleanup** - Remove old automated snapshots
2. **Emergency Disk Cleanup** - Clear temp files when disk space >95%
3. **Memory Pressure Relief** - Drop disk cache when memory usage >90%
4. **System Cache Refresh** - Clean temp files and refresh services
5. **Auto-Update System** - Security updates and package management

## Implementation Plan

### Phase 1: Infrastructure Setup

#### 1.1 Create TUI Framework
**Files:**
- `/usr/local/bin/proxmox-tui.sh` - Main TUI launcher
- `/usr/local/lib/proxmox-health/tui/` - TUI modules directory
- `/usr/local/lib/proxmox-health/tui/common-ui.sh` - Shared UI functions

**Implementation:**
```bash
# Main TUI structure
while true; do
    CHOICE=$(whiptail --title "Proxmox Health Monitor" --menu "Select an option:" 15 60 5 \
        "1" "Health Status" \
        "2" "Configuration" \
        "3" "Automation" \
        "4" "Logs" \
        "5" "Exit" 3>&1 1>&2 2>&3)

    case $CHOICE in
        1) source "$TUI_DIR/health-tab.sh" ;;
        2) source "$TUI_DIR/config-tab.sh" ;;
        3) source "$TUI_DIR/automation-tab.sh" ;;
        # ... other tabs
    esac
done
```

#### 1.2 Create Configuration Structure
**Config Files:**
- `/etc/proxmox-health/automation.conf` - Automation configuration
- `/etc/cron.d/proxmox-automation` - Automation cron jobs

**Configuration Format:**
```bash
# Automation Configuration
AUTOMATION_ENABLED="yes"
AUTOMATION_LOG_LEVEL="INFO"
AUTOMATION_NOTIFY_ON_SUCCESS="yes"
AUTOMATION_NOTIFY_ON_FAILURE="critical"

# Individual Job Settings
AUTOMATION_ZFS_CLEANUP_ENABLED="no"
AUTOMATION_ZFS_CLEANUP_SCHEDULE="0 2 * * 0"
AUTOMATION_ZFS_CLEANUP_RETENTION="30"

AUTOMATION_DISK_CLEANUP_ENABLED="no"
AUTOMATION_DISK_CLEANUP_SCHEDULE="0 * * * *"
AUTOMATION_DISK_CLEANUP_THRESHOLD="95"

AUTOMATION_MEMORY_RELIEF_ENABLED="no"
AUTOMATION_MEMORY_RELIEF_SCHEDULE="*/15 * * * *"
AUTOMATION_MEMORY_RELIEF_THRESHOLD="90"

AUTOMATION_SYSTEM_REFRESH_ENABLED="no"
AUTOMATION_SYSTEM_REFRESH_SCHEDULE="0 4 * * *"

AUTOMATION_AUTO_UPDATE_ENABLED="no"
AUTOMATION_AUTO_UPDATE_SCHEDULE="0 3 * * 0"
AUTOMATION_AUTO_UPDATE_SECURITY_ONLY="yes"
```

### Phase 2: Automation Tab Implementation

#### 2.1 Create Automation Tab
**File:** `/usr/local/lib/proxmox-health/tui/automation-tab.sh`

**Features:**
- Enable/disable individual automation jobs
- Configure scheduling for each job
- Set thresholds and parameters
- Test automation functions
- View automation logs

**UI Structure:**
```bash
automation_menu() {
    while true; do
        CHOICE=$(whiptail --title "Automation Management" --menu "Select automation task:" 20 70 8 \
            "1" "ZFS Snapshot Cleanup [$(get_status zfs_cleanup)]" \
            "2" "Emergency Disk Cleanup [$(get_status disk_cleanup)]" \
            "3" "Memory Pressure Relief [$(get_status memory_relief)]" \
            "4" "System Cache Refresh [$(get_status system_refresh)]" \
            "5" "Auto-Update System [$(get_status auto_update)]" \
            "6" "View Automation Logs" \
            "7" "Test Automation Functions" \
            "8" "Back to Main Menu" 3>&1 1>&2 2>&3)

        case $CHOICE in
            1) configure_zfs_cleanup ;;
            2) configure_disk_cleanup ;;
            # ... other options
        esac
    done
}
```

#### 2.2 Individual Automation Functions

##### ZFS Snapshot Cleanup
**File:** `/usr/local/lib/proxmox-health/automation/zfs-cleanup.sh`
```bash
#!/bin/bash
# ZFS Snapshot Cleanup Automation
source "/usr/local/lib/proxmox-health/utils.sh"
source "/usr/local/lib/proxmox-health/notifications.sh"

zfs_cleanup() {
    local retention_days=${1:-30}
    log_info "Starting ZFS snapshot cleanup (retention: $retention_days days)"

    # Send start notification
    send_notification "ZFS snapshot cleanup started" "info" "automation"

    # Find and remove old snapshots
    local removed_count=0
    while IFS= read -r snapshot; do
        if /usr/sbin/zfs destroy "$snapshot" 2>/dev/null; then
            ((removed_count++))
            log_debug "Removed snapshot: $snapshot"
        else
            log_warning "Failed to remove snapshot: $snapshot"
        fi
    done < <(/usr/sbin/zfs list -t snapshot -o name -H | grep -E "@auto-[0-9]{4}-[0-9]{2}-[0-9]{2}")

    # Send completion notification
    local message="ZFS snapshot cleanup completed. Removed $removed_count snapshots."
    send_notification "$message" "info" "automation"
    log_info "$message"
}
```

##### Emergency Disk Cleanup
**File:** `/usr/local/lib/proxmox-health/automation/disk-cleanup.sh`
```bash
#!/bin/bash
# Emergency Disk Cleanup Automation
source "/usr/local/lib/proxmox-health/utils.sh"
source "/usr/local/lib/proxmox-health/notifications.sh"

disk_cleanup() {
    local threshold=${1:-95}
    log_info "Checking disk space (threshold: ${threshold}%)"

    # Check root filesystem
    local usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')

    if [ "$usage" -gt "$threshold" ]; then
        log_warning "Disk usage critical: ${usage}% - initiating cleanup"
        send_notification "Emergency disk cleanup initiated (usage: ${usage}%)" "warning" "automation"

        # Clean temporary files
        local cleaned_files=0
        cleaned_files+=$(find /tmp -type f -mtime +7 -delete 2>/dev/null; echo $?)
        cleaned_files+=$(find /var/tmp -type f -mtime +3 -delete 2>/dev/null; echo $?)

        local message="Emergency cleanup completed. Cleaned $cleaned_files files."
        send_notification "$message" "info" "automation"
        log_info "$message"
    else
        log_debug "Disk usage normal: ${usage}%"
    fi
}
```

##### Memory Pressure Relief
**File:** `/usr/local/lib/proxmox-health/automation/memory-relief.sh`
```bash
#!/bin/bash
# Memory Pressure Relief Automation
source "/usr/local/lib/proxmox-health/utils.sh"
source "/usr/local/lib/proxmox-health/notifications.sh"

memory_relief() {
    local threshold=${1:-90}
    log_info "Checking memory pressure (threshold: ${threshold}%)"

    # Get memory usage
    local memory_usage=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')

    if [ "$memory_usage" -gt "$threshold" ]; then
        log_warning "Memory usage critical: ${memory_usage}% - dropping caches"
        send_notification "Memory pressure relief initiated (usage: ${memory_usage}%)" "warning" "automation"

        # Drop disk caches
        sync && echo 3 > /proc/sys/vm/drop_caches

        local new_usage=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
        local message="Memory pressure relief completed. Usage: ${memory_usage}% → ${new_usage}%"
        send_notification "$message" "info" "automation"
        log_info "$message"
    else
        log_debug "Memory usage normal: ${memory_usage}%"
    fi
}
```

##### System Cache Refresh
**File:** `/usr/local/lib/proxmox-health/automation/system-refresh.sh`
```bash
#!/bin/bash
# System Cache Refresh Automation
source "/usr/local/lib/proxmox-health/utils.sh"
source "/usr/local/lib/proxmox-health/notifications.sh"

system_refresh() {
    log_info "Starting system cache refresh"
    send_notification "System refresh started" "info" "automation"

    # Clean temporary files
    local tmp_cleaned=$(find /tmp -type f -atime +1 -delete 2>/dev/null | wc -l)
    local var_tmp_cleaned=$(find /var/tmp -type f -atime +7 -delete 2>/dev/null | wc -l)

    # Refresh systemd services
    systemctl restart systemd-logind 2>/dev/null || true

    local message="System refresh completed. Cleaned $tmp_cleaned tmp files, $var_tmp_cleaned var/tmp files."
    send_notification "$message" "info" "automation"
    log_info "$message"
}
```

##### Auto-Update System
**File:** `/usr/local/lib/proxmox-health/automation/auto-update.sh`
```bash
#!/bin/bash
# Auto-Update System Automation
source "/usr/local/lib/proxmox-health/utils.sh"
source "/usr/local/lib/proxmox-health/notifications.sh"

auto_update() {
    local security_only=${1:-yes}
    log_info "Starting system updates (security only: $security_only)"
    send_notification "System updates started" "info" "automation"

    # Update package lists
    apt update >/dev/null 2>&1

    # Perform updates
    local update_output
    if [ "$security_only" = "yes" ]; then
        update_output=$(apt upgrade -y --with-new-pkgs -o APT::Get::Show-User-Simulation-Note=false -o Dpkg::Use-Pty=0 2>&1)
    else
        update_output=$(apt full-upgrade -y -o APT::Get::Show-User-Simulation-Note=false -o Dpkg::Use-Pty=0 2>&1)
    fi

    # Check if updates were applied
    if echo "$update_output" | grep -q "0 upgraded, 0 newly installed"; then
        local message="System updates completed. No updates required."
    else
        local message="System updates completed. Updates were applied."
        send_notification "$message" "warning" "automation"
    fi

    send_notification "$message" "info" "automation"
    log_info "$message"
}
```

### Phase 3: Integration with Existing Systems

#### 3.1 Cron Job Generation
**File:** `/usr/local/lib/proxmox-health/automation/generate-cron.sh`
```bash
#!/bin/bash
# Generate automation cron jobs
source "/etc/proxmox-health/automation.conf"

generate_cron_jobs() {
    local cron_file="/etc/cron.d/proxmox-automation"

    # Generate cron file header
    cat > "$cron_file" << 'EOF'
# Proxmox Health Monitoring - Automation Jobs
# Generated by proxmox-health automation system
EOF

    # Add individual jobs based on configuration
    if [ "$AUTOMATION_ZFS_CLEANUP_ENABLED" = "yes" ]; then
        echo "$AUTOMATION_ZFS_CLEANUP_SCHEDULE root /usr/local/lib/proxmox-health/automation/zfs-cleanup.sh $AUTOMATION_ZFS_CLEANUP_RETENTION" >> "$cron_file"
    fi

    if [ "$AUTOMATION_DISK_CLEANUP_ENABLED" = "yes" ]; then
        echo "$AUTOMATION_DISK_CLEANUP_SCHEDULE root /usr/local/lib/proxmox-health/automation/disk-cleanup.sh $AUTOMATION_DISK_CLEANUP_THRESHOLD" >> "$cron_file"
    fi

    if [ "$AUTOMATION_MEMORY_RELIEF_ENABLED" = "yes" ]; then
        echo "$AUTOMATION_MEMORY_RELIEF_SCHEDULE root /usr/local/lib/proxmox-health/automation/memory-relief.sh $AUTOMATION_MEMORY_RELIEF_THRESHOLD" >> "$cron_file"
    fi

    if [ "$AUTOMATION_SYSTEM_REFRESH_ENABLED" = "yes" ]; then
        echo "$AUTOMATION_SYSTEM_REFRESH_SCHEDULE root /usr/local/lib/proxmox-health/automation/system-refresh.sh" >> "$cron_file"
    fi

    if [ "$AUTOMATION_AUTO_UPDATE_ENABLED" = "yes" ]; then
        echo "$AUTOMATION_AUTO_UPDATE_SCHEDULE root /usr/local/lib/proxmox-health/automation/auto-update.sh $AUTOMATION_AUTO_UPDATE_SECURITY_ONLY" >> "$cron_file"
    fi

    chmod 644 "$cron_file"
}
```

#### 3.2 Enhanced Notification System
**File:** `/usr/local/lib/proxmox-health/notifications.sh` (additions)
```bash
# Add automation-specific notification function
send_automation_notification() {
    local message="$1"
    local level="${2:-info}"
    local operation="${3:-automation}"

    # Get notification preferences
    local notify_success="$AUTOMATION_NOTIFY_ON_SUCCESS"
    local notify_failure="$AUTOMATION_NOTIFY_ON_FAILURE"

    # Determine if we should send notification
    local should_send=false
    case "$level" in
        critical) should_send=true ;;
        error) should_send=true ;;
        warning) should_send=true ;;
        info) [ "$notify_success" = "yes" ] && should_send=true ;;
    esac

    if [ "$should_send" = "true" ]; then
        send_discord_notification "$message" "$level" "$operation"
    fi
}
```

#### 3.3 Installer Integration
**File:** `install-proxmox-health.sh` (additions)
```bash
# Add automation option to installer
SELECT_AUTOMATION=$(whiptail --title "Automation Features" --checklist \
    "Select automation features to install:" 15 60 5 \
    "ZFS_CLEANUP" "ZFS snapshot cleanup" OFF \
    "DISK_CLEANUP" "Emergency disk cleanup" OFF \
    "MEMORY_RELIEF" "Memory pressure relief" OFF \
    "SYSTEM_REFRESH" "System cache refresh" OFF \
    "AUTO_UPDATE" "Automatic system updates" OFF 3>&1 1>&2 2>&3)

# Configure automation based on selections
for feature in $SELECT_AUTOMATION; do
    case $feature in
        ZFS_CLEANUP)
            sed -i 's/AUTOMATION_ZFS_CLEANUP_ENABLED="no"/AUTOMATION_ZFS_CLEANUP_ENABLED="yes"/' "$CONFIG_LOCAL"
            ;;
        DISK_CLEANUP)
            sed -i 's/AUTOMATION_DISK_CLEANUP_ENABLED="no"/AUTOMATION_DISK_CLEANUP_ENABLED="yes"/' "$CONFIG_LOCAL"
            ;;
        # ... other features
    esac
done
```

### Phase 4: Testing and Deployment

#### 4.1 Test Functions
**File:** `/usr/local/lib/proxmox-health/automation/test-automation.sh`
```bash
#!/bin/bash
# Test automation functions
source "/usr/local/lib/proxmox-health/automation/test-helpers.sh"

test_all_automation() {
    echo "Testing automation functions..."

    test_zfs_cleanup
    test_disk_cleanup
    test_memory_relief
    test_system_refresh
    test_auto_update

    echo "All tests completed."
}
```

#### 4.2 Rollback Plan
- **Backup existing configurations** before installation
- **Disable all automation** by default
- **Manual override capability** via TUI
- **Emergency stop script** to disable all automation jobs
- **Comprehensive logging** for troubleshooting

### Configuration File Locations

After implementation, automation configuration will be available at:

- **Main Config:** `/etc/proxmox-health/automation.conf`
- **Local Overrides:** `/etc/proxmox-health/automation.conf.local`
- **Cron Jobs:** `/etc/cron.d/proxmox-automation`
- **Automation Scripts:** `/usr/local/lib/proxmox-health/automation/`
- **TUI Interface:** `/usr/local/bin/proxmox-tui.sh`
- **TUI Modules:** `/usr/local/lib/proxmox-health/tui/`

### Security Considerations

1. **Permission Management:**
   - Automation scripts run as root via cron
   - Strict file permissions (600/644)
   - Sudo wrapper for critical operations

2. **Update Safety:**
   - Security-only updates by default
   - Update exclusion list for critical packages
   - Update rollback capability

3. **Monitoring:**
   - Track automation success/failure rates
   - Alert on consecutive failures
   - Resource usage monitoring

### Success Metrics

- **Reliability:** <5% failure rate for automation jobs
- **Performance:** No significant performance impact during execution
- **Usability:** Clear TUI interface for configuration and monitoring
- **Safety:** No unintended system modifications
- **Notification:** Appropriate alerting for different scenarios

This implementation plan provides a comprehensive framework for adding automation capabilities to the Proxmox Health Monitoring Suite while maintaining the existing system's reliability and security standards.