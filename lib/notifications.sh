#!/bin/bash
# Proxmox Health Notification Functions
# This module handles all notification and alerting functionality

# Load configuration
# shellcheck disable=SC1091
source "/etc/proxmox-health/proxmox-health.conf"
# shellcheck disable=SC1091
[ -f "/etc/proxmox-health/proxmox-health.conf.local" ] && source "/etc/proxmox-health/proxmox-health.conf.local"

# --- Level mapping ---
level_num() {
    case "${1:-info}" in
        critical) echo 3;;
        warning) echo 2;;
        info|ok) echo 1;;
        *) echo 1;;
    esac
}

# --- Notification State Management ---
get_notification_state() {
    local key="$1"
    local state_file="$STATE_DIR/${key}.notify"

    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

set_notification_state() {
    local key="$1"
    local state="$2"
    local state_file="$STATE_DIR/${key}.notify"

    echo "$state" > "$state_file"
    # Set expiration for alert cooldown
    if [ "$state" = "alerted" ]; then
        touch -d "+$ALERT_COOLDOWN_MINUTES minutes" "$state_file.cooldown"
    fi
}

clear_notification_state() {
    local key="$1"
    local state_file="$STATE_DIR/${key}.notify"

    rm -f "$state_file" "$state_file.cooldown" 2>/dev/null || true
}

is_notification_cooldown_active() {
    local key="$1"
    local cooldown_file="$STATE_DIR/${key}.notify.cooldown"

    if [ -f "$cooldown_file" ]; then
        local cooldown_time
        cooldown_time=$(stat -c %Y "$cooldown_file" 2>/dev/null || echo 0)
        local current_time
        current_time=$(date +%s)

        if [ "$current_time" -lt "$cooldown_time" ]; then
            return 0  # Cooldown active
        fi
    fi

    return 1  # Cooldown not active
}

# --- Alert Level Management ---
get_alert_level() {
    local level="$1"
    case "$level" in
        "critical") echo "🔴 CRITICAL" ;;
        "warning") echo "🟡 WARNING" ;;
        "info") echo "🔵 INFO" ;;
        "ok") echo "🟢 OK" ;;
        *) echo "$level" ;;
    esac
}

