# Development, Validation, and Release Workflow

This document owns the repository's normal engineering workflow. Current priorities, dependencies, and acceptance criteria live in GitHub Issues.

## 1. Working model

- Integration target: `main`.
- Substantive work uses an isolated branch/workspace and a pull request.
- Keep each implementation bounded to its owning Issue unless a directly required safety/correctness dependency is discovered.
- Preserve unrelated work; do not reset/clean/force-push through ambiguous state.
- Use SemVer for releases.

Recommended branch naming:

```text
fix/<issue>-<short-name>
feature/<issue>-<short-name>
master/<bounded-master-work>
```

## 2. Safe AI Server Agent usage

When using the dedicated AI Server Agent:

- create a uniquely named workspace for this repository/task;
- never reuse or edit an active workspace belonging to another Master/Worker/project;
- normal source/build/test commands run as the unprivileged `aiworker` user;
- do not request root merely to make a test easier;
- never mutate the shared host's real firewall, routing, sysctl, systemd, Fail2Ban, or package state to validate SSO code.

Tests that require real root/kernel/service behavior belong in a disposable isolated environment or at an explicit human-controlled server-validation gate.

## 3. Required static checks

For every changed Bash path:

```bash
bash -n install.sh sso.sh modules/*.sh
```

When ShellCheck is available:

```bash
shellcheck --severity=error install.sh sso.sh modules/*.sh
```

Warnings should be reviewed, not automatically suppressed. A warning becomes required work when it exposes a correctness, portability, or maintenance defect relevant to the change.

## 4. Test suite

The repository test entrypoint is:

```bash
bash tests/run.sh
```

Tests should be deterministic and must not require mutation of the developer host.

Preferred patterns:

- source a module with safe function overrides/mocks;
- inject temporary paths instead of hardcoding `/etc` in test execution;
- prepend a temporary `PATH` containing mocked commands such as `nft`, `ipset`, `systemctl`, or `fail2ban-client`;
- capture command invocations and assert intended ordering/arguments;
- use a temporary filesystem root for rendered config/state;
- test failure paths, not only happy paths.

Regression coverage should be added for reproduced defects whenever practical.

## 5. High-value stabilization regressions

The v1.1.0 stabilization suite should cover at least the behavior corresponding to the active Issues, including:

- Fail2Ban existing operator config is not overwritten;
- SSO-generated Fail2Ban config is syntactically valid and validation failure prevents restart;
- rollback backup selection works and backup IDs do not collide;
- backup/rollback represents prior absence versus prior existence for SSO-owned artifacts;
- uninstall removes all SSO-owned launcher/restore artifacts without deleting unrelated files;
- immediate and persisted RPS/RFS values agree;
- CPU-mask formatting handles large CPU counts correctly where that behavior remains supported;
- local/offline installer uses its actual payload directory;
- helper functions used as machine-readable output do not mix UI output into returned values;
- invalid firewall entries are rejected before runtime apply;
- mocked firewall element/apply failures cannot produce a false success;
- bulk firewall apply does not spawn one backend process per list entry in the optimized backend path;
- blacklist/whitelist add/remove persists and updates active state in one requested operation where supported.

## 6. Firewall validation strategy

### Pure/mocked tests

Validate:

- list parsing and canonicalization;
- duplicate handling;
- invalid IPv4/CIDR rejection;
- generated nftables batch content;
- validation/apply sequencing;
- expected set/table names;
- false-success prevention;
- immediate add/remove behavior;
- lock behavior for concurrent mutation where practical.

### Isolated integration

When a disposable environment with nftables is available:

1. generate the SSO ruleset;
2. validate using the backend's check mode where supported;
3. apply only inside the isolated environment;
4. verify table/set/chain existence and entry counts;
5. verify re-apply idempotency;
6. verify remove/disable behavior.

Do not run these steps against the shared development host's live firewall.

## 7. Fail2Ban validation strategy

SSO must write only its owned drop-in. Before service restart/reload, validate the effective configuration with the installed Fail2Ban tool when available.

Mocked tests must prove that:

- `/etc/fail2ban/jail.local` is not rewritten;
- `ignoreip` is placed under a valid section in the SSO-owned file;
- a validation failure stops before restart;
- rollback/uninstall removes/restores only SSO-owned state.

## 8. Installer/update validation

Validate separately:

- offline/local payload discovery;
- online release metadata retrieval;
- immutable version/tag selection;
- checksum/integrity failure;
- incomplete payload failure;
- staged installation before live replacement;
- previous-install preservation/rollback behavior;
- launcher creation;
- no stale `.bak` creation on a first install merely because the target directory was pre-created by the installer itself.

Never use a successful download alone as proof of trusted release identity.

## 9. Review standard

Before integration, review the effective target-to-candidate diff for:

- scope and acceptance;
- operator configuration preservation;
- idempotency and partial failure;
- rollback/uninstall completeness;
- root/supply-chain security;
- Debian/Ubuntu compatibility;
- runtime performance for large lists/high connection workloads where affected;
- tests that can false-pass because commands are mocked incorrectly;
- docs/user-facing behavior drift.

Security-sensitive or high-blast-radius changes may require an independent reviewer context in addition to Master self-review.

GitHub Copilot review must not be used for this repository. When an independent review is required, the Master must provide the owner with one ready-to-paste `INDEPENDENT REVIEW CHAT` prompt for a fresh independent chat/reviewer context. The review packet must bind the exact repository, PR/change, target/base SHA, candidate HEAD SHA, owning Issue/Contract Revision, review scope, risk, constraints, and current validation evidence. The returned review must identify the exact candidate SHA, give an `APPROVE` or `CHANGES_REQUIRED` verdict, and list concrete `BLOCKER`, `REQUIRED`, or `OPTIONAL` findings. Before relying on it, the Master must re-check that the candidate, target, contract, and effective diff have not materially drifted.

## 10. CI baseline

CI should remain small and high-signal. At minimum it should run:

```text
bash syntax
ShellCheck error-level checks
repository regression tests
```

Do not add large matrices/caches merely because they are available. Add supported-OS or backend integration coverage when it protects a real compatibility boundary that unit/mocked tests cannot establish.

## 11. Release readiness

Before publishing a release:

- all accepted release Issues are integrated or explicitly removed from release scope through the appropriate project decision;
- target branch checks pass on the exact release commit;
- version/changelog/release notes match the actual effective change;
- installation source is tied to the immutable release identity;
- release integrity metadata is generated and verified;
- known limitations relevant to operators are documented;
- rollback/update behavior is validated proportionally to the change.

For `v1.1.0`, publication is followed by an explicit owner test on a real VPN/proxy server. That real-server validation is a human-operation boundary and is not replaced by CI.

## 12. v1.1.0 human test handoff

The release handoff should provide the owner with:

- exact release/tag/commit identity;
- integrity-verified install command/path;
- a concise backup/snapshot warning;
- expected menu changes;
- targeted checks for firewall, Fail2Ban, network tuning, rollback, update, and uninstall;
- commands/output needed to verify effective state;
- exact logs/output to return on failure.

Do not start the major post-v1.1.0 VPN-aware feature expansion until the owner test result is reconciled, except for a required stabilization hotfix.
