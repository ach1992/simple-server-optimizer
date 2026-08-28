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

VPN/proxy workloads are the main use case, but v1.1.0 does not need protocol-specific automation.

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

## Current active outcome — v1.1.0

v1.1.0 is a **focused stabilization release for the existing script**.

Required work is limited to:

- keep the existing regression/CI baseline;
- preserve operator-owned Fail2Ban configuration and validate SSO-owned config;
- retain the already-integrated rollback/uninstall correctness fixes;
- fix local/offline installation and make update/reinstall explicit and simple;
- ensure normal `sso` use runs installed files instead of re-downloading the project;
- fix reproduced CPU/RPS persistence/correctness defects;
- validate firewall list input, prevent false-success, and make common add/remove actions immediate and easy;
- fix current output/UI contract defects that affect use;
- publish v1.1.0 and test it on a real server.

### Explicit v1.1.0 non-goals

Do **not** add these merely to make the release look more complete:

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

A versioned GitHub release/tag and normal HTTPS download path are sufficient for the v1.1.0 product contract. Straightforward checksums may be published when useful, but a custom trust engine is not a release requirement.

## v1.1.0 completion criteria

The release is ready when:

- the focused v1.1.0 Issues are integrated;
- reproduced defects targeted by those Issues have focused regression coverage where practical;
- Bash syntax, ShellCheck error-level checks, and the repository test suite pass on the exact release commit;
- normal `sso` launch uses the installed application without update/download side effects;
- local install works from the actual local payload directory;
- explicit update/reinstall preserves a simple usable fallback and reports failure accurately;
- Fail2Ban and rollback/uninstall preserve unrelated operator state;
- firewall invalid input and backend failure do not produce false success;
- v1.1.0 is tagged/published with concise notes and a short owner test checklist.

## Future work

Ideas such as VPN-aware firewall expansion, IPv6 sets, VPN Doctor, protocol profiles, adaptive tuning, managed blocklist sources, and broader abuse tooling are **deferred ideas**, not committed phases.

After the owner tests v1.1.0, keep only ideas that solve a demonstrated need and justify their complexity.

## Engineering boundaries

- Do not develop substantive changes directly on `main`.
- Use PRs for substantive changes.
- CI should stay small and high-signal: Bash syntax, ShellCheck error-level checks, and regression tests.
- Do not mutate a shared development host's real firewall/sysctl/systemd/Fail2Ban/package state for tests.
- Use temporary roots, mocks, or a dedicated disposable system where needed.
- GitHub Copilot review is not used for this repository.
- Default review is proportional Master/developer self-review plus CI. Independent review is added only when the **actual candidate** introduces exceptional destructive/security complexity that materially benefits from it.
- Real server validation remains an owner/human operation unless a specific disposable target is explicitly authorized.

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