# --- Discord Notifications ---
send_discord_notification() {
    local message="$1"
    local level="${2:-info}"

    # Check if webhook URL is configured
    if [ -z "$WEBHOOK_URL" ]; then
        log_warning "Discord webhook URL not configured"
        return 1
    fi

    # Get webhook from secret file if configured
    if [ -f "$WEBHOOK_SECRET_FILE" ]; then
        local webhook_url
        webhook_url=$(cat "$WEBHOOK_SECRET_FILE")
        [ -n "$webhook_url" ] && WEBHOOK_URL="$webhook_url"
    fi

    # Get hostname and format message
    local hostname
    hostname=$(hostname)
    local alert_level
    alert_level=$(get_alert_level "$level")
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Escape message for JSON
    local escaped_message
    escaped_message=$(printf '%s' "[$alert_level] [$hostname] [$timestamp] $message" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Create JSON payload
    local json_payload
    json_payload="{\"content\":\"$escaped_message\"}"

    # Send notification with retry logic
    local retry_count=0
    local max_retries=$ALERT_MAX_RETRIES

    while [ $retry_count -lt "$max_retries" ]; do
        if curl -s -H "Content-Type: application/json" -X POST \
           -d "$json_payload" \
           "$WEBHOOK_URL" >/dev/null 2>&1; then
            log_info "Discord notification sent successfully"
            return 0
        else
            retry_count=$((retry_count + 1))
            log_warning "Discord notification failed (attempt $retry_count/$max_retries)"

            if [ $retry_count -lt "$max_retries" ]; then
                sleep "$ALERT_RETRY_DELAY_SECONDS"
            fi
        fi
    done

    log_error "Failed to send Discord notification after $max_retries attempts"
    return 1
}

# --- Email Notifications ---
send_email_notification() {
    local message="$1"
    local level="${2:-info}"
    local level_label
    level_label=$(get_alert_level "$level")
    local subject_host
    subject_host=$(hostname)
    local subject="[Proxmox Alert] $level_label - $subject_host"

    if [ "$EMAIL_NOTIFICATIONS_ENABLED" != "yes" ]; then
        return 0
    fi

    # Check if email configuration is complete
    if [ -z "$SMTP_SERVER" ] || [ -z "$EMAIL_TO" ]; then
        log_warning "Email configuration incomplete"
        return 1
    fi

    # Create email content
    local sent_at
    sent_at=$(date '+%Y-%m-%d %H:%M:%S')
    local email_date
    email_date=$(date -R)
    local email_content
    email_content=$(cat <<EOF
From: $EMAIL_FROM
To: $EMAIL_TO
Subject: $subject
Date: $email_date
Content-Type: text/plain; charset=UTF-8

Proxmox Health Alert
===================
Host: $subject_host
Time: $sent_at
Level: $level_label

Message: $message

--
Proxmox Health Monitoring System
EOF
)

    # Send email using mail command if available
    if command -v mail >/dev/null 2>&1; then
        echo "$email_content" | mail -s "$subject" "$EMAIL_TO" 2>/dev/null
        return $?
    fi

    # Fallback to sendmail
    if command -v sendmail >/dev/null 2>&1; then
        echo "$email_content" | sendmail -t 2>/dev/null
        return $?
    fi

    log_warning "No email client found (mail or sendmail)"
    return 1
}

# --- System Log Notifications ---
send_system_log_notification() {
    local message="$1"
    local level="${2:-info}"

    local priority="info"
    case "$level" in
        "critical") priority="err" ;;
        "warning") priority="warning" ;;
        "info") priority="info" ;;
        "ok") priority="info" ;;
    esac

    logger -t "proxmox-health" -p "user.$priority" "$message"
}

# --- Alert Management Functions ---
alert_once() {
    local key="$1"
    local level="$2"
    local message_fail="$3"
    local message_ok="${4:-restored}"

    # Check maintenance mode
    if [ -f "$MAINTENANCE_MODE_FILE" ]; then
        log_debug "Maintenance mode active - skipping alert for $key"
        return 0
    fi

    local previous_state
    previous_state=$(get_notification_state "$key")

    if [ "$level" = "fail" ] || [ "$level" = "critical" ] || [ "$level" = "warning" ]; then
        if [ "$previous_state" != "alerted" ] || ! is_notification_cooldown_active "$key"; then
            set_notification_state "$key" "alerted"
            send_notification "$message_fail" "$level" "$key"
        fi
    else
        if [ "$previous_state" = "alerted" ]; then
            clear_notification_state "$key"
            send_notification "$message_ok" "ok" "$key"
        fi
    fi
}

alert_clear() {
    local key="$1"
    local message="${2:-OK}"

    # Check maintenance mode
    if [ -f "$MAINTENANCE_MODE_FILE" ]; then
        log_debug "Maintenance mode active - skipping clear for $key"
        return 0
    fi

    local previous_state
    previous_state=$(get_notification_state "$key")

    if [ "$previous_state" = "alerted" ]; then
        clear_notification_state "$key"
        send_notification "$message" "ok" "$key"
    else
        log_debug "$key: $message"
    fi
}

