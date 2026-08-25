# Simple Server Optimizer — Project Specification

This file is the **bootstrap source-of-intent** for **Simple Server Optimizer (SSO)**. Its job is to establish the durable project direction from which repository documentation, architecture rules, GitHub Issues, release work, and operating instructions are derived.

It is **not** the normal recovery source for future Master sessions. After bootstrap is complete, routine recovery and execution must use the derived authoritative sources closest to the work: `README.md`, `AGENTS.md`, specialized docs, GitHub Issues/PRs, Git refs, CI, and release state. Re-read this file only when project-level intent, durable constraints, supported environments, non-goals, or completion criteria become materially unclear or are explicitly changed.

## Mission

Build a small, dependable Bash toolkit that measurably improves the safety, reliability, diagnosability, and network performance of **Debian/Ubuntu servers used primarily as VPN/proxy nodes**, while remaining understandable, reversible, and practical for real operators.

The intended product direction is:

> **A safe, adaptive VPN/proxy server optimizer and abuse-protection toolkit.**

SSO should optimize only where evidence and the actual workload justify it. It must not become a collection of cargo-cult sysctl values or broad destructive hardening rules.

## Primary environments and users

Primary workloads include, without being limited to:

- WireGuard and other routed/TUN VPN gateways;
- OpenVPN in UDP or TCP modes;
- Xray-based proxy nodes such as VLESS/Reality deployments;
- UDP/QUIC-oriented proxy transports such as Hysteria/TUIC;
- mixed VPN/proxy nodes where forwarded traffic and locally-originated proxy traffic coexist.

Primary supported operating systems remain Debian and Ubuntu. Exact supported versions are documented in `README.md` and must be verified before release changes.

## Product principles

1. **Safety before tuning** — never trade correctness, connectivity, or recoverability for a theoretical benchmark gain.
2. **Detect before changing** — inspect kernel, virtualization, interfaces, queues, existing configuration, and workload-relevant state before recommending or applying tuning.
3. **Protocol-aware behavior** — TCP-only tuning must not be presented as a universal VPN optimization; UDP, forwarding, MTU/PMTU, conntrack, queueing, and routed traffic matter for VPN workloads.
4. **Idempotent operations** — repeated application must converge to one intended state without duplicated rules or configuration drift.
5. **Explicit ownership** — SSO must prefer its own drop-ins, state files, tables, chains, sets, and services instead of overwriting unrelated operator configuration.
6. **Reversible changes** — every persistent SSO-owned change must have a credible rollback/uninstall path; backup existence alone is not proof of recoverability.
7. **Fail closed on partial mutation** — validation should happen before dangerous apply steps, and partial failures must not be reported as success.
8. **Atomic where practical** — firewall/list replacement and installation/update flows should avoid exposing half-applied state.
9. **No lockout by surprise** — firewall changes must account for current management connectivity and clearly distinguish host traffic from forwarded VPN traffic.
10. **IPv4 and IPv6 are first-class** — do not solve IPv6 concerns by blindly disabling IPv6.
11. **Performance must be evidence-driven** — adaptive queue/IRQ/RPS/XPS/TCP/UDP tuning is preferred over fixed values when hardware, virtualization, queue topology, or kernel behavior can materially change the correct answer.
12. **Supply-chain integrity matters** — root-executed online updates must be tied to an immutable release identity and integrity verification, not mutable branch contents alone.
13. **Simple operator experience** — common operations such as blocking/unblocking an IP must be immediate, understandable, and verifiable without unnecessary menu round-trips.
14. **No hidden policy** — managed defaults must be visible and explainable; SSO must not silently re-add operator-deleted policy unless it is an explicitly documented system invariant.

## Existing product surface

The current toolkit is a menu-driven Bash application with modules for:

- system/network inspection;
- BBR/qdisc and TCP-related tuning;
- CPU/IRQ/RPS/RFS/XPS tuning;
- firewall blocklist/whitelist management;
- Fail2Ban setup/integration;
- backups and rollback;
- update and uninstall.

Preserve this small modular Bash architecture unless evidence shows that a larger runtime/dependency would deliver enough value to justify the added operational cost.

## Accepted delivery sequence

### Phase 1 — v1.1.0 stabilization and trustworthy baseline

The immediate active outcome is a stabilization release that fixes known correctness/safety defects and improves the existing features before adding major new VPN functionality.

Required themes:

- stop SSO from overwriting unrelated Fail2Ban configuration;
- make Fail2Ban whitelist synchronization syntactically valid and validate config before restart;
- repair backup selection, backup identity collisions, rollback completeness, and uninstall leftovers;
- make CPU/RPS persistence consistent across immediate apply and reboot;
- correct CPU-mask handling where needed and remove unsafe universal tuning assumptions from user-facing language/behavior;
- repair true offline/local installation behavior;
- improve installer/update provenance and integrity handling appropriate to a root-executed tool;
- separate machine-readable helper output from UI output where current contracts are broken;
- make firewall list validation reject invalid entries before apply;
- improve the **existing** firewall manager so add/remove is faster, easier, and applied immediately where safely possible;
- replace per-entry firewall process spawning with validated bulk/transactional apply paths where supported, while preserving current policy semantics for this stabilization release;
- add enough automated validation/CI to prevent the reproduced regressions from returning;
- publish `v1.1.0` for operator testing.

**Human validation boundary:** after `v1.1.0` is published, the owner will test it on a real VPN/proxy server. Do not begin the larger Phase 2+ product expansion until that feedback is reconciled, except for a necessary stabilization hotfix.

