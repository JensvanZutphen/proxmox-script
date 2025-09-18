#!/bin/bash
# Emergency stop for all automation jobs

set -euo pipefail

CRON_FILE="/etc/cron.d/proxmox-automation"
CONFIG_FILE="/etc/proxmox-health/automation.conf"

# log writes messages to stderr prefixed with `[emergency-stop]`.
log() { echo "[emergency-stop] $*" >&2; }

# confirm prompts "Disable all automation now? [y/N]" and returns 0 if the user answers yes (case-insensitive, accepts "y" or "yes"); treats any other response or EOF as no and returns 1.
confirm() {
    read -r -p "Disable all automation now? [y/N] " ans || ans="n"
    case "$ans" in
        [yY][eE][sS]|[yY]) return 0;;
        *) return 1;;
    esac
}

# main performs an emergency stop of all Proxmox automation: optionally confirms unless invoked with `--yes`, removes the cron job file, attempts to reload cron, and disables automation flags in the configuration file.
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
        sudo sed -ri 's/^[[:space:]]*AUTOMATION_([A-Z0-9_]+)_ENABLED[[:space:]]*=.*/AUTOMATION_\1_ENABLED="no"/' "$CONFIG_FILE"
        log "Disabled automation flags in $CONFIG_FILE"
    else
        log "Config file not found: $CONFIG_FILE"
    fi

    log "Emergency stop completed."
}

main "$@"