# --- Main Notification Function ---
send_notification() {
    local message="$1"
    local level="${2:-info}"
    local key="${3:-general}"

    log_info "Sending notification [$level] $key: $message"

    local category
    category=$(category_for_key "$key")
    if notify_topic_enabled "$category"; then
        # Honor minimum severity threshold and quiet hours
        local min_level_num; min_level_num=$(level_num "${NOTIFY_MIN_LEVEL:-info}")
        local this_level_num; this_level_num=$(level_num "$level")
        if [ "${QUIET_HOURS_ENABLED:-no}" = "yes" ] && [ "$level" != "critical" ]; then
            # Elevate threshold to critical during quiet hours
            local now_hm; now_hm=$(date +%H:%M)
            local qs="${QUIET_HOURS_START:-22:00}"; local qe="${QUIET_HOURS_END:-07:00}"
            if { [ "$qs" \< "$qe" ] && [ "$now_hm" \> "$qs" ] && [ "$now_hm" \< "$qe" ]; } || \
               { [ "$qs" \> "$qe" ] && { [ "$now_hm" \> "$qs" ] || [ "$now_hm" \< "$qe" ]; }; }; then
                min_level_num=$(level_num critical)
            fi
        fi
        if [ "$this_level_num" -lt "$min_level_num" ]; then
            log_debug "Notification below threshold ($level < ${NOTIFY_MIN_LEVEL:-info}); suppressed"
        else
            # Send to Discord only (email disabled by project policy)
            send_discord_notification "$message" "$level" || log_warning "Discord notification failed"
        fi
    else
        log_debug "External notifications suppressed for category: $category"
    fi

    # Always log to system log
    send_system_log_notification "$message" "$level"
}

# --- Maintenance Mode Functions ---
enable_maintenance_mode() {
    local duration="${1:-1h}"
    local reason="${2:-scheduled maintenance}"

    echo "$reason" > "$MAINTENANCE_MODE_FILE"
    if [ "$duration" != "0" ]; then
        touch -d "+$duration" "$MAINTENANCE_MODE_FILE"
    fi

    send_notification "Maintenance mode enabled: $reason" "info" "maintenance"
    log_info "Maintenance mode enabled: $reason"
}

disable_maintenance_mode() {
    if [ -f "$MAINTENANCE_MODE_FILE" ]; then
        rm -f "$MAINTENANCE_MODE_FILE"
        send_notification "Maintenance mode disabled" "info" "maintenance"
        log_info "Maintenance mode disabled"
    fi
}

check_maintenance_mode() {
    if [ -f "$MAINTENANCE_MODE_FILE" ]; then
        # Check if maintenance mode has expired
        local expiry_time
        expiry_time=$(stat -c %Y "$MAINTENANCE_MODE_FILE" 2>/dev/null || echo 0)
        local current_time
        current_time=$(date +%s)

        if [ "$current_time" -gt "$expiry_time" ]; then
            disable_maintenance_mode
            return 1
        fi
        return 0
    fi
    return 1
}

