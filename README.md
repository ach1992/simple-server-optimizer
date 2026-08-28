# Simple Server Optimizer (SSO)

Simple Server Optimizer is a **small, menu-driven Bash utility for Debian and Ubuntu servers**, especially VPN/proxy nodes.

SSO is intentionally simple. It is not a control panel, package manager, VPN platform, or large automation framework. Its job is to make a small set of common server operations easier to run, understand, repeat, and roll back.

## What SSO provides

From one `sso` menu you can access:

- system/network status checks;
- fq + BBR and basic TCP tuning helpers;
- CPU / IRQ / RPS / RFS / XPS helpers;
- IPv4 firewall blocklist and whitelist management;
- Fail2Ban setup/integration;
- SSO backups and rollback;
- explicit online update/reinstall;
- uninstall and cleanup of SSO-owned state.

SSO performs low-level system operations as root. On important servers, keep provider console/out-of-band access or a server snapshot available when testing a new release.

---

## Supported operating systems

Current documented targets:

- Debian 10 / 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04

Other distributions are not currently targeted.

The examples below assume you are already logged in as `root`. If you use a normal sudo-enabled account, prefix the commands with `sudo` where appropriate.

---

# Installation

There are two supported installation paths:

1. **Online install** — the server downloads SSO directly from GitHub.
2. **Offline/local install** — you download the complete SSO source on another computer, upload it to the server, and install entirely from those local files.

If your server cannot reach `raw.githubusercontent.com` reliably, use the offline/local method.

## Method 1 — Online install

For the current development baseline on `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/ach1992/simple-server-optimizer/main/install.sh -o /tmp/sso-install.sh
bash /tmp/sso-install.sh --online
```

The installer downloads the required SSO payload, validates it, and installs it under:

```text
/root/simple-server-optimizer/
```

It also creates the command:

```text
/usr/local/bin/sso
```

After installation, SSO opens automatically. Later you can start it with:

```bash
sso
```

> Stable release `v1.1.1` packages the post-v1.1.0 usability improvements while preserving the v1.1.0 safety baseline. For an exact immutable `v1.1.1` installation/update, use the Source ZIP or tarball from the [`v1.1.1` GitHub Release](https://github.com/ach1992/simple-server-optimizer/releases/tag/v1.1.1), extract the complete source tree, and run `bash install.sh --local`. The `--online` channel follows the current `main` branch.

---

# Offline / local installation — exact steps

This is the recommended method when the target server has limited or blocked access to GitHub.

## Important: do not download only `install.sh`

A local installation needs the **complete SSO payload**, not only the installer file.

At minimum the installer expects the application files under the same source directory, including:

```text
install.sh
sso.sh
modules/
assets/
```

The safest and simplest approach is therefore to download the **entire repository Source ZIP** and upload the complete extracted folder.

## Step 1 — Download SSO on your computer

On a computer that has normal internet access:

1. Open the SSO GitHub repository:
   `ach1992/simple-server-optimizer`
2. Click **Code**.
3. Click **Download ZIP**.
4. Extract the ZIP on your computer.

For a published release, use the Source ZIP for that specific release/tag instead of `main`.

After extraction, you will have a folder similar to:

```text
simple-server-optimizer-main/
```

or, for a tagged release, a similarly named versioned source folder.

## Step 2 — Rename the extracted folder

For clarity, rename the extracted folder on your computer to:

```text
sso-offline
```

You should now have a local folder whose structure looks approximately like this:

```text
sso-offline/
├── install.sh
├── sso.sh
├── modules/
│   ├── utils.sh
│   ├── network.sh
│   ├── cpu_irq.sh
│   ├── firewall.sh
│   ├── fail2ban.sh
│   ├── rollback.sh
│   └── uninstall.sh
├── assets/
│   ├── whitelist-default.ipv4
│   └── blocklist-ip.ipv4
├── README.md
└── ...
```

Do **not** move `install.sh` out of this folder. The installer intentionally discovers the other local files relative to the directory containing `install.sh`.

## Step 3 — Upload the entire folder to the server

Using SFTP/SCP/FileZilla/WinSCP or your preferred file-transfer tool, upload the **whole `sso-offline` folder** to `/root`.

The result on the server must be:

```text
/root/sso-offline/
```

and these files must exist, for example:

```text
/root/sso-offline/install.sh
/root/sso-offline/sso.sh
/root/sso-offline/modules/firewall.sh
/root/sso-offline/assets/whitelist-default.ipv4
```

### Recommended layout

Use this temporary upload directory:

```text
/root/sso-offline/
```

Do **not** manually use `/root/simple-server-optimizer/` as the upload/staging directory unless you specifically intend to adopt that directory in place. `/root/simple-server-optimizer/` is SSO's normal **final installed application directory**, so keeping the uploaded source in `/root/sso-offline/` makes the process much clearer and safer.

## Step 4 — Run the local installer

SSH to the server as root and run:

```bash
cd /root/sso-offline
bash install.sh --local
```

That is the complete offline installation command.

The `--local` option explicitly tells the installer:

> use the files in the directory containing this `install.sh`; do not download the SSO application from GitHub.

The installer validates the local payload and Bash syntax before replacing the installed application.

## Step 5 — What the installer creates

After a successful local install, the actual installed application is located at:

```text
/root/simple-server-optimizer/
```

The launcher is:

```text
/usr/local/bin/sso
```

Persistent SSO state is stored under:

```text
/etc/sso/
```

Now start SSO with:

```bash
sso
```

or explicitly:

```bash
bash /root/simple-server-optimizer/sso.sh
```

## Step 6 — Remove the temporary upload folder

After you have confirmed that `sso` starts correctly, the temporary uploaded source folder is no longer required:

```bash
rm -rf /root/sso-offline
```

This does **not** remove the installed SSO application. The installed copy remains under:

```text
/root/simple-server-optimizer/
```

## Does offline installation need internet access?

The SSO **local installation itself does not download the SSO application** when you use:

```bash
bash install.sh --local
```

However, some features inside SSO may later install normal operating-system packages such as Fail2Ban, irqbalance, or `ipset`. Those package-install actions still require working Debian/Ubuntu package repositories unless the required packages are already installed or you provide your own offline package source.

---

# Offline update / reinstall

You can use exactly the same local method to update an existing SSO installation without relying on GitHub access from the server.

1. Download the newer complete Source ZIP on another computer.
2. Extract it.
3. Rename the extracted folder to `sso-offline`.
4. Upload it as `/root/sso-offline/`.
5. Run:

```bash
cd /root/sso-offline
bash install.sh --local
```

When replacing a recognized existing SSO installation, the installer keeps the previous application as a simple fallback at:

```text
/root/simple-server-optimizer.bak/
```

Existing SSO backup history is carried into the replacement installation.

After confirming the update works:

```bash
sso
```

then you may remove the temporary upload folder:

```bash
rm -rf /root/sso-offline
```

---

# Normal use

Start the application with:

```bash
sso
```

Normal `sso` startup uses the files already installed under `/root/simple-server-optimizer/`.

**Launching SSO does not automatically download or reinstall the project.**

The main menu currently provides:

```text
1) System Check
2) Network Optimizations
3) CPU & IRQ Optimizations
4) Firewall + Abuse Defender
5) Fail2Ban
6) Backups & Rollback
7) Update
8) Uninstall
0) Exit
```

---

# Updating from inside SSO

Menu option **7) Update** performs an explicit **online** update/reinstall.

