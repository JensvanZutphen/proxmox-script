#!/bin/bash
# Proxmox Health Check Functions
# This module contains all health check functions

# Load configuration and utilities
# shellcheck disable=SC1091
source "/etc/proxmox-health/proxmox-health.conf"
# shellcheck disable=SC1091
[ -f "/etc/proxmox-health/proxmox-health.conf.local" ] && source "/etc/proxmox-health/proxmox-health.conf.local"
# shellcheck disable=SC1091
source "/usr/local/lib/proxmox-health/utils.sh"

# Run a check with one retry and jitter
run_with_retry() {
    local fn="$1"
    if "$fn"; then
        return 0
    fi
    sleep $(( (RANDOM % 3) + 1 ))
    "$fn"
}

# --- Service Health Checks ---
check_services() {
    local failed_services=()

    for service in $PROXMOX_SERVICES; do
        if systemctl is-active --quiet "$service"; then
            log_debug "Service $service is running"
            alert_clear "svc-$service" "Service $service is running"
        else
            log_warning "Service $service is not running"
            alert_once "svc-$service" "fail" "Service $service is down" "Service $service restored"

            # Attempt to restart the service
            if systemctl restart "$service"; then
                sleep 2
                if systemctl is-active --quiet "$service"; then
                    log_info "Service $service restarted successfully"
                    alert_clear "svc-$service" "Service $service restarted successfully"
                else
                    failed_services+=("$service")
                fi
            else
                failed_services+=("$service")
            fi
        fi
    done

    if [ ${#failed_services[@]} -gt 0 ]; then
        return 1
    fi
    return 0
}

# --- Disk Space Checks ---
check_disk_space() {
    local issues_found=0

    # Check root filesystem
    local disk_usage
    disk_usage=$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}')
    if [ "$disk_usage" -ge "$DISK_ROOT_CRITICAL_THRESHOLD" ]; then
        alert_once "disk-root" "critical" "Root disk usage critically high: ${disk_usage}%" "Root disk usage restored"
        issues_found=1
    elif [ "$disk_usage" -ge "$DISK_ROOT_WARNING_THRESHOLD" ]; then
        alert_once "disk-root" "warning" "Root disk usage high: ${disk_usage}%" "Root disk usage restored"
        issues_found=1
    else
        alert_clear "disk-root" "Root disk usage normal: ${disk_usage}%"
    fi

    return $issues_found
}

# --- ZFS Pool Checks ---
check_zfs_pools() {
    local issues_found=0

    if command -v zpool >/dev/null 2>&1; then
        # Check pool health
        if ! zpool status -x 2>/dev/null | grep -qi "all pools are healthy"; then
            alert_once "zfs-health" "critical" "ZFS pool degraded or errors present" "ZFS pool healthy"
            issues_found=1
        else
            alert_clear "zfs-health" "All ZFS pools healthy"
        fi

        # Check pool capacity
        while read -r name _ _ _ cap _ _ _; do
            cap="${cap:-0}"
            key="zfs-cap-$name"

            if [ "$cap" -ge "$ZFS_CAPACITY_CRITICAL_THRESHOLD" ]; then
                alert_once "$key" "critical" "ZFS pool $name critically high capacity: ${cap}%" "ZFS pool $name capacity normal"
                issues_found=1
            elif [ "$cap" -ge "$ZFS_CAPACITY_WARNING_THRESHOLD" ]; then
                alert_once "$key" "warning" "ZFS pool $name high capacity: ${cap}%" "ZFS pool $name capacity normal"
                issues_found=1
            else
                alert_clear "$key" "ZFS pool $name capacity normal: ${cap}%"
            fi
        done < <(zpool list -Hp 2>/dev/null)
    fi

    return $issues_found
}

# --- Memory and Swap Checks ---
check_memory() {
    local issues_found=0

    # Check memory usage
    local mem_usage
    mem_usage=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
    if [ "$mem_usage" -ge "$MEMORY_CRITICAL_THRESHOLD" ]; then
        alert_once "mem" "critical" "Memory usage critically high: ${mem_usage}%" "Memory usage restored"
        issues_found=1
    elif [ "$mem_usage" -ge "$MEMORY_WARNING_THRESHOLD" ]; then
        alert_once "mem" "warning" "Memory usage high: ${mem_usage}%" "Memory usage restored"
        issues_found=1
    else
        alert_clear "mem" "Memory usage normal: ${mem_usage}%"
    fi

    # Check swap usage
    local swap_usage
    swap_usage=$(free | awk '/Swap:/ { if ($2==0) print 0; else printf "%.0f", $3/$2*100 }')
    if [ "$swap_usage" -ge "$SWAP_CRITICAL_THRESHOLD" ]; then
        alert_once "swap" "critical" "Swap usage critically high: ${swap_usage}%" "Swap usage restored"
        issues_found=1
    elif [ "$swap_usage" -ge "$SWAP_WARNING_THRESHOLD" ]; then
        alert_once "swap" "warning" "Swap usage high: ${swap_usage}%" "Swap usage restored"
        issues_found=1
    else
        alert_clear "swap" "Swap usage normal: ${swap_usage}%"
    fi

    return $issues_found
}

# --- Load Average Checks ---
check_load_average() {
    local issues_found=0
    local cores
    cores=$(nproc)
    local load_warn=$LOAD_WARNING_THRESHOLD
    local load_crit=$LOAD_CRITICAL_THRESHOLD

    if [ "$LOAD_AUTO_DETECT" = "yes" ]; then
        load_warn=$cores
        load_crit=$((cores * 2))
    fi

    local load_int
    load_int=$(awk '{printf "%d",$1}' /proc/loadavg)

    if [ "$load_int" -gt "$load_crit" ]; then
        alert_once "load" "critical" "Load average critically high: ${load_int} (cores: $cores)" "Load average restored"
        issues_found=1
    elif [ "$load_int" -gt "$load_warn" ]; then
        alert_once "load" "warning" "Load average high: ${load_int} (cores: $cores)" "Load average restored"
        issues_found=1
    else
        alert_clear "load" "Load average normal: ${load_int} (cores: $cores)"
    fi

    return $issues_found
}

# --- I/O Wait Checks ---
check_iowait() {
    local issues_found=0

    read -r _cpu user nice sys idle iowait irq softirq steal _guest _gnice < /proc/stat
    local t_total=$((user + nice + sys + idle + iowait + irq + softirq + steal))
    local t_iowait=$iowait

    sleep 2
    read -r _cpu2 user2 nice2 sys2 idle2 iowait2 irq2 softirq2 steal2 _guest2 _gnice2 < /proc/stat
    local t_total2=$((user2 + nice2 + sys2 + idle2 + iowait2 + irq2 + softirq2 + steal2))
    local t_iowait2=$iowait2

    local delta_total=$((t_total2 - t_total))
    local delta_iowait=$((t_iowait2 - t_iowait))
    local iowait_pct=0

    if [ $delta_total -gt 0 ]; then
        iowait_pct=$(( 100 * delta_iowait / delta_total ))
    fi

    if [ "$iowait_pct" -ge "$IOWAIT_CRITICAL_THRESHOLD" ]; then
        alert_once "iowait" "critical" "I/O wait critically high: ${iowait_pct}%" "I/O wait restored"
        issues_found=1
    elif [ "$iowait_pct" -ge "$IOWAIT_WARNING_THRESHOLD" ]; then
        alert_once "iowait" "warning" "I/O wait high: ${iowait_pct}%" "I/O wait restored"
        issues_found=1
    else
        alert_clear "iowait" "I/O wait normal: ${iowait_pct}%"
    fi

    return $issues_found
}

# --- Network Connectivity Checks ---
check_network() {
    local issues_found=0

    # Test connectivity
    if ping -c5 -w6 "$PING_TEST_HOST" >/dev/null 2>&1; then
        local loss
        loss=$(ping -c5 -w6 "$PING_TEST_HOST" 2>/dev/null | grep -oE '[0-9]+% packet loss' | tr -dc '0-9')
        loss=${loss:-0}

        if [ "$loss" -ge "$PACKET_LOSS_CRITICAL_THRESHOLD" ]; then
            alert_once "net-loss" "critical" "Critical packet loss: ${loss}% to $PING_TEST_HOST" "Packet loss restored"
            issues_found=1
        elif [ "$loss" -ge "$PACKET_LOSS_WARNING_THRESHOLD" ]; then
            alert_once "net-loss" "warning" "High packet loss: ${loss}% to $PING_TEST_HOST" "Packet loss restored"
            issues_found=1
        else
            alert_clear "net" "Network connectivity OK"
            alert_clear "net-loss" "Packet loss normal: ${loss}%"
        fi
    else
        alert_once "net" "critical" "Network unreachable to $PING_TEST_HOST" "Network connectivity restored"
        issues_found=1
    fi

    # Check bridge interfaces
    for bridge in $MONITORED_BRIDGES; do
        if ip link show "$bridge" 2>/dev/null | grep -q "state UP"; then
            alert_clear "br-$bridge" "Bridge $bridge is UP"
        else
            alert_once "br-$bridge" "critical" "Bridge $bridge is DOWN" "Bridge $bridge restored"
            issues_found=1
        fi
    done

    return $issues_found
}

# --- Interface Error Checks ---
check_interface_errors() {
    local issues_found=0

    while IFS= read -r line; do
        local interface
        interface=$(awk -F': ' '{print $2}' <<< "$line")
        [ "$interface" = "lo" ] && continue

        local stats
        stats=$(ip -s link show "$interface")
        local rx_err
        rx_err=$(awk '/RX:/{getline; print $3; exit}' <<< "$stats")
        local tx_err
        tx_err=$(awk '/TX:/{getline; print $3; exit}' <<< "$stats")

        # Check for error deltas
        local prev_file="$STATE_DIR/iface-$interface.err"
        if [ -f "$prev_file" ]; then
            local prev_rx
            prev_rx=$(awk '{print $1}' "$prev_file")
            local prev_tx
            prev_tx=$(awk '{print $2}' "$prev_file")
            local delta_rx=$((rx_err - prev_rx))
            local delta_tx=$((tx_err - prev_tx))

            if [ $delta_rx -ge "$INTERFACE_ERROR_DELTA_THRESHOLD" ]; then
                alert_once "iface-rx-$interface" "warning" "High RX errors on $interface: +$delta_rx" "RX errors on $interface stable"
                issues_found=1
            else
                alert_clear "iface-rx-$interface" "RX errors on $interface stable"
            fi

            if [ $delta_tx -ge "$INTERFACE_ERROR_DELTA_THRESHOLD" ]; then
                alert_once "iface-tx-$interface" "warning" "High TX errors on $interface: +$delta_tx" "TX errors on $interface stable"
                issues_found=1
            else
                alert_clear "iface-tx-$interface" "TX errors on $interface stable"
            fi
        fi

        echo "$rx_err $tx_err" > "$prev_file"
    done < <(ip -o link show up | awk -F': ' '{print $2}' | awk -F'@' '{print $1}' | sed 's/:.*//')

    return $issues_found
}

# --- SSH Security Checks ---
check_ssh_security() {
    local issues_found=0

    # Check for failed login attempts
    local failed_logins
    failed_logins=$(
        { journalctl -q -S "-10 minutes" -u ssh -u sshd 2>/dev/null || true; } |
        grep -c "Failed password"
    )

    if [ "${failed_logins:-0}" -ge "$SSH_FAILED_LOGIN_THRESHOLD" ]; then
        alert_once "ssh-bruteforce" "warning" "High SSH failures: $failed_logins in last 10m" "SSH failures restored"
        issues_found=1
    else
        alert_clear "ssh-bruteforce" "SSH failures normal: $failed_logins in last 10m"
    fi

    # Check concurrent SSH connections
    local ssh_connections
    ssh_connections=$(ss -tan 'sport = :22' 2>/dev/null | grep -c ESTAB || true)
    if [ "${ssh_connections:-0}" -ge "$SSH_CONNECTION_WARNING_THRESHOLD" ]; then
        alert_once "ssh-conns" "warning" "High SSH connections: $ssh_connections" "SSH connections restored"
        issues_found=1
    else
        alert_clear "ssh-conns" "SSH connections normal: $ssh_connections"
    fi

    return $issues_found
}

# --- System Event Checks ---
check_system_events() {
    local issues_found=0

    # Check for OOM kills
    if timeout 10s journalctl -k -S "-10 minutes" 2>/dev/null | grep -qiE "Out of memory|oom-killer|Killed process"; then
        alert_once "oom" "critical" "OOM kill detected in last 10 minutes" "OOM condition cleared"
        issues_found=1
    else
        alert_clear "oom" "No OOM kills detected"
    fi

    # Check for duplicate IP addresses
    if timeout 10s journalctl -S "-10 minutes" 2>/dev/null | grep -qiE "duplicate address|Duplicate address|ARP.*duplicate"; then
        alert_once "dup-ip" "warning" "Duplicate IP/ARP issue detected" "Duplicate IP condition cleared"
        issues_found=1
    else
        alert_clear "dup-ip" "No duplicate IP issues detected"
    fi

    return $issues_found
}

# --- Temperature Monitoring ---
check_temperatures() {
    local issues_found=0

    # Check CPU temperatures
    if command -v sensors >/dev/null 2>&1; then
        local max_temp
        max_temp=$(timeout 10s sensors 2>/dev/null | awk -F'[:+ ]+' '/°C/{print int($(NF-1))}' | sort -nr | head -1)
        if [ -n "${max_temp:-}" ]; then
            if [ "$max_temp" -ge "$CPU_TEMPERATURE_CRITICAL_THRESHOLD" ]; then
                alert_once "cpu-temp" "critical" "CPU temperature critically high: ${max_temp}°C" "CPU temperature restored"
                issues_found=1
            elif [ "$max_temp" -ge "$CPU_TEMPERATURE_WARNING_THRESHOLD" ]; then
                alert_once "cpu-temp" "warning" "CPU temperature high: ${max_temp}°C" "CPU temperature restored"
                issues_found=1
            else
                alert_clear "cpu-temp" "CPU temperature normal: ${max_temp}°C"
            fi
        fi
    fi

    # Check disk temperatures
    while IFS= read -r dev; do
        [ -z "$dev" ] && continue

        if timeout 10s smartctl -H "$dev" >/tmp/smth.$$ 2>/dev/null; then
            if ! grep -q "PASSED" /tmp/smth.$$; then
                alert_once "smart-$dev" "critical" "SMART health problem on $dev" "SMART health restored on $dev"
                issues_found=1
            else
                alert_clear "smart-$dev" "SMART health OK on $dev"
            fi
        fi

        # Check temperature
        local temp
        temp=$(timeout 10s smartctl -A "$dev" 2>/dev/null | awk '/Temperature_Celsius|Temperature Composite|Current Drive Temperature|Temperature:/ {for(i=1;i<=NF;i++){if($i+0==$i){print int($i); exit}}}')
        if [ -n "${temp:-}" ]; then
            if [[ "$dev" == *"nvme"* ]]; then
                if [ "$temp" -ge "$SSD_TEMPERATURE_CRITICAL_THRESHOLD" ]; then
                    alert_once "temp-$dev" "critical" "SSD temperature critically high: ${temp}°C" "SSD temperature restored"
                    issues_found=1
                elif [ "$temp" -ge "$SSD_TEMPERATURE_WARNING_THRESHOLD" ]; then
                    alert_once "temp-$dev" "warning" "SSD temperature high: ${temp}°C" "SSD temperature restored"
                    issues_found=1
                else
                    alert_clear "temp-$dev" "SSD temperature normal: ${temp}°C"
                fi
            else
                if [ "$temp" -ge "$HDD_TEMPERATURE_CRITICAL_THRESHOLD" ]; then
                    alert_once "temp-$dev" "critical" "HDD temperature critically high: ${temp}°C" "HDD temperature restored"
                    issues_found=1
                elif [ "$temp" -ge "$HDD_TEMPERATURE_WARNING_THRESHOLD" ]; then
                    alert_once "temp-$dev" "warning" "HDD temperature high: ${temp}°C" "HDD temperature restored"
                    issues_found=1
                else
                    alert_clear "temp-$dev" "HDD temperature normal: ${temp}°C"
                fi
            fi
        fi

        rm -f /tmp/smth.$$ || true
    done < <(list_disks)

    return $issues_found
}

# --- Backup Monitoring ---
check_backups() {
    local issues_found=0

    # Check for backup failures
    if ls "$VZDUMP_LOG_DIR"/*.log >/dev/null 2>&1; then
        if find "$VZDUMP_LOG_DIR" -type f -mtime -1 -name '*.log' -print0 | xargs -0 grep -q "ERROR:" 2>/dev/null; then
            alert_once "vzdump-fail" "critical" "vzdump backup error found in last 24h" "vzdump backups OK"
            issues_found=1
        else
            alert_clear "vzdump-fail" "vzdump backups OK"
        fi
    fi

    # Check backup age
    if [ -d "$BACKUP_DIR" ]; then
        local last_backup
        last_backup=$(find "$BACKUP_DIR" -type f -printf '%T@\\n' 2>/dev/null | sort -nr | head -1)
        if [ -n "$last_backup" ]; then
            local now
            now=$(date +%s)
            local age_days
            age_days=$(( (now - ${last_backup%.*}) / 86400 ))

            if [ "$age_days" -gt "$BACKUP_MAX_AGE_DAYS" ]; then
                alert_once "backup-age" "warning" "No backups in ${BACKUP_MAX_AGE_DAYS} days (last ${age_days}d)" "Backup recency OK"
                issues_found=1
            else
                alert_clear "backup-age" "Backup recency OK (last ${age_days}d)"
            fi
        fi
    fi

    return $issues_found
}

# --- System Updates Check ---
check_system_updates() {
    local issues_found=0
    local stamp_file="$STATE_DIR/apt-check.stamp"

    if [ ! -f "$stamp_file" ] || [ $(($(date +%s) - $(stat -c %Y "$stamp_file"))) -ge $((APT_CHECK_INTERVAL_HOURS * 3600)) ]; then
        local updates=0
        if [ "${UPDATES_READONLY:-yes}" = "yes" ]; then
            updates=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -ci '^Inst ' || true)
        else
            timeout 30s apt-get update -qq || true
            updates=$(timeout 15s apt list --upgradable 2>/dev/null | grep -Eic "(security|pve-kernel|linux-image)" || true)
        fi

        if [ "$updates" -gt 0 ]; then
            alert_once "updates" "info" "Security/kernel updates available: $updates" "Security updates cleared"
        else
            alert_clear "updates" "No security updates needed"
        fi

        date +%s > "$stamp_file"
    fi

    return $issues_found
}

# --- Virtual Machine Monitoring ---
check_virtual_machines() {
    local issues_found=0

    # Check containers
    pct list 2>/dev/null | awk 'NR>1{print $1,$2}' > "$STATE_DIR/ct.now" || true
    if [ -f "$STATE_DIR/ct.prev" ]; then
        # Find stopped containers that were running
        awk '$2=="running"{print $1}' "$STATE_DIR/ct.prev" > "$STATE_DIR/ct.prev.run"
        awk '$2=="running"{print $1}' "$STATE_DIR/ct.now" > "$STATE_DIR/ct.now.run"

        while read -r id; do
            if ! grep -q "^$id$" "$STATE_DIR/ct.now.run"; then
                alert_once "ct-$id" "warning" "Container $id stopped (was running)" "Container $id restored"
                issues_found=1
            fi
        done < "$STATE_DIR/ct.prev.run"

        # Find started containers that were stopped
        awk '$2=="stopped"{print $1}' "$STATE_DIR/ct.prev" > "$STATE_DIR/ct.prev.stop"
        while read -r id; do
            if grep -q "^$id$" "$STATE_DIR/ct.now.run"; then
                alert_clear "ct-$id" "Container $id restored (running)"
            fi
        done < "$STATE_DIR/ct.prev.stop"
    fi
    mv -f "$STATE_DIR/ct.now" "$STATE_DIR/ct.prev" 2>/dev/null || true

    # Check VMs
    qm list 2>/dev/null | awk 'NR>1{print $1,$3}' > "$STATE_DIR/vm.now" || true
    if [ -f "$STATE_DIR/vm.prev" ]; then
        awk '$2=="running"{print $1}' "$STATE_DIR/vm.prev" > "$STATE_DIR/vm.prev.run"
        awk '$2=="running"{print $1}' "$STATE_DIR/vm.now" > "$STATE_DIR/vm.now.run"

        while read -r id; do
            if ! grep -q "^$id$" "$STATE_DIR/vm.now.run"; then
                alert_once "vm-$id" "warning" "VM $id stopped (was running)" "VM $id restored"
                issues_found=1
            fi
        done < "$STATE_DIR/vm.prev.run"

        awk '$2=="stopped"{print $1}' "$STATE_DIR/vm.prev" > "$STATE_DIR/vm.prev.stop"
        while read -r id; do
            if grep -q "^$id$" "$STATE_DIR/vm.now.run"; then
                alert_clear "vm-$id" "VM $id restored (running)"
            fi
        done < "$STATE_DIR/vm.prev.stop"
    fi
    mv -f "$STATE_DIR/vm.now" "$STATE_DIR/vm.prev" 2>/dev/null || true

    return $issues_found
}

# --- Helper function to list disks ---
list_disks() {
    lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'
    ls /dev/nvme*n* 2>/dev/null || true
}

# --- Main health check function ---
run_all_health_checks() {
    local total_issues=0
    local start_time
    start_time=$(date +%s)

    log_info "Starting comprehensive health check"

    # Check if maintenance mode is active
    if [ -f "$MAINTENANCE_MODE_FILE" ]; then
        log_info "Maintenance mode active - skipping health checks"
        return 0
    fi

    # Run all health checks (respect ENABLE_CHECK_* flags)
    if [ "${ENABLE_CHECK_SERVICES:-yes}" = "yes" ] && run_with_retry check_services; then
        log_debug "All services OK"
    else
        if [ "${ENABLE_CHECK_SERVICES:-yes}" = "yes" ]; then
            log_warning "Service issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "Services check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_DISK:-yes}" = "yes" ] && run_with_retry check_disk_space; then
        log_debug "Disk space OK"
    else
        if [ "${ENABLE_CHECK_DISK:-yes}" = "yes" ]; then
            log_warning "Disk space issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "Disk space check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_ZFS:-yes}" = "yes" ] && run_with_retry check_zfs_pools; then
        log_debug "ZFS pools OK"
    else
        if [ "${ENABLE_CHECK_ZFS:-yes}" = "yes" ]; then
            log_warning "ZFS pool issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "ZFS check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_MEMORY:-yes}" = "yes" ] && run_with_retry check_memory; then
        log_debug "Memory usage OK"
    else
        if [ "${ENABLE_CHECK_MEMORY:-yes}" = "yes" ]; then
            log_warning "Memory issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "Memory check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_LOAD:-yes}" = "yes" ] && run_with_retry check_load_average; then
        log_debug "Load average OK"
    else
        if [ "${ENABLE_CHECK_LOAD:-yes}" = "yes" ]; then
            log_warning "Load average issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "Load check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_IOWAIT:-yes}" = "yes" ] && run_with_retry check_iowait; then
        log_debug "I/O wait OK"
    else
        if [ "${ENABLE_CHECK_IOWAIT:-yes}" = "yes" ]; then
            log_warning "I/O wait issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "I/O wait check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_NETWORK:-yes}" = "yes" ] && run_with_retry check_network; then
        log_debug "Network connectivity OK"
    else
        if [ "${ENABLE_CHECK_NETWORK:-yes}" = "yes" ]; then
            log_warning "Network issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "Network check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_INTERFACE_ERRORS:-yes}" = "yes" ] && run_with_retry check_interface_errors; then
        log_debug "Interface errors OK"
    else
        if [ "${ENABLE_CHECK_INTERFACE_ERRORS:-yes}" = "yes" ]; then
            log_warning "Interface error issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "Interface error check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_SSH:-yes}" = "yes" ] && run_with_retry check_ssh_security; then
        log_debug "SSH security OK"
    else
        if [ "${ENABLE_CHECK_SSH:-yes}" = "yes" ]; then
            log_warning "SSH security issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "SSH check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_SYSTEM_EVENTS:-yes}" = "yes" ] && run_with_retry check_system_events; then
        log_debug "System events OK"
    else
        if [ "${ENABLE_CHECK_SYSTEM_EVENTS:-yes}" = "yes" ]; then
            log_warning "System event issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "System events check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_TEMPS:-yes}" = "yes" ] && run_with_retry check_temperatures; then
        log_debug "Temperatures OK"
    else
        if [ "${ENABLE_CHECK_TEMPS:-yes}" = "yes" ]; then
            log_warning "Temperature issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "Temperature check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_BACKUPS:-yes}" = "yes" ] && run_with_retry check_backups; then
        log_debug "Backups OK"
    else
        if [ "${ENABLE_CHECK_BACKUPS:-yes}" = "yes" ]; then
            log_warning "Backup issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "Backups check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_UPDATES:-yes}" = "yes" ] && run_with_retry check_system_updates; then
        log_debug "System updates OK"
    else
        if [ "${ENABLE_CHECK_UPDATES:-yes}" = "yes" ]; then
            log_warning "System update issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "System updates check disabled"
        fi
    fi

    if [ "${ENABLE_CHECK_VMS:-yes}" = "yes" ] && run_with_retry check_virtual_machines; then
        log_debug "Virtual machines OK"
    else
        if [ "${ENABLE_CHECK_VMS:-yes}" = "yes" ]; then
            log_warning "Virtual machine issues detected"
            total_issues=$((total_issues + 1))
        else
            log_info "VM/CT checks disabled"
        fi
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_info "Health check completed in ${duration}s. Issues found: $total_issues"

    return $total_issues
}
