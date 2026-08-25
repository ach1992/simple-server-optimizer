# Architecture and Safety Boundaries

This document owns the stable implementation boundaries for Simple Server Optimizer (SSO). Current work and priorities live in GitHub Issues; user-facing behavior lives in `README.md`.

## 1. Product shape

SSO is a small Bash-first toolkit for Debian/Ubuntu VPN/proxy nodes. The current application is interactive and module-driven:

```text
install.sh
  -> installs/updates SSO
  -> /usr/local/bin/sso launcher

sso.sh
  -> menu/orchestration
  -> modules/*.sh

modules/
  utils.sh
  network.sh
  cpu_irq.sh
  firewall.sh
  fail2ban.sh
  rollback.sh
  uninstall.sh

assets/
  default lists/data

/etc/sso/
  persistent runtime state
```

Keep this structure simple. Introduce a larger runtime or dependency only when its operational value materially exceeds its installation, security, maintenance, and recovery cost.

## 2. Ownership model

SSO must know what it owns and must not infer ownership merely because a path exists.

### SSO-owned examples

- `/etc/sso/*` runtime state created by SSO;
- `/etc/sysctl.d/99-sso-*.conf`;
- `/etc/systemd/system/sso-*.service`;
- `/usr/local/sbin/sso-*-restore`;
- `/usr/local/bin/sso`;
- explicitly namespaced firewall tables/chains/sets such as `sso*`;
- SSO-specific Fail2Ban drop-ins such as `/etc/fail2ban/jail.d/sso.local`;
- SSO backup/manifest data.

### Operator-owned examples

SSO must not claim ownership of these merely because it needs to interoperate with them:

- `/etc/fail2ban/jail.local`;
- arbitrary `/etc/sysctl.conf` or non-SSO `/etc/sysctl.d/*` files;
- unrelated nftables/iptables tables/chains/rules;
- unrelated systemd units;
- VPN/proxy service configuration owned by WireGuard/OpenVPN/Xray/Hysteria/TUIC or a control panel.

Prefer drop-ins, namespaced resources, and explicit state over editing shared configuration.

## 3. State and mutation contract

Every persistent mutation should follow this model where practical:

```text
DISCOVER CURRENT STATE
  -> VALIDATE INPUT / PRECONDITIONS
  -> CAPTURE PRIOR OWNED STATE
  -> PREPARE NEW STATE
  -> VALIDATE PREPARED STATE
  -> APPLY ATOMICALLY OR IN A BOUNDED ORDER
  -> VERIFY EFFECTIVE STATE
  -> RECORD SSO STATE/MANIFEST
```

A partial failure is not success. Error suppression such as `|| true` is acceptable only when the failure is explicitly non-fatal and the caller still has enough evidence to determine the final result.

## 4. Backup, rollback, and uninstall

A backup must distinguish at least:

- an artifact existed and its content/metadata was captured;
- an artifact did not exist before SSO changed the system;
- a service existed/enabled/active state before SSO touched it;
- SSO installed a package versus a package that already existed.

Rollback should restore the SSO-relevant prior state, including absence when appropriate. It must not recreate a service/file merely because the current system still contains a newer SSO artifact.

Uninstall must remove every SSO-owned persistent artifact that the installed version created, while preserving unrelated operator state. A manifest-driven model is preferred as the surface grows.

## 5. Firewall architecture

### Current stabilization boundary

For v1.1.0, preserve the current policy semantics while correcting validation, performance, partial-failure handling, and management UX.

Requirements:

- validate every block/allow entry before runtime apply;
- prefer one validated nftables batch/transaction over one `nft` process per entry;
- for the legacy iptables/ipset backend, prefer bulk restore/swap patterns when supported;
- never report a complete apply when entries were rejected;
- add/remove operations should update persisted state and active runtime state in one operator action where safely possible;
- serialize concurrent list mutations with a simple lock;
- runtime verification should confirm the expected table/set/chain and relevant entry counts/content;
- keep SSO resources explicitly namespaced.

### VPN-aware firewall boundary after v1.1.0

Do not assume only host `INPUT`/`OUTPUT` traffic matters. Routed VPN gateways require explicit `FORWARD` consideration; locally-originating proxies can require `OUTPUT` controls. Future firewall scopes must therefore be explicit and workload-aware.

