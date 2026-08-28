# Simple Server Optimizer — Project Specification

This file defines the durable project direction for **Simple Server Optimizer (SSO)**. It is intentionally short: implementation details, live status, and task acceptance belong in the README, docs, GitHub Issues/PRs, Git, and CI.

## Mission

Build and maintain a **small, practical, menu-driven Bash utility** that makes common Debian/Ubuntu server tuning and basic protection tasks easier for operators, especially on VPN/proxy nodes.

The product should be simple to install, simple to run, easy to understand, and predictable when something fails.

SSO is not trying to become a complete VPN platform, a general security framework, a package manager, or a research project in perfect transactional shell behavior.

## Primary users and environments

Primary users are operators of Debian/Ubuntu servers who want one lightweight script for common tasks such as:

- basic network/kernel tuning;
- CPU/IRQ/RPS helpers;
- firewall blocklist/whitelist management;
- Fail2Ban setup/integration;
- backup, rollback, update, and uninstall.

VPN/proxy workloads are the main use case. Protocol-specific automation is not a standing product requirement.

## Product principles

1. **Ease of use first** — normal operation should be obvious and require as few steps as practical.
2. **Fix real bugs before inventing architecture** — reproduced defects and operator friction outrank hypothetical edge cases.
3. **Keep it small** — Bash and normal system tools are preferred; new abstractions and dependencies must earn their complexity.
4. **Preserve operator configuration** — do not overwrite unrelated firewall, Fail2Ban, sysctl, service, or user files.
5. **Report the truth** — rejected input, failed apply, partial support, or failed update must not be shown as complete success.
6. **Be reversible enough for the actual feature** — use clear SSO-owned files and straightforward backup/rollback; do not build transaction frameworks unless a demonstrated requirement needs them.
7. **Avoid cargo-cult tuning** — do not claim one tuning profile is universally optimal.
8. **Use proportional safety and review** — root/system changes deserve care, but controls must match the actual change instead of automatically escalating every task into HIGH_ASSURANCE process.
9. **Real-server feedback matters** — owner testing decides what future complexity is worth adding.

## Existing product surface

The current toolkit is a modular Bash application with:

- `sso.sh` menu entrypoint;
- network and CPU tuning helpers;
- firewall blocklist/whitelist management;
- Fail2Ban integration;
- backup/rollback/uninstall;
- installer/update support.

Preserve this small architecture unless a concrete operator problem proves that a larger design is necessary.

## Delivered baseline — v1.1.0

`v1.1.0` is the published focused stabilization baseline for the existing script.

The delivered baseline includes:

- regression/CI coverage for release-critical behavior;
- preservation of operator-owned Fail2Ban configuration and validation of SSO-owned configuration;
- hardened rollback/uninstall ownership and recovery behavior;
- complete local/offline installation and explicit update/reinstall;
- normal `sso` startup using installed files without an update/download side effect;
- corrected CPU/RPS/RFS/XPS apply, persistence, rollback, and uninstall restoration behavior;
- validated firewall list input, honest backend failure reporting, and immediate common add/remove behavior;
- safe cleanup of installer-created previous-install fallback state;
- successful real Ubuntu owner validation;
- normal Git tag/GitHub Release publication.

### v1.1.0 non-goals retained after delivery

Do **not** add these merely because they were outside the delivered release:

- a custom transactional installer/update subsystem;
- inode-identity/race protocols for every temporary file/path;
- runtime GitHub tag/ref object-resolution chains;
- a bespoke cryptographic/supply-chain framework;
- mandatory immutable-release platform machinery;
- adaptive tuning engines;
- VPN Doctor or protocol-specific profiles;
- new FORWARD/IPv6 firewall feature surfaces;
- broad concurrency, locking, or backend redesign without a reproduced problem;
- large CI matrices or mandatory independent-review ceremony for otherwise bounded changes.

A normal versioned GitHub release/tag and HTTPS source download path remain sufficient unless a future demonstrated requirement proves otherwise.

## Maintenance posture after v1.1.0

There is no standing implementation roadmap merely because v1.1.0 is complete.

Open new executable work only when justified by one of these:

- a reproduced defect or regression;
- concrete operator feedback;
- a supported OS/runtime compatibility change;
- a security or correctness problem;
- an explicit owner-approved bounded product outcome.

Keep fixes proportional to the demonstrated need. Do not manufacture architecture, features, process, or review ceremony to keep the project busy.

## Future work

Ideas such as VPN-aware firewall expansion, IPv6 sets, VPN Doctor, protocol profiles, adaptive tuning, managed blocklist sources, and broader abuse tooling are **deferred ideas**, not committed phases.

Keep only ideas that solve a demonstrated need and justify their complexity.

## Engineering boundaries

- Do not develop substantive changes directly on `main`.
- Use PRs for substantive changes.
- CI should stay small and high-signal: Bash syntax, ShellCheck error-level checks, and regression tests.
- Do not mutate a shared development host's real firewall/sysctl/systemd/Fail2Ban/package state for tests.
- Use temporary roots, mocks, or a dedicated disposable system where needed.
- GitHub Copilot review is not used for this repository.
- Default review is proportional Master/developer self-review plus CI. Independent review is added only when the **actual candidate** introduces exceptional destructive/security complexity that materially benefits from it.
- Real-server validation remains an owner/human operation unless a specific disposable target is explicitly authorized.

## Source-of-truth model

After this project-level direction is established:

- `README.md` owns user-facing behavior and usage;
- `AGENTS.md` owns stable contributor/agent rules;
- `docs/*` owns architecture/development guidance;
- GitHub Issues own current scope, priority, acceptance, and dependencies;
- PRs/Git own implementation identity;
- CI owns validation state;
- tags/releases own published versions.

This file should be revisited only when project-level intent materially changes.

## Project success

SSO succeeds when the owner can install it easily, run `sso`, understand the menu, apply the current features without unrelated configuration damage, see honest errors when something fails, update/reinstall deliberately, and remove or roll back SSO-owned changes without needing a heavyweight management system.