Internally, SSO runs the installed installer using the online mode. Therefore this method requires the server to be able to reach the configured GitHub source.

If GitHub/raw GitHub access is blocked on the server, do not use the online Update menu. Use the **Offline update / reinstall** procedure above instead.

An update is separate from normal application startup: simply running `sso` does not trigger an update.

---

# Installed and persistent paths

The main SSO-owned paths are:

| Path | Purpose |
| --- | --- |
| `/root/simple-server-optimizer/` | installed SSO application |
| `/root/simple-server-optimizer.bak/` | previous recognized application after an update/reinstall, when applicable |
| `/root/simple-server-optimizer/backups/` | SSO backup history |
| `/etc/sso/` | persistent SSO state |
| `/usr/local/bin/sso` | command launcher |
| `/etc/sysctl.d/99-sso-*.conf` | SSO-owned persistent sysctl configuration |
| `/usr/local/sbin/sso-*-restore` | SSO restore helpers, when created by a feature |
| `/etc/systemd/system/sso-*.service` | SSO persistence units, when created by a feature |

SSO is designed to preserve unrelated operator-owned configuration instead of claiming whole system configuration files unnecessarily.

---

# Firewall behavior

SSO currently provides an IPv4-oriented host firewall manager.

To apply SSO firewall rules, the server needs **one usable firewall backend**:

- usable `nftables`; **or**
- both `iptables` **and** `ipset`.

`iptables` by itself is not enough for the SSO blocklist/whitelist backend. Some minimal Debian/Ubuntu server images include `iptables` but do not include `ipset` by default. SSO's **System Check** reports whether a usable SSO backend is ready and, when `iptables` is present but `ipset` is missing, shows the exact package command to install it:

```bash
apt-get update
apt-get install -y ipset
```

On a server without internet/package-repository access, provide `ipset` through your normal offline Debian/Ubuntu package source before applying SSO firewall rules.

Importing the bundled blocklist only updates SSO's saved list. It does **not** install firewall packages and does **not** activate SSO firewall rules. Use **Apply/refresh SSO firewall rules** explicitly after a usable backend is available.

The published `v1.1.1` patch release preserves the v1.1.0 firewall safety baseline and adds the post-v1.1.0 usability improvements:

- validating IPv4/CIDR list entries before apply;
- accepting one or many blacklist/whitelist IPv4/CIDR entries separated by commas and/or whitespace;
- deduplicating input and validating the whole batch before mutation;
- rejecting an invalid batch without partial persisted/runtime mutation;
- protecting the required default whitelist entry `10.235.0.0/19` during bulk removal;
- not reporting full success after required backend failures;
- keeping whitelist priority over blocklist rules;
- preserving the existing INPUT/OUTPUT policy scope;
- making blacklist/whitelist add/remove update an already-active SSO nftables/ipset backend immediately;
- keeping those list changes persisted;
- showing compact requested/changed/unchanged/backend result summaries;
- applying the common BitTorrent-port toggle immediately when SSO firewall is already active, with saved-state rollback if live apply fails;
- never auto-enabling an inactive SSO firewall because of a direct list edit or BitTorrent toggle.

