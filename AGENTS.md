# AGENTS.md

These instructions apply to the entire repository.

## Routine recovery and work entry

For normal development or a replacement Master, recover current truth from the sources closest to the work:

1. `README.md` for supported user-facing behavior and project navigation;
2. this file for stable contributor/agent rules;
3. the relevant specialized docs such as `docs/ARCHITECTURE.md` and `docs/DEVELOPMENT.md`;
4. the current GitHub Issue/PR that owns the work, including dependencies and acceptance;
5. current Git refs, CI/checks, and release/tag state;
6. only then the source/tests required by the active work.

Current Git/GitHub/CI evidence is authoritative for mutable state. Do not reconstruct current status from old chat summaries.

`PROJECT-SPEC.md` is a bootstrap source-of-intent, not part of the routine recovery path. Read it only when project-level intent, durable constraints, supported environments, non-goals, or completion criteria are materially unclear or explicitly changing.

## Engineering rules

- Keep the toolkit small and Bash-first unless a new dependency has a clear operational payoff.
- Treat root-executed code, firewall changes, sysctl changes, package operations, systemd units, update/install code, and rollback/uninstall paths as safety-sensitive.
- Preserve unrelated operator configuration. Prefer SSO-owned files/drop-ins and namespaced firewall objects.
- Changes must be idempotent where repeated application is expected.
- Do not report success after a partial apply. Validate input/config first and verify the intended result.
- Keep online install/update provenance immutable and integrity-checked for releases.
- Never hardcode credentials, tokens, private URLs, or environment-specific secrets.
- Do not disable IPv6 or apply aggressive network/kernel settings as generic shortcuts.
- Network tuning must be justified by the VPN/proxy workload and the detected host characteristics.
- Avoid broad cleanup/refactors unrelated to the active Issue.

## Repository workflow

- Do not develop substantive work directly on `main`.
- Use a dedicated branch/workspace per active implementation.
- PR-based integration is the normal path for substantive changes.
- Preserve concurrent work; never reset, clean, force-push, or overwrite another Master's/worker's workspace or branch for convenience.
- The dedicated AI Server Agent may be used for project work only from a uniquely named isolated workspace. Do not reuse another active project's worktree.

## Validation

At minimum for changed Bash code:

```bash
bash -n install.sh sso.sh modules/*.sh
shellcheck --severity=error install.sh sso.sh modules/*.sh
```

Run `bash tests/run.sh` when the test suite is present. Add focused regression coverage for reproduced bugs when practical.

Never mutate the shared development host's real firewall, sysctl, systemd, Fail2Ban, or package state just to test SSO. Use mocks, temporary roots, namespaces/containers, or a dedicated disposable VM/server appropriate to the behavior.

## Safety-sensitive configuration

- Validate Fail2Ban configuration before restart/reload.
- Prefer atomic/batch firewall updates; validate the generated ruleset before apply when supported.
- Rollback/uninstall must account for every persistent SSO-owned artifact created or changed by the active feature.
- Backup code must distinguish “artifact did not exist before” from “artifact existed and was captured”.

## Release

Follow `docs/DEVELOPMENT.md` and the active release Issue. A release must identify an immutable reviewed commit/tag and include the required integrity metadata. Real VPN/proxy server validation is a human operation unless an exact disposable target has been explicitly authorized.