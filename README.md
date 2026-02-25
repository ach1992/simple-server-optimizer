# Simple Server Optimizer (SSO)

A small, menu-driven Bash toolkit to apply common server hardening and performance tweaks on **Debian / Ubuntu**.

It is designed to be:
- **Interactive** (menu UI)
- **Idempotent** (re-running should not stack duplicate rules)
- **Persistent** (settings that must survive reboots are restored automatically via systemd)

> ⚠️ This project makes low-level network / kernel / firewall changes. Always test on a staging server first.

---

## Features

- **Firewall automation**
  - Applies a managed ruleset (nftables or iptables/ipset depending on what is available)
  - Cleans up previously created SSO rules before re-applying
  - **Persists across reboot** via a dedicated systemd restore service

- **Fail2Ban helper**
  - Ensures `/etc/fail2ban/jail.local` exists (created if missing)
  - Syncs `ignoreip` from your whitelist

- **CPU / IRQ / RPS tuning**
  - NIC detection and network queue tuning (RPS/RFS/XPS) where applicable
  - **Persists across reboot** via a dedicated systemd restore service + sysctl drop-in

- **Rollback**
  - Limited rollback that removes **only the files/services created by SSO**
  - Does **not** overwrite or delete unrelated system configs

---

## Supported OS

- Debian 10/11/12
- Ubuntu 20.04 / 22.04 / 24.04

Other distributions are **not** targeted (by design).

---

## Quick Start

### Option A: One-line installer (recommended)
Run this as root (Debian/Ubuntu):
```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/ach1992/simple-server-optimizer/main/install.sh)
```

### Option B: Offline / local install
Clone or download the repository to your server, then:
```bash
sudo bash install.sh
```

### Run after installation (no reinstall needed)
The installer creates a small launcher command:
```bash
sudo sso
```

If you prefer the direct path:
```bash
sudo bash /root/simple-server-optimizer/sso.sh
```

---

## IMPORTANT: How to run (stdin/TTY note)

Some users run installers like this:
```bash
curl -fsSL <URL> | bash
```

That pattern may break interactive input for menu scripts in many projects because `read` consumes piped stdin.

SSO is patched to read input from `/dev/tty` when available, so menus should still work even when stdin is piped.  
Still, the most reliable approach is to download first and run locally:

```bash
sudo bash install.sh
```

---

## Installation Mode: Online vs Offline

SSO follows this logic:

- If an **offline payload** (the required files) is detected inside the install folder, the installer will ask whether to use it.
- If no offline payload is found, the installer **auto-installs online** (no unnecessary questions).

---

## Persistence (Survive Reboot)

SSO creates systemd services so that firewall and sysfs-based tuning are re-applied after reboot.

### Firewall persistence
Files created:
- `/usr/local/sbin/sso-firewall-restore`
- `/etc/systemd/system/sso-firewall.service`

Service behavior:
- Restores the SSO-managed firewall rules on boot.

Check status:
```bash
systemctl status sso-firewall.service
```

### CPU/IRQ & RPS/RFS/XPS persistence
Files created:
- `/usr/local/sbin/sso-cpuirq-restore`
- `/etc/systemd/system/sso-cpuirq.service`
- `/etc/sysctl.d/99-sso-rps.conf`  (sysctl persistence for related knobs)

Check status:
```bash
systemctl status sso-cpuirq.service
```

---

## Rollback (Safe / Limited)

Rollback removes **only SSO-managed artifacts**, such as:
- `/etc/sysctl.d/99-sso-*.conf` and `/etc/sysctl.d/99-sso-rps.conf`
- `/etc/modules-load.d/bbr.conf` (if created by SSO)
- `sso-firewall.service`, `sso-cpuirq.service` and restore scripts
- SSO-related backups created by the toolkit

It does **NOT**:
- Delete or overwrite unrelated `/etc/sysctl.d/*` files
- Reset custom firewall rules not created by SSO

Run rollback from the menu or via the rollback module (depending on your workflow).

---

## Firewall Notes

- The toolkit tries to use the best available backend on your system.
- If `nft` is available, SSO may prefer nftables.
- If iptables/ipset is used, rules are re-applied on boot by SSO’s systemd service.

> Tip: If you maintain your own firewall, review the generated rules carefully before enabling.

---

## Files & Directories Created by SSO

Common paths:
- `/etc/ssoptimizer/install_dir` (stores install directory for restore services)
- `/etc/sysctl.d/99-sso-*.conf` (SSO sysctl settings)
- `/usr/local/sbin/sso-*-restore` (restore scripts)
- `/etc/systemd/system/sso-*.service` (systemd services)

---

## Troubleshooting

### Menu input does nothing
- Ensure you are running as root:
  ```bash
  sudo bash sso.sh
  ```
- If running via a pipe, make sure `/dev/tty` exists (normally it does in an interactive SSH session).

### Firewall rules disappear after reboot
- Verify the restore service is enabled:
  ```bash
  systemctl is-enabled sso-firewall.service
  systemctl status sso-firewall.service
  ```
- Re-apply from the menu once, then reboot and re-check.

### Check if BBR is active
Run:
```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

### NIC detection issues
If the server has unusual routing (no default route), NIC auto-detection may fall back to a default (e.g., `eth0`).  
You can adjust NIC selection logic in the networking module if needed.

---

## Security & Safety

- Always review changes before applying on production.
- Keep an out-of-band console access when testing firewall changes.
- Use snapshots where possible.

---

## License
License (MIT).