The explicit **Apply/refresh SSO firewall rules** action remains for initial activation, explicit refresh/recovery, and intentionally staged state.

SSO does not currently try to become a complete firewall platform. New routed `FORWARD` semantics and new IPv6 firewall feature surface remain outside the v1.1.1 scope.

Common BitTorrent-port blocking is **best-effort port blocking**, not complete BitTorrent protocol detection.

If another firewall manager is installed on the server, review how its rules interact with SSO before enabling SSO firewall rules.

---

# Fail2Ban behavior

SSO manages its own Fail2Ban configuration/drop-in and should preserve unrelated operator configuration such as an existing `/etc/fail2ban/jail.local`.

SSO validates its generated configuration before service mutation where the Fail2Ban validation tooling is available.

The goal is to add or remove SSO-owned behavior without taking ownership of unrelated administrator configuration.

---

# CPU / IRQ / network tuning

SSO includes helpers for:

- fq + BBR;
- basic TCP tuning;
- irqbalance;
- RPS;
- RFS;
- XPS.

These are practical helpers, not a claim that one fixed set of values is universally optimal for every server or every VPN/proxy workload.

The v1.1.0 stabilization baseline continues to define correctness and persistence expectations for these existing tuning features; v1.1.1 does not broaden them into adaptive tuning or protocol-specific profiles.

---

# Backup and rollback

SSO can create and restore SSO-aware backups for the system state it manages.

Backups are stored under:

```text
/root/simple-server-optimizer/backups/
```

The rollback menu lets you list available backups, restore the latest usable backup, or choose a specific usable backup.

Rollback is intentionally scoped to state SSO knows how to manage; it is not a replacement for a full VPS/provider snapshot.

---

# Uninstall

Use menu option:

```text
8) Uninstall (rollback + remove SSO)
```

The uninstall flow is designed to remove SSO-owned state while preserving unrelated operator-owned configuration where ownership can be determined safely.

For important servers, a provider snapshot or console remains the best final safety net before large system changes.

---

# Current published release: v1.1.1

`v1.1.1` is a focused patch release that packages the post-v1.1.0 operator usability work from Issue #37 without expanding the underlying firewall policy surface.

The v1.1.1 delta includes:

- clearer inline input guidance and examples;
- more consistent semantic color/status treatment across the CLI;
- bulk blacklist/whitelist add/remove with comma/whitespace input, deduplication, and full-batch validation;
- atomic rejection of invalid/protected whitelist removal batches;
- immediate active-backend list application with compact result summaries and fail-closed rollback behavior;
- immediate active-firewall BitTorrent common-port toggle application with rollback on live-apply failure;
- preserving explicit Apply/refresh for activation/recovery/staged state;
- no silent activation of an inactive firewall;
- no new IPv6/FORWARD/DPI semantics.

The v1.1.0 release remains the stabilization baseline that delivered:

- preserving operator-owned Fail2Ban configuration;
- journald-only SSH Fail2Ban support on supported hosts;
- rollback/uninstall correctness fixes;
- exact RPS/RFS/XPS runtime restoration during rollback/uninstall;
- safe removal of installer-created previous-install fallback state;
- reliable local/offline installation;
- normal `sso` launch using installed files without re-downloading;
- explicit/simple update and reinstall behavior;
- CPU/RPS persistence and correctness fixes;
- firewall input validation and honest apply failures;
- immediate active-backend blacklist/whitelist add/remove;
- focused CI/regression coverage;
- completed real-server owner validation and published GitHub Release.

Large transactional installer frameworks, custom supply-chain systems, VPN Doctor, adaptive tuning, protocol profiles, new IPv6/FORWARD firewall features, and similar expansion are **not part of v1.1.1**.

Future work will be selected from reproduced defects, compatibility needs, real usage, and operator feedback rather than an automatic expansion roadmap.

---

# Development and validation

Routine repository validation uses:

```bash
bash -n install.sh sso.sh modules/*.sh
shellcheck --severity=error install.sh sso.sh modules/*.sh
bash tests/run.sh
```

Repository tests should not mutate a shared development host's real firewall, sysctl, systemd, Fail2Ban, package, or network state.

GitHub Copilot review is not used for this repository. Review depth is proportional to the actual change.

---

# Project documentation

- [`PROJECT-SPEC.md`](PROJECT-SPEC.md) — durable project direction and non-goals;
- [`AGENTS.md`](AGENTS.md) — contributor/agent operating rules;
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — ownership and state boundaries;
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — development, validation, and release workflow;
- GitHub Issues — current work and acceptance criteria;
- Pull Requests / Git / CI — implementation and validation truth.

Repository:

`https://github.com/ach1992/simple-server-optimizer`

---

## License

MIT. See [`LICENSE`](LICENSE).
