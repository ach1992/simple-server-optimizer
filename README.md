# Simple Server Optimizer (SSO)

Simple Server Optimizer is a **small, menu-driven Bash utility** for Debian/Ubuntu servers, especially VPN/proxy nodes.

Its purpose is simple: make common tuning, firewall, Fail2Ban, backup/rollback, update, and uninstall tasks easier to run and easier to understand without requiring a heavyweight management stack.

The project deliberately prefers practical fixes over large architecture.

## What SSO currently does

- network/kernel tuning helpers;
- CPU / IRQ / RPS / RFS / XPS helpers;
- firewall blocklist/whitelist management;
- Fail2Ban setup/integration;
- backup and rollback;
- update and uninstall;
- `sso` launcher/menu.

SSO runs low-level operations as root, so important servers should still have a snapshot or out-of-band console available when testing a new release.

## Current focus: v1.1.0

v1.1.0 is a **focused stabilization release**. The goal is to fix problems in the current script, not turn SSO into a larger platform.

Current release work is limited to:

- preserving operator-owned Fail2Ban configuration;
- retaining the rollback/uninstall correctness fixes already integrated;
- fixing local/offline install behavior;
- making normal `sso` execution use installed files without re-downloading the project;
- making update/reinstall explicit and simple;
- fixing reproduced CPU/RPS persistence problems;
- validating firewall input and preventing false-success;
- making firewall add/remove quick and immediate where the active backend supports it;
- keeping CI/regressions small and useful;
- publishing v1.1.0 for real-server owner testing.

Large transactional installer frameworks, custom supply-chain systems, VPN Doctor, adaptive tuning, protocol profiles, new IPv6/FORWARD firewall features, and similar expansion are **not part of v1.1.0**.

Future work will be chosen after real use shows what is actually valuable.

## Supported OS

Current documented targets:

- Debian 10 / 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04

Other distributions are not targeted by design.

## Quick Start

### Online install

For the current development baseline:

```bash
curl -fsSL https://raw.githubusercontent.com/ach1992/simple-server-optimizer/main/install.sh -o /tmp/sso-install.sh
sudo bash /tmp/sso-install.sh
```

For published versions, prefer the versioned/tagged install path documented in the GitHub Release.

### Local/offline install

Clone or download the repository, then run:

```bash
sudo bash install.sh
```

v1.1.0 specifically fixes local payload discovery so the installer uses the directory that actually contains `install.sh`.

### Run SSO

After installation:

```bash
sudo sso
```

Normal `sso` usage is expected to **run the installed application only**. It should not download or update SSO just because you launched the menu.

### Update / reinstall

Update is an explicit operator action. v1.1.0 will keep this flow simple: validate the required payload, preserve a straightforward previous-install fallback, replace the installed files, and report failures honestly.

The exact published update command/path will be documented with the v1.1.0 release.

## Main paths

Common SSO-owned paths include:

- `/root/simple-server-optimizer/` — installed application;
- `/etc/sso/` — persistent SSO state;
- `/usr/local/bin/sso` — launcher;
- `/etc/sysctl.d/99-sso-*.conf` — SSO-owned sysctl files;
- `/usr/local/sbin/sso-*-restore` — restore helpers;
- `/etc/systemd/system/sso-*.service` — persistence units;
- `/root/simple-server-optimizer/backups` — current backup location.

SSO should preserve unrelated operator configuration.

## Firewall notes

- SSO currently supports its existing IPv4-oriented host firewall behavior.
- v1.1.0 focuses on validation, accurate failure reporting, and easier add/remove operations.
- New routed `FORWARD` semantics, IPv6 firewall features, counters/search, and broader redesign are deferred.
- Common BitTorrent-port blocking is best-effort port blocking, not complete protocol detection.

If another firewall manager is installed, review interactions before enabling SSO rules.

## Fail2Ban notes

SSO should use its own configuration/drop-in and must not overwrite unrelated operator `jail.local` configuration.

Configuration should be validated before SSO restarts/reloads Fail2Ban when validation tooling is available.

## Tuning notes

SSO should not present fixed tuning values as universally optimal. v1.1.0 fixes current correctness/persistence defects; adaptive or protocol-specific tuning is deferred until real usage demonstrates a need.

## Project direction

SSO intentionally stays **small, Bash-first, and practical**.

The priority is:

1. easy operation;
2. fix reproduced bugs;
3. preserve unrelated system configuration;
4. keep behavior understandable;
5. add complexity only when a real operator problem justifies it.

The live roadmap and release acceptance criteria are maintained in GitHub Issues.

## Development and validation

Routine development uses:

```bash
bash -n install.sh sso.sh modules/*.sh
shellcheck --severity=error install.sh sso.sh modules/*.sh
bash tests/run.sh
```

Tests should not mutate the shared development host's real firewall, sysctl, systemd, Fail2Ban, or package state.

GitHub Copilot review is not used for this repository. Review is proportional to the actual change; bounded fixes normally use focused regressions, CI, and developer/Master self-review.

## Project documentation

- [`PROJECT-SPEC.md`](PROJECT-SPEC.md) — durable project direction;
- [`AGENTS.md`](AGENTS.md) — contributor/agent operating rules;
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — ownership/state boundaries;
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — development/test/release workflow;
- GitHub Issues — current work and acceptance;
- Pull Requests / Git / CI — implementation and validation truth.

## License

MIT. See [`LICENSE`](LICENSE).