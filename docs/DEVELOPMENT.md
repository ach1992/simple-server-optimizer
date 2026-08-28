# Development, Validation, and Release Workflow

This document defines the normal engineering workflow for SSO. Keep it proportional to a small Bash project.

## 1. Working model

- Integration target: `main`.
- Substantive changes use an isolated branch/workspace and a PR.
- Keep each change bounded to its owning Issue.
- Prefer the smallest implementation that fixes the reproduced problem.
- Do not expand a bug fix into a new subsystem unless the accepted requirement actually needs it.

## 2. Validation baseline

For changed Bash code:

```bash
bash -n install.sh sso.sh modules/*.sh
shellcheck --severity=error install.sh sso.sh modules/*.sh
bash tests/run.sh
```

Tests should be deterministic and should not require mutation of the shared development host.

Useful patterns include temporary directories, mocked commands through `PATH`, sourced helper functions, and focused failure-path assertions.

Add regressions for reproduced bugs when practical. Do not create large test frameworks merely to defend hypothetical behavior outside the current product contract.

## 3. Shared-host safety

Do not mutate the shared development host's live firewall, routing, sysctl, systemd, Fail2Ban, or package state just to validate SSO.

Use mocks/temp roots for normal development. Use a disposable isolated VM/server only when the behavior genuinely cannot be validated otherwise.

## 4. Delivered v1.1.0 stabilization baseline

The published `v1.1.0` release established and validated these behaviors:

- Fail2Ban operator configuration is not overwritten;
- rollback/uninstall acts only on proven SSO-owned state and restores captured runtime state where required;
- local/offline installer uses its actual payload directory;
- normal `sso` launch does not download/update the application;
- explicit update/reinstall is simple, validates required files, preserves a straightforward previous-install fallback, and reports failure accurately;
- immediate and persisted CPU/RPS/RFS/XPS values agree where the feature supports them;
- rollback/uninstall restores the exact captured RPS/RFS/XPS runtime baseline or fails closed;
- firewall input is validated before apply;
- firewall backend failure cannot produce complete-success output;
- blacklist/whitelist add/remove is immediate and simple when the active backend is available;
- SSO-owned Fail2Ban is stopped and verified before package purge;
- installer-created previous-install fallback state is removed safely during full uninstall.

Treat this as the compatibility baseline for later maintenance unless a future accepted Issue intentionally changes behavior.

## 5. Installer/update guidance

Keep the installer understandable.

The v1.1.0 baseline requires it to:

1. locate the payload relative to `install.sh` for local/offline use;
2. validate the small required file set before replacing an installation;
3. avoid creating a meaningless `.bak` on first install;
4. preserve one straightforward previous-install fallback during explicit update/reinstall;
5. create/update the `sso` launcher;
6. fail clearly if copy/validation fails;
7. keep normal application launch separate from update.

A versioned GitHub release/tag source path is sufficient for immutable published-version installation/update guidance.

Do not add these requirements unless a new accepted Issue explicitly needs them:

- custom atomic publication frameworks;
- inode-identity/race state machines;
- runtime GitHub tag/ref object parsing chains;
- bespoke release-manifest trust frameworks;
- mandatory immutable-release platform configuration.

## 6. Firewall validation

For the current firewall manager, focus on:

- IPv4/CIDR parsing and rejection;
- generated command/rules correctness;
- false-success prevention;
- simple add/remove behavior;
- idempotent re-apply;
- preserving existing policy scope.

Use a backend batch path when it is already simple and materially avoids obvious per-entry overhead, but do not redesign the firewall subsystem solely for theoretical scale or concurrency.

## 7. Fail2Ban validation

SSO must write only its own configuration/drop-in and preserve unrelated operator configuration.

When Fail2Ban validation tooling is available, validate before restart/reload.

## 8. Review standard

GitHub Copilot review must not be used for this repository.

Default pre-integration review is:

- re-read the owning Issue acceptance criteria;
- inspect the effective diff;
- check operator-config preservation and failure reporting;
- run focused regressions and repository CI;
- perform developer/Master self-review for unintended scope.

Independent review is **optional and proportional**, not a blanket rule. Use a fresh independent reviewer only when the actual candidate introduces exceptional destructive/security complexity, difficult rollback, or broad semantics that materially benefit from separation.

Do not create an independent-review packet for a bounded change merely because the script executes as root.

## 9. CI

CI should remain small and high-signal:

- Bash syntax;
- ShellCheck error-level checks;
- repository regression tests.

Do not add large matrices, caches, or release/security machinery unless a real compatibility or defect pattern justifies them.

## 10. Release readiness

For a future release:

- define the bounded release outcome in GitHub Issues;
- integrate the accepted changes;
- run required checks on the exact release commit;
- ensure README/release notes match shipped behavior;
- create the version tag on that exact commit;
- publish a normal GitHub Release;
- optionally publish straightforward SHA256 checksums where useful;
- run proportionate owner/real-server validation when system-level behavior warrants it;
- verify the published tag/Release resolves to the intended exact commit before closing delivery work.

The release process does not require a custom immutable-release workflow, runtime tag resolver, or bespoke supply-chain implementation unless a future accepted requirement demonstrates that need.

`v1.1.0` completed this process successfully and is the current published stabilization baseline.

## 11. Owner test handoff

When a future release needs real-server validation, keep the owner checklist concise and practical. Depending on the changed surface, it may include:

- install from the documented release path;
- run `sso` and confirm no unwanted re-download occurs;
- exercise explicit update/reinstall;
- add/remove one firewall entry and confirm runtime state;
- verify Fail2Ban still preserves operator configuration;
- verify one tuning persistence path;
- exercise rollback/uninstall as appropriate;
- return the exact failing command/output/log if something breaks.

The `v1.1.0` real-server validation is complete. Future feature work should still be driven by demonstrated operator need rather than an automatic expansion roadmap.
