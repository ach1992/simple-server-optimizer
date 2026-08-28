# AGENTS.md

These instructions apply to the entire repository.

## Routine recovery

For normal development or a replacement Master, recover current truth from:

1. `README.md` for current user-facing behavior and direction;
2. this file for stable contributor rules;
3. the active GitHub Issue/PR;
4. current Git refs and CI;
5. only the code/tests needed for the active work.

`PROJECT-SPEC.md` is read when project-level intent materially changes or becomes unclear. Current Git/GitHub/CI is authoritative for mutable state.

## Engineering rules

- Keep SSO **small, Bash-first, and easy to operate**.
- Fix reproduced defects before adding architecture for hypothetical edge cases.
- Prefer the smallest correct change that solves the active Issue.
- Preserve unrelated operator configuration. Prefer SSO-owned files/drop-ins and namespaced resources.
- Repeated supported operations should be idempotent where practical.
- Do not report complete success after rejected input or a failed/partial apply.
- Keep dependencies minimal and justified.
- Do not disable IPv6 or apply aggressive kernel/network settings as generic shortcuts.
- Do not turn bounded installer/update work into a custom transaction, package-manager, or supply-chain framework unless an explicit accepted requirement genuinely needs it.
- Avoid broad cleanup/refactors unrelated to the active Issue.

## Repository workflow

- Do not develop substantive work directly on `main`.
- Use a dedicated branch/workspace and PR for substantive changes.
- Preserve concurrent work; never reset, clean, force-push, or overwrite uncertain work for convenience.
- The dedicated AI Server Agent may be used only from a uniquely isolated workspace.

## Validation

For changed Bash code, normally run:

```bash
bash -n install.sh sso.sh modules/*.sh
shellcheck --severity=error install.sh sso.sh modules/*.sh
bash tests/run.sh
```

Add focused regression coverage for reproduced bugs when practical.

Do not mutate the shared development host's real firewall, sysctl, systemd, Fail2Ban, routing, or package state just to test SSO. Use mocks, temporary roots, or an explicitly disposable environment.

## Safety-sensitive behavior

- Validate Fail2Ban configuration before restart/reload when tooling is available.
- Validate firewall input before apply and report backend failure accurately.
- Rollback/uninstall should act only on SSO-owned artifacts.
- Backup logic must distinguish prior presence from prior absence when that distinction is required for correct restore.
- Installer/update logic should remain understandable: validate the required payload, preserve a straightforward fallback for explicit update, replace files, and fail honestly.

## Review

GitHub Copilot review must not be used for this repository.

Default review for bounded changes is:

- focused tests/regressions;
- repository CI;
- developer/Master diff self-review.

Do **not** require a fresh independent HIGH_ASSURANCE review merely because code runs as root. Add independent review only when the actual candidate introduces exceptional destructive/security complexity or the active Issue explicitly requires it for a concrete reason.

## Release

Follow the active release Issue and `docs/DEVELOPMENT.md`.

A normal versioned Git tag/GitHub Release is sufficient for the v1.1.0 product contract. Straightforward checksums may be included where useful, but custom immutable-release/supply-chain machinery is not a standing release requirement.

Real VPN/proxy server validation is a human/owner operation unless an exact disposable target is explicitly authorized.