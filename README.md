# Simple Server Optimizer (SSO)

Simple Server Optimizer is a small, menu-driven Bash toolkit for **Debian / Ubuntu servers used primarily as VPN/proxy nodes**. It focuses on practical network tuning, firewall/abuse controls, persistence, diagnostics, and safe recovery without requiring a heavyweight management stack.

The project is intentionally conservative: tuning should be applied because it fits the detected server/workload, not because a kernel setting is popular in generic optimization guides.

It is designed to be:

- **Interactive** — simple menu-driven operation;
- **Idempotent** — re-running supported operations should converge instead of stacking duplicate state;
- **Persistent** — settings that must survive reboot are restored through explicit SSO-owned mechanisms;
- **Reversible** — SSO-owned changes should have credible rollback/uninstall behavior;
- **VPN/proxy aware** — project direction prioritizes the real needs of routed VPNs and proxy workloads.

> ⚠️ SSO makes low-level network, kernel, firewall, service, and package changes as root. Keep snapshot/out-of-band console access when testing on important servers.

---

## Current Features

The current codebase provides:

- **Firewall automation**
  - managed blocklist/whitelist state with strict IPv4/CIDR validation and redundant-network collapse;
  - nftables or iptables/ipset backend depending on availability;
  - fast bulk/staged application instead of one backend process per list entry;
  - blacklist/whitelist add/remove updates the active SSO firewall immediately when it is enabled;
  - SSO-namespaced rules and reboot persistence through an SSO systemd restore service;
  - common BitTorrent/P2P port blocking as a best-effort port rule, not a complete protocol detector.

- **Fail2Ban helper**
  - SSH-focused setup;
  - optional nginx jail support;
  - whitelist synchronization.

- **Network tuning**
  - fq + BBR activation when supported;
  - TCP-related sysctl tuning.

- **CPU / IRQ / RPS / RFS / XPS tuning**
  - NIC detection;
  - irqbalance helper;
  - queue-related tuning and reboot persistence where supported.

- **Backups, rollback, update, and uninstall**
  - SSO-specific backup/restore paths;
  - online/offline installer flow;
  - launcher command (`sso`).

### Current stabilization work

The project is preparing **v1.1.0**, focused on correctness and safety before larger VPN-aware features are added. This includes repairing known Fail2Ban, rollback/uninstall, installer/update, CPU persistence, and firewall validation/performance issues and establishing automated regression checks.

Current work, acceptance criteria, and dependencies live in GitHub Issues rather than in this README.

---

## Project Direction

SSO is evolving from a generic server-tuning script into a **safe, adaptive VPN/proxy server optimizer and abuse-protection toolkit**.

After the v1.1.0 stabilization release and real-server owner validation, planned areas include:

- firewall scopes that explicitly understand `INPUT`, `OUTPUT`, and routed `FORWARD` traffic;
- IPv4 + IPv6 firewall sets;
- faster atomic/bulk firewall list management;
- firewall counters/search/explainability;
- a read-only **VPN Doctor** for MTU/PMTU, forwarding, conntrack, queue/drop, congestion-control, and firewall health;
- protocol-aware recommendations/profiles for WireGuard, OpenVPN, Xray/VLESS/Reality, Hysteria/TUIC/QUIC, and mixed nodes;
- adaptive rather than fixed RPS/RFS/XPS/TCP/UDP tuning;
- managed abuse/blocklist operations with provenance, diff, and rollback where useful.

The roadmap is tracked in GitHub Issues so live status is not duplicated into documentation.

---

## Supported OS

Current documented targets:

- Debian 10 / 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04

Other distributions are not targeted by design.

Version support is a compatibility contract. Changes to this list should be backed by actual validation of the packages/commands/kernel behavior used by SSO.

---

## Quick Start

### Option A: online installer

Current `main` installer:

```bash
curl -fsSL https://raw.githubusercontent.com/ach1992/simple-server-optimizer/main/install.sh -o /tmp/sso-install.sh \
  && sudo bash /tmp/sso-install.sh
```

> Security note: the v1.1.0 stabilization work is replacing mutable-branch-only update trust with an immutable release + integrity-verification model. For important production systems, prefer a reviewed release once v1.1.0 is published.

### Option B: local/offline install

Clone or download the repository, then:

```bash
sudo bash install.sh
```

The v1.1.0 stabilization work includes fixing local payload detection so this path reliably uses the actual directory containing the installer payload.

### Run after installation

```bash
sudo sso
```

