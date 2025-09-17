#!/bin/bash
# Uninstall Proxmox Health Monitoring System
set -euo pipefail

confirm() { read -r -p "$1 [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]]; }

SERVICE="/etc/systemd/system/proxmox-health.service"
TIMER="/etc/systemd/system/proxmox-health.timer"
SUMMARY_SERVICE="/etc/systemd/system/proxmox-health-summary.service"
SUMMARY_TIMER="/etc/systemd/system/proxmox-health-summary.timer"
CRON="/etc/cron.d/proxmox-health"
LOGROTATE="/etc/logrotate.d/proxmox-health"
BIN_DIR="/usr/local/bin"
LIB_DIR="/usr/local/lib/proxmox-health"
INSTALL_DIR="/etc/proxmox-health"
STATE_DIR="/var/tmp/proxmox-health"
RUN_DIR="/run/proxmox-health"

echo "Stopping services..."
systemctl disable --now proxmox-health.timer >/dev/null 2>&1 || true
systemctl disable --now proxmox-health.service >/dev/null 2>&1 || true
systemctl disable --now proxmox-health-summary.timer >/dev/null 2>&1 || true
systemctl disable --now proxmox-health-summary.service >/dev/null 2>&1 || true

echo "Removing timers/services..."
rm -f "$SERVICE" "$TIMER" "$SUMMARY_SERVICE" "$SUMMARY_TIMER" || true
systemctl daemon-reload || true

echo "Removing cron and logrotate..."
rm -f "$CRON" "$LOGROTATE" || true

echo "Removing binaries..."
rm -f "$BIN_DIR/proxmox-healthcheck.sh" "$BIN_DIR/proxmox-notify.sh" "$BIN_DIR/proxmox-maintenance.sh" "$BIN_DIR/proxmox-health-summary.sh" || true

echo "Removing libraries..."
rm -rf "$LIB_DIR" || true

if confirm "Remove configuration in $INSTALL_DIR?"; then
  rm -rf "$INSTALL_DIR"
fi

if confirm "Remove state in $STATE_DIR and runtime in $RUN_DIR?"; then
  rm -rf "$STATE_DIR" "$RUN_DIR"
fi

echo "Uninstall completed."
