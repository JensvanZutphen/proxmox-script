# Proxmox Health Monitoring Suite 🩺

> Comprehensive monitoring, alerting, and daily reporting for your Proxmox VE clusters.

Keep your cluster healthy with a curated set of Bash tools: scheduled health checks, actionable alerts, daily summaries, and extensible libraries—all packaged in a guided installer that tailors settings to your environment.

---

## ✨ Highlights
- **Holistic coverage**: services, storage, ZFS pools, memory/swap, CPU load, I/O wait, networking, SSH, system events, temperatures, backups, updates, and VM lifecycle changes.
- **Notification routing**: Discord webhook support out of the box, optional email/syslog, plus cooldown logic to avoid alert storms.
- **Daily summaries**: systemd (or cron) timer drives `proxmox-health-summary.sh` so you receive digest reports even without classic cron.
- **Installer TUI**: interactive wizard captures interval, ping host, monitored bridges, summary time, and notification topics—persisted safely to `/etc/proxmox-health/proxmox-health.conf.local`.
- **Scheduler flexibility**: choose systemd timers or cron during install; the `--configure` path lets you switch later.
- **Layered configuration**: upstream defaults live in `proxmox-health.conf`; overrides land in `.conf.local`, keeping your tweaks cleanly separated.
- **Extensible libraries**: reusable modules in `lib/` expose logging, caching, alerting, and helper utilities for your own scripts.

---

## 🗂 Repository Layout
```
├── config/                     # Baseline configuration (copied to /etc/proxmox-health)
├── install-proxmox-health.sh   # Main installer with TUI + scheduling logic
├── uninstall-proxmox-health.sh # Clean removal script
├── lib/                        # Shared Bash libraries (checks, notifications, utils, installer helpers)
├── tests/                      # Lightweight validation scripts + harness
└── README.md                   # You are here
```

---

## 🚀 Installation
> **Run as root on the Proxmox host**—the installer writes to `/etc`, `/usr/local/bin`, `/usr/local/lib`, creates systemd units, cron entries, etc.

1. Clone/download the repository on your Proxmox node.
2. Launch the installer:
   ```bash
   ./install-proxmox-health.sh --tui
   ```
3. Follow the wizard prompts to choose components, scheduler, check interval, ping host, monitored bridges, daily summary time, notification topics, and (optionally) validate a Discord webhook.
4. After completion, review the summary for next steps (editing the webhook secret, tailing logs, etc.).

### Non-interactive installs
Use `./install-proxmox-health.sh --no-tui` to accept defaults, or pre-create `/etc/proxmox-health/proxmox-health.conf.local` before running the installer.

### Reconfigure without reinstalling
Update preferences later by re-running the wizard:
```bash
./install-proxmox-health.sh --tui --configure
```
This refreshes overrides, ensures the chosen scheduler is active, and leaves binaries/libraries untouched.

---

## ♻️ Uninstallation
Remove all installed components:
```bash
./uninstall-proxmox-health.sh
```
You’ll be prompted before configuration/state directories are deleted.

---

## 🧰 Runtime Components
| Path / Unit                                           | Description |
|-------------------------------------------------------|-------------|
| `/usr/local/bin/proxmox-healthcheck.sh`               | Orchestrates all enabled checks with retry + cooldown handling. |
| `/usr/local/bin/proxmox-notify.sh`                    | Sends ad-hoc notifications (`proxmox-notify.sh "message" "level"`). |
| `/usr/local/bin/proxmox-health-summary.sh`            | Generates and dispatches the daily summary digest. |
| `/usr/local/bin/proxmox-maintenance.sh`               | CLI for maintenance mode (enable/disable/status). |
| `/etc/systemd/system/proxmox-health.service(.timer)`  | Periodic health-check systemd units. |
| `/etc/systemd/system/proxmox-health-summary.service(.timer)` | Daily summary systemd units. |
| `/etc/cron.d/proxmox-health`                          | Cron schedule (when cron mode is selected). |
| `/etc/proxmox-health/`                                | Configuration root (`proxmox-health.conf`, `.conf.local`, custom checks, plugins). |
| `/usr/local/lib/proxmox-health/`                      | Shared libraries sourced by binaries and extensions. |
| `/var/log/proxmox-health/`                            | Log directory (main log, summaries). |
| `/var/tmp/proxmox-health/`                            | State/cache (alert markers, interface deltas, summaries). |

---