# --- Alert Summary Functions ---
generate_alert_summary() {
    local summary_file="$STATE_DIR/alert_summary.txt"
    local -a alert_files=()
    mapfile -t alert_files < <(find "$STATE_DIR" -name "*.notify" -type f 2>/dev/null)
    local alert_count=${#alert_files[@]}

    {
        echo "Proxmox Health Alert Summary"
        echo "============================"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host: $(hostname)"
        echo ""

        echo "Active Alerts: $alert_count"
        echo ""

        if [ "$alert_count" -gt 0 ]; then
            echo "Active Alert Details:"
            echo "---------------------"
            local alert_file
            for alert_file in "${alert_files[@]}"; do
                local key
                key=$(basename "$alert_file" .notify)
                local state
                state=$(<"$alert_file")
                echo "- $key: $state"
            done
        else
            echo "No active alerts"
        fi

    } > "$summary_file"

    echo "$summary_file"
}

send_alert_summary() {
    local summary_file
    summary_file=$(generate_alert_summary)

    if [ -f "$summary_file" ]; then
        local summary_content
        summary_content=$(<"$summary_file")
        send_notification "Daily Alert Summary:\n\n$summary_content" "info" "summary"
        rm -f "$summary_file"
    fi
}

# --- Notification Test Functions ---
test_discord_notification() {
    local current_time
    current_time=$(date '+%Y-%m-%d %H:%M:%S')
    local test_message="Proxmox Health Monitoring Test - $current_time"
    send_discord_notification "$test_message" "info"
}

test_email_notification() {
    local current_time
    current_time=$(date '+%Y-%m-%d %H:%M:%S')
    local test_message="Proxmox Health Monitoring Test - $current_time"
    send_email_notification "$test_message" "info"
}

test_all_notifications() {
    log_info "Testing notification channel (Discord)..."

    test_discord_notification

    send_notification "Test notification completed" "info" "test"
}

# --- Notification Cleanup Functions ---
cleanup_old_notifications() {
    # Clean up old notification state files
    find "$STATE_DIR" -name "*.notify" -mtime +"$STATE_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$STATE_DIR" -name "*.notify.cooldown" -mtime +"$STATE_RETENTION_DAYS" -delete 2>/dev/null || true
}

# --- Initialization Function ---
initialize_notifications() {
    log_info "Initializing notification system..."

    # Ensure state directory exists
    mkdir -p "$STATE_DIR"

    # Check if webhook secret file exists, create template if not
    if [ ! -f "$WEBHOOK_SECRET_FILE" ] && [ -n "$WEBHOOK_URL" ]; then
        mkdir -p "$(dirname "$WEBHOOK_SECRET_FILE")"
        echo "$WEBHOOK_URL" > "$WEBHOOK_SECRET_FILE"
        chmod 600 "$WEBHOOK_SECRET_FILE"
    fi

    # Test notification channels on first run
    if [ ! -f "$STATE_DIR/.notifications_tested" ]; then
        test_all_notifications
        touch "$STATE_DIR/.notifications_tested"
    fi

    log_info "Notification system initialized successfully"
}

# Export functions
export -f get_notification_state set_notification_state clear_notification_state
export -f is_notification_cooldown_active get_alert_level
export -f send_discord_notification send_email_notification send_system_log_notification
# --- Topic mapping ---
category_for_key() {
    local key="$1"
    case "$key" in
        svc-*) echo services ;;
        disk-*) echo disk ;;
        zfs-*) echo zfs ;;
        mem|swap) echo memory ;;
        load) echo load ;;
        iowait) echo iowait ;;
        net*|br-*) echo network ;;
        iface-*) echo interface_errors ;;
        ssh-*) echo ssh ;;
        oom|dup-ip) echo system_events ;;
        cpu-temp|smart-*|temp-*) echo temps ;;
        backup-*) echo backups ;;
        updates) echo updates ;;
        ct-*|vm-*) echo vms ;;
        *) echo general ;;
    esac
}

# Returns 0 if allowed to notify externally, 1 otherwise
notify_topic_enabled() {
    local category="$1"
    case "$category" in
        services) val="$NOTIFY_SERVICES" ;;
        disk) val="$NOTIFY_DISK" ;;
        zfs) val="$NOTIFY_ZFS" ;;
        memory) val="$NOTIFY_MEMORY" ;;
        load) val="$NOTIFY_LOAD" ;;
        iowait) val="$NOTIFY_IOWAIT" ;;
        network) val="$NOTIFY_NETWORK" ;;
        interface_errors) val="$NOTIFY_INTERFACE_ERRORS" ;;
        ssh) val="$NOTIFY_SSH" ;;
        system_events) val="$NOTIFY_SYSTEM_EVENTS" ;;
        temps) val="$NOTIFY_TEMPS" ;;
        backups) val="$NOTIFY_BACKUPS" ;;
        updates) val="$NOTIFY_UPDATES" ;;
        vms) val="$NOTIFY_VMS" ;;
        *) val="yes" ;;
    esac

    [ "${val:-yes}" = "yes" ]
}
export -f alert_once alert_clear send_notification
export -f enable_maintenance_mode disable_maintenance_mode check_maintenance_mode
export -f generate_alert_summary send_alert_summary
export -f test_discord_notification test_email_notification test_all_notifications
export -f cleanup_old_notifications initialize_notifications
