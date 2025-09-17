# Proxmox Health Monitoring Suite

Comprehensive health monitoring and alerting for Proxmox VE clusters. The suite installs a collection of Bash tools, scheduled tasks, and helper libraries that continuously check cluster health, collect telemetry, and notify on actionable events via Discord (and optional email/syslog outputs).

## Highlights

- **Holistic coverage** – services, storage, ZFS pools, memory/swap, CPU load, I/O wait, network connectivity/bridges, interface errors, SSH anomalies, system events, temperatures, backup recency, package updates, and VM lifecycle changes.
- **Notification routing** – Discord webhooks out of the box, optional email + syslog, and built-in alert throttling/cooldown logic to prevent noisy repeat alerts.
- **Daily summaries** – dedicated `proxmox-health-summary.sh` script powered by a systemd timer (or cron) so alert digests are delivered even without classic cron.
- **Installer TUI** – interactive whiptail wizard captures cluster-specific preferences (check cadence, ping target, monitored bridges, notification topics, summary time, and more) and persists them in `/etc/proxmox-health/proxmox-health.conf.local`.
- **Dual scheduler support** – choose systemd timers or cron during install; switching later is supported via the `--configure` flow.
- **Idempotent + configurable** – a layered configuration approach (`proxmox-health.conf` + `.local` overrides) keeps upstream defaults intact while allowing cluster-specific tuning.
- **Self-contained libraries** – reusable modules under `lib/` expose logging, caching, alerting, and check utilities that can be consumed by your own extensions.

## Repository Layout

```
.
├── config/                     # Baseline configuration (copied into /etc/proxmox-health)
├── install-proxmox-health.sh   # Main installer with TUI + scheduling logic
├── uninstall-proxmox-health.sh # Clean removal script
├── lib/                        # Shared Bash libraries (checks, notifications, utils, installer helpers)
├── tests/                      # Lightweight validation helpers and framework harness
└── README.md                   # You are here
```

## Installation

> ⚠️ **Run as root on the Proxmox host** (the installer writes to `/etc`, `/usr/local/bin`, `/usr/local/lib`, and manipulates systemd units/cron).

1. Clone or download the repository on the Proxmox node.
2. Execute the installer:
   ```bash
   sudo ./install-proxmox-health.sh --tui
   ```
3. The wizard will prompt for:
   - Components to install (deps, config, libraries, binaries, cron, logrotate, systemd timer, example configs, initial auto-detected tuning)
   - Scheduler preference (systemd timer vs cron)
   - Health check interval (minutes)
   - Ping host for connectivity tests
   - Space/comma-separated list of network bridges to monitor (blank disables bridge checks)
   - Daily summary time (HH:MM, 24-hour)
   - Notification topics (what gets checked vs what triggers alerts)
   - Optional Discord webhook validation + test message

4. After the installer completes, review the post-install message for next steps (editing the webhook secret, tailing logs, etc.).

### Non-interactive installs

Use `--no-tui` to accept defaults, or pre-create `/etc/proxmox-health/proxmox-health.conf.local` before running the installer.

### Reconfiguration without reinstall

To re-run the TUI and apply new preferences without reinstalling binaries:
```bash
sudo ./install-proxmox-health.sh --tui --configure
```
This updates `/etc/proxmox-health/proxmox-health.conf.local`, ensures the chosen scheduler is active, and leaves other components untouched.

## Uninstallation

To remove all installed components:
```bash
sudo ./uninstall-proxmox-health.sh
```
You will be prompted before configuration/state directories are deleted.

## Runtime Components

| Path / Unit | Description |
|-------------|-------------|
| `/usr/local/bin/proxmox-healthcheck.sh` | One-shot orchestration script that runs every enabled check with retry/cooldown logic. |
| `/usr/local/bin/proxmox-notify.sh`      | Thin wrapper to send manual notifications (`proxmox-notify.sh "message" "level"`). |
| `/usr/local/bin/proxmox-health-summary.sh` | Generates and dispatches the daily summary digest. |
| `/usr/local/bin/proxmox-maintenance.sh` | CLI helper to enable/disable/status maintenance mode (pauses alerts). |
| `/etc/systemd/system/proxmox-health.service(.timer)` | Systemd units for periodic health checks. |
| `/etc/systemd/system/proxmox-health-summary.service(.timer)` | Systemd units for daily summary dispatch. |
| `/etc/cron.d/proxmox-health` | Optional cron schedule when cron mode is selected. |
| `/etc/proxmox-health/` | Configuration root (`proxmox-health.conf`, `.conf.local`, custom checks, plugins). |
| `/usr/local/lib/proxmox-health/` | Library modules (`*.sh`) sourced by binaries and extensions. |
| `/var/log/proxmox-health/` | Log directory (main log, summaries). |
| `/var/tmp/proxmox-health/` | State/cache files (e.g., alert state, interface error deltas). |