## ⚙️ Configuration Files
- `config/proxmox-health.conf` → `/etc/proxmox-health/proxmox-health.conf`: upstream defaults.
- `/etc/proxmox-health/proxmox-health.conf.local`: installer-generated overrides (editable safely). Expect entries like:
  - `HEALTH_CHECK_INTERVAL_MINUTES`
  - `PING_TEST_HOST`
  - `MONITORED_BRIDGES`
  - `DAILY_SUMMARY_TIME`
  - `ENABLE_CHECK_*` / `NOTIFY_*`
- `/etc/proxmox-health/webhook-secret`: Discord webhook URL (single line). Created by the installer if provided.

### Custom checks & plugins
Drop executables into:
- `/etc/proxmox-health/custom-checks/` – run alongside built-in checks.
- `/etc/proxmox-health/plugins/` – more sophisticated extension points.
Example templates are generated when you select “example configs” during installation.

---

## 🗓 Daily Summary
- `proxmox-health-summary.timer` (or cron) triggers `proxmox-health-summary.sh` at your configured `DAILY_SUMMARY_TIME`.
- The script compiles active alerts from `$STATE_DIR` and sends a digest (category `summary`).
- Adjust timing by editing `DAILY_SUMMARY_TIME` in `/etc/proxmox-health/proxmox-health.conf.local` and re-running `systemctl restart proxmox-health-summary.timer` (or re-run the installer with `--configure`).

---

## 🛠 Command Cheat Sheet
| Command | Purpose |
|---------|---------|
| `proxmox-healthcheck.sh` | Run all enabled checks instantly. |
| `proxmox-health-summary.sh` | Generate/send the daily summary on demand. |
| `proxmox-notify.sh "Message" [level]` | Send a quick alert (levels: info, warning, critical, etc.). |
| `proxmox-maintenance.sh enable 2h "Kernel upgrade"` | Enter maintenance mode (silences alerts). |
| `proxmox-maintenance.sh disable` | Exit maintenance mode. |
| `proxmox-maintenance.sh status` | Show maintenance status/reason. |

---

## 📜 Logging & State
- Primary log: `/var/log/proxmox-health/proxmox-health.log`
- Alert state files: `/var/tmp/proxmox-health/*.notify`
- Summary cache: `/var/tmp/proxmox-health/alert_summary.txt`
- Installer automatically backs up existing installs to `/tmp/proxmox-health-backup-YYYYMMDD_HHMMSS/`

---

## 🧪 Development & Testing
- **Lint**: `shellcheck install-proxmox-health.sh lib/*.sh tests/*.sh`
- **Validation helpers**:
  - `tests/test-input-validation.sh` – verifies installer sanitizers/validators.
  - `tests/test-framework.sh` – harness you can reuse for custom test suites.

Add new tests under `tests/`, sourcing the framework for consistent reporting.

---

## 🛠 Troubleshooting
- **No Discord alerts?** Ensure `/etc/proxmox-health/webhook-secret` contains a valid URL, or rerun the installer TUI (optionally send the test message).
- **Switching schedulers?** Rerun `./install-proxmox-health.sh --tui --configure` and choose the desired scheduler (systemd timer vs cron). The installer disables the other automatically.
- **Permission errors?** Scripts expect root; confirm they’re executable (`chmod 755`).
- **Adjusting thresholds?** Edit `/etc/proxmox-health/proxmox-health.conf.local`, then run `systemctl start proxmox-health.service` (or wait for the next scheduled run).

---

## 🤝 Contributing
1. Fork or branch off `main`.
2. Implement changes (Bash/POSIX-friendly).
3. Run ShellCheck and relevant smoke tests.
4. Submit a PR with a concise summary and testing notes.

---

## 🛠 Development

### Code Formatting
This project uses automated formatting checks to maintain code quality. If you encounter formatting-related CI failures:

**Quick fix for all files:**
```bash
./scripts/fix-formatting.sh
```

**Auto-fix on commit (recommended):**
```bash
ln -sf ../../.github/pre-commit-hook.sh .git/hooks/pre-commit
```

**Manual fixes:**
```bash
# Fix tabs and trailing whitespace
find . -name "*.sh" -exec sed -i -e 's/\t/    /g' -e 's/[[:space:]]*$//' {} +
```

### Running Tests
```bash
cd tests
./run-tests.sh
```

---

## 📄 License
Released under the [MIT License](LICENSE).

---

## 📣 Support & Feedback
- Open issues or discussions once the repo is public.
- For private questions, contact the maintainer directly.

Happy monitoring! 🚀
