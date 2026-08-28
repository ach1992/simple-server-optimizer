# Architecture and Safety Boundaries

This document defines the stable implementation boundaries for Simple Server Optimizer (SSO). Current work and priorities live in GitHub Issues; user-facing behavior lives in `README.md`.

## 1. Product shape

SSO is a small Bash-first toolkit:

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

/etc/sso/
  persistent SSO state
```

Keep this structure simple. Do not introduce a larger runtime, framework, or transaction system unless a concrete operator problem requires it.

## 2. Ownership

SSO may manage clearly SSO-owned resources such as:

- `/etc/sso/*`;
- `/etc/sysctl.d/99-sso-*.conf`;
- `/etc/systemd/system/sso-*.service`;
- `/usr/local/sbin/sso-*-restore`;
- `/usr/local/bin/sso`;
- SSO-namespaced firewall objects;
- SSO Fail2Ban drop-ins;
- SSO backups.

SSO must preserve unrelated operator resources such as:

- `/etc/fail2ban/jail.local`;
- unrelated sysctl files;
- unrelated firewall tables/chains/rules;
- unrelated systemd units;
- VPN/proxy service configuration.

Prefer explicit SSO-owned files and namespaced resources over editing shared configuration.

## 3. Mutation model

For normal features, use the simplest flow that keeps behavior honest:

```text
CHECK INPUT / CURRENT STATE
  -> PREPARE THE REQUESTED CHANGE
  -> APPLY
  -> VERIFY ENOUGH TO KNOW SUCCESS OR FAILURE
  -> RECORD SSO STATE WHEN NEEDED
```

Do not report complete success after a failed/partial apply.

Use temp-file + rename, validation-before-apply, or backup-before-replace where those are simple and materially useful. Do not generalize every filesystem operation into a custom transaction/identity framework.

## 4. Backup, rollback, and uninstall

Backups should represent the prior SSO-relevant state well enough to restore or remove SSO-owned changes correctly.

Important distinctions include prior presence vs prior absence where restore behavior depends on it.

Rollback/uninstall must not delete unrelated operator state.

The implementation should remain understandable. A larger manifest/transaction model is optional future work only if the current product surface actually outgrows the simpler model.

## 5. Firewall

For v1.1.0, keep current policy semantics and fix existing behavior only:

- validate block/allow input before apply;
- reject invalid entries clearly;
- do not report complete success after backend failure;
- make add/remove update persisted state and the active backend in one operator action when possible;
- keep SSO firewall objects namespaced;
- use a simple backend batch path when it clearly avoids obvious per-entry overhead and does not add disproportionate complexity.

Do not add new FORWARD semantics, IPv6 feature surface, concurrency frameworks, counters/search, or broad firewall redesign to v1.1.0 without a separate accepted requirement.

## 6. Fail2Ban

SSO should manage its own drop-in under `jail.d` and preserve operator-owned `jail.local`.

When validation tooling is available, validate the effective configuration before restart/reload.

## 7. Network / CPU tuning

Do not present fixed tuning as universally optimal.

v1.1.0 only fixes reproduced correctness/persistence defects in the current tuning features. Adaptive topology/workload-aware tuning is deferred until real use proves it is valuable.

Any value applied interactively and persisted for reboot should come from the same intended configuration so reboot does not silently change behavior.

## 8. Installer and update

Keep install/update behavior simple:

- local/offline install uses the directory that actually contains `install.sh`;
- first install does not create a meaningless backup;
- normal `sso` launch runs installed files only;
- update/reinstall is explicit;
- explicit update validates the small required payload before replacement;
- keep one straightforward previous-install fallback during replacement;
- launcher behavior remains obvious;
- published versions may use a straightforward versioned GitHub release/tag path.

For v1.1.0, the architecture does **not** require:

- a custom atomic publication subsystem;
- inode-identity/race protocols for temporary paths;
- runtime GitHub tag/ref object parsing;
- a bespoke release-manifest or cryptographic trust engine;
- mandatory immutable-release platform enforcement.

Those may be considered only if a future accepted requirement demonstrates that the extra complexity is worth it.

## 9. Concurrency and filesystem behavior

Use ordinary shell-safe patterns where practical:

- unique temp files/directories;
- temp-file + rename for simple state/config writes;
- simple locking only where a real concurrent-write problem is demonstrated;
- unique backup names;
- machine-readable helper output separated from UI output.

Do not build global concurrency/transaction infrastructure without evidence that normal single-operator use needs it.

## 10. Testing

Development tests must not mutate the shared AI Server Agent host's real firewall, sysctl, systemd, Fail2Ban, package database, or networking.

Use, as needed:

1. pure Bash/helper tests;
2. temporary-root/mocked-command tests;
3. isolated disposable integration only when a current behavior genuinely requires it;
4. owner validation on a real VPN/proxy server after release.

See `docs/DEVELOPMENT.md` for the normal workflow.