### Phase 2 — VPN-aware firewall and traffic protection

After the v1.1.0 test gate, evolve firewall behavior for actual VPN/proxy traffic:

- explicit INPUT / OUTPUT / FORWARD scopes;
- routed VPN traffic protection via FORWARD where appropriate;
- IPv6 block/allow sets;
- counters and useful firewall statistics;
- management-session safety checks / safe apply behavior;
- search and explainability such as “why is this IP blocked?”;
- clearer abuse-protection options and accurate naming for best-effort controls such as common BitTorrent-port blocking.

### Phase 3 — VPN Doctor and protocol-aware profiles

Add a read-only diagnostic capability first, then recommendations/profiles for workloads such as WireGuard, OpenVPN, Xray/VLESS/Reality, Hysteria/TUIC/QUIC, and mixed nodes. Important signals include forwarding, MTU/PMTU, UDP/TCP buffers, conntrack pressure, queue topology, packet/softnet drops, congestion control, and firewall coverage.

### Phase 4 — adaptive performance tuning

Make queue, IRQ, RPS/RFS/XPS, TCP, UDP, socket, and capacity tuning conditional on detected system/workload characteristics. Prefer before/after evidence and conservative defaults over fixed “maximum performance” values.

### Phase 5 — abuse and operations improvements

Potential work includes managed blocklist sources with provenance, safe refresh/diff/rollback, abuse profiles, diagnostics export, scheduled maintenance, and other low-cost operational improvements that demonstrate clear value.

## v1.1.0 completion criteria

The stabilization release is ready only when:

- reproduced P0/P1 defects targeted by the active stabilization Issues have regression coverage or equivalent high-signal validation;
- all Bash files pass syntax checks and the repository CI policy;
- firewall list apply cannot silently succeed after rejected entries in the supported path being tested;
- Fail2Ban changes are isolated to SSO-owned configuration and are validated before service restart;
- rollback/uninstall behavior accounts for every SSO-owned persistent artifact touched by the release;
- install/update behavior has a documented, verified immutable release/integrity path;
- release notes clearly identify remaining limitations and the real-server test boundary;
- the reviewed release commit is tagged and published as `v1.1.0`.

## Non-goals

Unless a later accepted Issue explicitly changes scope, SSO should not:

- install or manage complete VPN products/panels as its primary job;
- overwrite arbitrary operator-owned firewall, Fail2Ban, sysctl, or service configuration;
- claim that blocking a few common ports fully blocks BitTorrent/P2P;
- disable IPv6 globally as a generic hardening shortcut;
- apply aggressive kernel/network settings solely because they are popular in tuning guides;
- require a heavyweight application stack for functionality that Bash/system tools can implement clearly and safely;
- mutate a production/user server merely to validate development changes when an isolated test environment can prove the behavior.

## Architecture and state boundaries

- Repository source: installation scripts, modules, defaults, docs, tests.
- SSO persistent runtime state: `/etc/sso`.
- SSO-owned sysctl drop-ins: `/etc/sysctl.d/99-sso-*.conf`.
- SSO-owned services/restore helpers: explicitly named `sso-*` units/scripts.
- Backups: must represent prior state accurately enough to restore the artifacts SSO owns.
- Firewall: SSO must manage explicitly namespaced tables/chains/sets and avoid assuming ownership of unrelated rules.
- Fail2Ban: SSO should use an SSO-owned drop-in under `jail.d` rather than owning `/etc/fail2ban/jail.local`.

These requirements are materialized into implementation-oriented documentation during bootstrap. After that, developers should use the specialized document that owns the relevant rule rather than repeatedly consulting this project specification.

## Engineering and release rules

- Use isolated branches/workspaces for substantive work; do not develop directly on `main`.
- For this project, PR-based integration is the normal path for substantive changes.
- Use the dedicated AI Server Agent only in a uniquely isolated workspace for development/testing; never reuse or mutate another active Master's workspace.
- Do not run firewall/sysctl/systemd mutations on a shared development host just to test code. Use mocks, namespaces, containers, or dedicated disposable systems proportional to the behavior under test.
- Validate configuration before reload/restart when the underlying tool supports it.
- Preserve operator configuration by default; SSO-owned drop-ins and namespaced resources are preferred.
- Keep dependencies minimal and justified.
- Version with SemVer. Release source must correspond to an immutable reviewed commit/tag.
- Production/user-server testing is a human operation unless explicitly delegated for a specific disposable target.

## Bootstrap output model

This specification should be used to establish and, when project-level intent changes, reconcile the repository's normal authoritative sources. Bootstrap is complete when the project direction above is represented in the appropriate stable docs and the executable work is represented in GitHub Issues/PRs.

After bootstrap:

- `README.md` owns the user-facing product contract and supported usage;
- `AGENTS.md` owns stable contributor/agent operating rules;
- specialized `docs/*` files own architecture, development, testing, and release guidance;
- GitHub Issues own unresolved work, priority, dependency, acceptance, and the active release plan;
- Git/PRs own implementation identity and review history;
- CI owns validation state;
- tags/releases own published delivery identity.

Do **not** put this file in the routine recovery checklist. A new Master should recover through those normal sources and only return here if project-level intent cannot otherwise be resolved or has been explicitly changed.

## Project success

SSO succeeds when an operator can safely install it on a supported VPN/proxy node, understand what it wants to change and why, apply only relevant optimizations, manage firewall policy quickly, diagnose important network bottlenecks, recover from changes, and upgrade/uninstall without losing unrelated system configuration.