IPv4 and IPv6 must be modeled separately where address-family semantics require it, while using common `inet` nftables structures where appropriate.

### Safe management

Before high-impact rule replacement, SSO should have enough information to avoid accidental management lockout or clearly warn/cancel when it cannot establish safety. A future safe-apply watchdog/rollback mechanism may be used where it can be made reliable.

## 6. Fail2Ban boundary

SSO should manage its own drop-in under `jail.d`, not replace `jail.local`.

Before restarting/reloading Fail2Ban after an SSO change:

1. render/write only the SSO-owned configuration;
2. validate configuration using the installed Fail2Ban tooling;
3. abort without restarting on validation failure;
4. restart/reload only after validation succeeds;
5. verify service/jail state relevant to the requested operation.

## 7. Network tuning model

SSO is primarily for VPN/proxy nodes, so tuning must be workload-aware.

### TCP-oriented concerns

Examples include congestion control, qdisc, listen/backlog capacity, local ephemeral ports, and connection lifecycle. These settings should not be presented as universally beneficial to all VPN traffic.

### UDP/routed VPN concerns

Examples include:

- MTU/PMTU and MSS interaction;
- socket receive/send buffers;
- IPv4/IPv6 forwarding;
- conntrack capacity/pressure where applicable;
- queueing and packet drops;
- NIC queue topology and virtualization;
- forwarded traffic rather than only local sockets.

### RPS/RFS/XPS/IRQ

Do not apply a fixed all-CPU mask merely because CPUs exist. The correct policy can depend on RSS, RX/TX queue count, CPU topology, IRQ distribution, NIC driver, and virtualization. If tuning cannot be justified from detected state, prefer no change plus a diagnostic recommendation.

Any value applied interactively and persisted for reboot must come from the same source of truth so reboot cannot silently change the intended setting.

## 8. VPN Doctor direction

A later read-only `VPN Doctor` should diagnose before tuning. Useful evidence may include:

- OS/kernel/virtualization;
- CPU and NIC queue topology;
- detected WAN/VPN interfaces;
- forwarding state;
- MTU/PMTU indicators;
- conntrack usage;
- TCP congestion control/qdisc;
- UDP/TCP buffer limits;
- packet/softnet drop signals;
- firewall backend and INPUT/OUTPUT/FORWARD coverage;
- block/allow list health.

Read-only diagnostics should be separable from mutation so operators can inspect a server without applying changes.

## 9. Installer and update trust boundary

SSO is executed as root. Online install/update therefore has a high-impact supply-chain surface.

Release installation should be based on an immutable release/tag/artifact and verified integrity metadata. Downloading mutable `main` content with only “file is non-empty / has a shebang” validation is not an acceptable long-term release trust model.

Installation/update should stage content before replacing the live installation and should preserve a known-good previous installation until the new payload passes integrity and structural validation.

Local/offline installation must use the actual directory containing the installer payload rather than assuming the payload already exists at the final install path.

## 10. Concurrency and filesystem behavior

- Use atomic replace (`write temp -> validate -> rename`) for state/config files when practical.
- Use `flock` for list/state mutations where concurrent SSO sessions could otherwise lose updates.
- Create unique backup IDs; second-level timestamps alone are insufficient.
- Separate UI output from function return data. Helpers used through command substitution should emit only their machine-readable return value on stdout; diagnostics/UI belong on stderr or outside the helper.

## 11. Compatibility

Supported OS versions and documented dependencies are user-facing contract and belong in `README.md`. Before changing version support, verify the actual commands/packages/kernel capabilities on those releases.

Backends may differ across supported systems. Backend fallback must not silently weaken correctness or verification.

## 12. Testing boundary

Development validation must not mutate the shared AI Server Agent host's real firewall, sysctl, systemd, Fail2Ban, package database, or networking.

Use, in increasing integration depth as warranted:

1. pure Bash/unit-style tests for parsers and helpers;
2. temporary-root/mocked command tests for filesystem/config behavior;
3. isolated namespace/container tests when kernel/network behavior is needed;
4. a dedicated disposable VM/server for full root/systemd/firewall integration;
5. owner validation on the intended real VPN/proxy server at the explicit release test boundary.

See `docs/DEVELOPMENT.md` for the executable workflow.