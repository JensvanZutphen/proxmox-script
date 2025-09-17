#!/bin/bash
# Emergency stop for all automation jobs

set -euo pipefail

CRON_FILE="/etc/cron.d/proxmox-automation"
CONFIG_FILE="/etc/proxmox-health/automation.conf"

log() { echo "[emergency-stop] $*" >&2; }

confirm() {
    read -r -p "Disable all automation now? [y/N] " ans || ans="n"
    case "$ans" in
        [yY][eE][sS]|[yY]) return 0;;
        *) return 1;;
    esac
}

main() {
    if [ "${1:-}" != "--yes" ]; then
        if ! confirm; then log "Aborted"; exit 1; fi
    fi

    if [ -f "$CRON_FILE" ]; then
        sudo rm -f "$CRON_FILE"
        log "Removed cron file: $CRON_FILE"
        if command -v systemctl >/dev/null 2>&1; then
            sudo systemctl reload cron 2>/dev/null || sudo systemctl reload crond 2>/dev/null || true
        fi
    else
        log "No cron file present: $CRON_FILE"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        sudo sed -i 's/^AUTOMATION_ENABLED=.*/AUTOMATION_ENABLED="no"/' "$CONFIG_FILE"
        sudo sed -i 's/^AUTOMATION_.*_ENABLED=.*/&_DISABLED_PLACEHOLDER/' "$CONFIG_FILE" || true
        # Disable each known job explicitly (idempotent)
        sudo sed -i 's/^AUTOMATION_ZFS_CLEANUP_ENABLED=.*/AUTOMATION_ZFS_CLEANUP_ENABLED="no"/' "$CONFIG_FILE"
        sudo sed -i 's/^AUTOMATION_DISK_CLEANUP_ENABLED=.*/AUTOMATION_DISK_CLEANUP_ENABLED="no"/' "$CONFIG_FILE"
        sudo sed -i 's/^AUTOMATION_MEMORY_RELIEF_ENABLED=.*/AUTOMATION_MEMORY_RELIEF_ENABLED="no"/' "$CONFIG_FILE"
        sudo sed -i 's/^AUTOMATION_SYSTEM_REFRESH_ENABLED=.*/AUTOMATION_SYSTEM_REFRESH_ENABLED="no"/' "$CONFIG_FILE"
        sudo sed -i 's/^AUTOMATION_AUTO_UPDATE_ENABLED=.*/AUTOMATION_AUTO_UPDATE_ENABLED="no"/' "$CONFIG_FILE"
        log "Disabled automation flags in $CONFIG_FILE"
    else
        log "Config file not found: $CONFIG_FILE"
    fi

    log "Emergency stop completed."
}

main "$@"