Direct path:

```bash
sudo bash /root/simple-server-optimizer/sso.sh
```

---

## Interactive Input / TTY

Piping an interactive installer directly into Bash can cause `read` to consume piped stdin in many scripts. SSO attempts to read interactive input from `/dev/tty` when available.

The most predictable pattern is still:

```bash
curl -fsSL <URL> -o /tmp/installer.sh
sudo bash /tmp/installer.sh
```

---

## Persistence

### Firewall

Common SSO-owned artifacts:

- `/usr/local/sbin/sso-firewall-restore`
- `/etc/systemd/system/sso-firewall.service`

Check:

```bash
systemctl is-enabled sso-firewall.service
systemctl status sso-firewall.service
```

### CPU / IRQ / RPS / RFS / XPS

Common SSO-owned artifacts:

- `/usr/local/sbin/sso-cpuirq-restore`
- `/etc/systemd/system/sso-cpuirq.service`
- `/etc/sysctl.d/99-sso-rps.conf`

Check:

```bash
systemctl is-enabled sso-cpuirq.service
systemctl status sso-cpuirq.service
```

---

## Firewall Notes

- SSO detects nftables first and may fall back to iptables/ipset.
- Firewall lists are validated before apply; malformed input aborts without replacing active policy.
- nftables uses an inactive staging table, bounded set batches, and a small final activation transaction so traffic does not observe partially populated sets.
- the iptables/ipset fallback uses bulk set restore/swap plus `iptables-restore --test` before activation.
- SSO uses namespaced firewall objects and should not assume ownership of unrelated firewall policy.
- The v1.1 stabilization scope still manages host `INPUT`/`OUTPUT`; explicit VPN routed-traffic (`FORWARD`) coverage is planned only after the v1.1.0 real-server test gate.
- “Common P2P/BitTorrent ports” is best-effort abuse reduction only; it is not complete BitTorrent/P2P protocol detection.

If you maintain another firewall manager, review interactions carefully before enabling SSO rules.

---

## BBR Check

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

SSO's future tuning direction is workload-aware: TCP settings are not assumed to optimize UDP/routed VPN traffic automatically.

---

## State and Owned Paths

Common SSO paths include:

- `/etc/sso/` — persistent SSO runtime state;
- `/etc/sysctl.d/99-sso-*.conf` — SSO-owned sysctl drop-ins;
- `/usr/local/bin/sso` — launcher;
- `/usr/local/sbin/sso-*-restore` — restore helpers;
- `/etc/systemd/system/sso-*.service` — persistence units;
- `/root/simple-server-optimizer/backups` — current backup location.

SSO should preserve unrelated operator configuration. See `docs/ARCHITECTURE.md` for ownership and rollback boundaries.

---

## Troubleshooting

### Menu input does nothing

Run from an interactive root-capable shell:

```bash
sudo sso
```

If `/dev/tty` is unavailable, interactive input cannot behave normally.

### Firewall rules disappear after reboot

```bash
systemctl is-enabled sso-firewall.service
systemctl status sso-firewall.service
```

### NIC detection issues

The current implementation uses the default route where possible and falls back to the first suitable non-loopback interface. Multi-interface/VPN-aware detection will become more explicit as the VPN Doctor/profile work is implemented.

---

## Security & Safety

- Use snapshots/backups where possible before testing a release on an important server.
- Keep out-of-band console access when changing firewall/network settings remotely.
- Do not treat a successful command exit as proof that a complex firewall/configuration change fully applied; SSO's stabilization work is adding stronger validation/verification for these paths.
- Do not hardcode credentials or private service data into SSO configuration or repository files.

---

## Project Documentation

Routine development/recovery should use the source closest to the question:

- [`AGENTS.md`](AGENTS.md) — contributor/agent operating rules and recovery entry;
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — implementation ownership, mutation, firewall, tuning, rollback, and test boundaries;
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — development, validation, CI, review, and release workflow;
- GitHub Issues — live roadmap, priorities, dependencies, acceptance, and release work;
- Pull Requests / Git / CI — implementation and validation truth.

`PROJECT-SPEC.md` is the bootstrap specification used to establish project direction and these derived systems. It is not part of normal session recovery unless project-level intent itself becomes unclear or changes.

---

## Contributing

Before substantive work, read `AGENTS.md` and the active GitHub Issue, then follow `docs/DEVELOPMENT.md`.

---

## License

MIT. See [`LICENSE`](LICENSE).