## Configuration Files

- `config/proxmox-health.conf` (repo) → `/etc/proxmox-health/proxmox-health.conf`: upstream defaults (thresholds, directories, toggles).
- `/etc/proxmox-health/proxmox-health.conf.local`: installer-generated overrides (editable safely). Contains TUI selections such as:
  - `HEALTH_CHECK_INTERVAL_MINUTES`
  - `PING_TEST_HOST`
  - `MONITORED_BRIDGES`
  - `DAILY_SUMMARY_TIME`
  - `ENABLE_CHECK_*` / `NOTIFY_*` flags
- `/etc/proxmox-health/webhook-secret`: Discord webhook URL (single line). Managed by the installer when provided in TUI.

### Adding Custom Checks / Plugins

Drop executable scripts into:
- `/etc/proxmox-health/custom-checks/` – run concurrently with core checks.
- `/etc/proxmox-health/plugins/` – for more complex extension points.
Example templates are created when the “examples” component is selected during installation.

## Daily Summary

- The systemd timer `proxmox-health-summary.timer` (or cron equivalent) triggers `proxmox-health-summary.sh` at the configured time.
- The script compiles active alerts from `$STATE_DIR` and sends a digest via the existing notification channels (`summary` category).
- Adjust the time by editing `DAILY_SUMMARY_TIME` in `/etc/proxmox-health/proxmox-health.conf.local` and re-running `sudo systemctl restart proxmox-health-summary.timer` (or reinstall with `--configure`).

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `sudo proxmox-healthcheck.sh` | Run all enabled checks immediately. |
| `sudo proxmox-health-summary.sh` | Generate/send the daily summary on demand. |
| `sudo proxmox-notify.sh "Message" [level]` | Send an ad-hoc alert (levels: info, warning, critical, etc.). |
| `sudo proxmox-maintenance.sh enable 2h "Kernel upgrade"` | Enter maintenance mode (pauses alerts). |
| `sudo proxmox-maintenance.sh disable` | Exit maintenance mode. |
| `sudo proxmox-maintenance.sh status` | Display maintenance status. |

## Logging & State

- Primary log: `/var/log/proxmox-health/proxmox-health.log`
- Alert state files: `/var/tmp/proxmox-health/*.notify`
- Summary cache: `/var/tmp/proxmox-health/alert_summary.txt`
- Installer writes backups to `/tmp/proxmox-health-backup-YYYYMMDD_HHMMSS/` before overwriting an existing deployment.

## Development & Testing

### Linting / Static Analysis

```bash
shellcheck install-proxmox-health.sh lib/*.sh tests/*.sh
```

### Smoke Tests

- `tests/test-input-validation.sh` – exercises installer validation helpers.
- `tests/test-framework.sh` – reusable harness for additional integration tests (currently supports targeted helper/unit testing; extend as desired).

Feel free to add new tests under `tests/` and source the framework for structured output.

## Troubleshooting

- **No Discord alerts**: Ensure `/etc/proxmox-health/webhook-secret` contains a valid URL, or rerun the installer TUI to validate/test the webhook.
- **Cron vs systemd conflicts**: Re-run the installer with `--configure` and choose the scheduler you want; the script will disable the other mode.
- **Permission issues**: All binaries expect to run as root (systemd timers, cron jobs, manual runs). Verify scripts are executable (`chmod 755`).
- **Adjusting thresholds**: Edit `/etc/proxmox-health/proxmox-health.conf.local`, then run `sudo systemctl start proxmox-health.service` (or the cron job will pick up changes on next run).

## Contributing

1. Fork or branch off main.
2. Make changes (keep scripts POSIX/Bash-compatible).
3. Run ShellCheck + relevant smoke tests.
4. Submit a pull request with a concise summary.

## License

This project is distributed under the MIT License. See `LICENSE` (add one if you intend to publish publicly).

## Support & Feedback

Issues and feature requests are welcome—open an issue or discussion in the public repository once you push it live. For private questions, reach out directly to the maintainer.
