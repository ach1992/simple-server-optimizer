#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

test_failed_launcher_write_preserves_existing_launcher() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/install" "$tmp/state" "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/install/sso.sh"
  cat > "$tmp/bin/sso" <<'LEGACY'
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR_FILE="/etc/sso/install_dir"
INSTALL_DIR="/root/simple-server-optimizer"
exec bash "${INSTALL_DIR}/sso.sh" "$@"
LEGACY
  local before
  before="$(cat "$tmp/bin/sso")"

  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    cat() { return 1; }
    ! create_launcher
    ! compgen -G "$SSO_LAUNCHER_PATH.tmp.*" > /dev/null
  ' >/dev/null 2>&1
  local rc=$?
  [[ "$rc" == "0" && "$(cat "$tmp/bin/sso")" == "$before" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_unowned_launcher_is_never_overwritten() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/install" "$tmp/state" "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/install/sso.sh"
  printf 'operator-command\n' > "$tmp/bin/sso"

  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    ! create_launcher
    [[ "$(cat "$SSO_LAUNCHER_PATH")" == "operator-command" ]]
    ! compgen -G "$SSO_LAUNCHER_PATH.tmp.*" > /dev/null
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_launcher_shell_escapes_configured_paths() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  local install_dir="$tmp/install\$(touch INJECTED)"
  mkdir -p "$install_dir" "$tmp/state" "$tmp/bin"
  cat > "$install_dir/sso.sh" <<RUNNER
#!/usr/bin/env bash
set -Eeuo pipefail
: > "$tmp/RAN"
RUNNER
  chmod +x "$install_dir/sso.sh"

  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" INSTALL_FIXTURE="$install_dir" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$INSTALL_FIXTURE"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    create_launcher
    bash -n "$SSO_LAUNCHER_PATH"
    [[ "$(stat -c %a "$SSO_LAUNCHER_PATH")" == "755" ]]
    grep -Fq "# Managed by Simple Server Optimizer." "$SSO_LAUNCHER_PATH"
    cd "$TMPROOT"
    "$SSO_LAUNCHER_PATH"
    [[ -f "$TMPROOT/RAN" ]]
    [[ ! -e "$TMPROOT/INJECTED" ]]
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_launcher_ownership_requires_exact_generated_structure() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/install" "$tmp/state" "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/install/sso.sh"

  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"

    printf "#!/usr/bin/env bash\n# Managed by Simple Server Optimizer.\necho operator\n" > "$SSO_LAUNCHER_PATH"
    if launcher_is_sso_owned "$SSO_LAUNCHER_PATH"; then exit 1; fi

    printf "#!/usr/bin/env bash\n# Managed by Simple Server Optimizer.\n# SSO Launcher Schema: 1\nset -Eeuo pipefail\n" > "$SSO_LAUNCHER_PATH"
    if launcher_is_sso_owned "$SSO_LAUNCHER_PATH"; then exit 1; fi

    render_current_launcher > "$SSO_LAUNCHER_PATH"
    launcher_is_current_sso_owned "$SSO_LAUNCHER_PATH"
    launcher_is_sso_owned "$SSO_LAUNCHER_PATH"

    render_transitional_launcher > "$SSO_LAUNCHER_PATH"
    launcher_is_sso_owned "$SSO_LAUNCHER_PATH"
    if launcher_is_current_sso_owned "$SSO_LAUNCHER_PATH"; then exit 1; fi

    render_legacy_launcher > "$SSO_LAUNCHER_PATH"
    launcher_is_sso_owned "$SSO_LAUNCHER_PATH"
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_launcher_symlink_and_directory_are_rejected() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/install" "$tmp/state" "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/install/sso.sh"

  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"

    render_current_launcher > "$TMPROOT/real-launcher"
    ln -s "$TMPROOT/real-launcher" "$SSO_LAUNCHER_PATH"
    if launcher_is_sso_owned "$SSO_LAUNCHER_PATH"; then exit 1; fi
    if create_launcher >/dev/null 2>&1; then exit 1; fi
    rm -f "$SSO_LAUNCHER_PATH"

    mkdir -p "$SSO_LAUNCHER_PATH"
    if launcher_is_sso_owned "$SSO_LAUNCHER_PATH"; then exit 1; fi
    if create_launcher >/dev/null 2>&1; then exit 1; fi
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_launcher_chmod_failure_preserves_previous_launcher() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/install" "$tmp/state" "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/install/sso.sh"

  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    render_transitional_launcher > "$SSO_LAUNCHER_PATH"
    before="$(cat "$SSO_LAUNCHER_PATH")"
    chmod() {
      if [[ "${1:-}" == "0755" && "${2:-}" == "$SSO_LAUNCHER_PATH.tmp."* ]]; then
        : > "$TMPROOT/CHMOD_FAILED"
        return 77
      fi
      command chmod "$@"
    }
    if create_launcher >/dev/null 2>&1; then exit 1; fi
    [[ -f "$TMPROOT/CHMOD_FAILED" ]]
    [[ "$(cat "$SSO_LAUNCHER_PATH")" == "$before" ]]
    ! compgen -G "$SSO_LAUNCHER_PATH.tmp.*" >/dev/null
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_launcher_mv_failure_preserves_previous_launcher() {
  local tmp mode case_root
  tmp="$(mktemp -d)" || return 1

  for mode in fail false-success corrupt-success; do
    case_root="$tmp/$mode"
    mkdir -p "$case_root/install" "$case_root/state" "$case_root/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$case_root/install/sso.sh"

    ROOT_DIR="$ROOT_DIR" TMPROOT="$case_root" MODE="$mode" bash -c '
      set -Eeuo pipefail
      export SSO_INSTALL_LIB_ONLY=1
      export SSO_INSTALL_DIR="$TMPROOT/install"
      export SSO_STATE_DIR="$TMPROOT/state"
      export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
      source "$ROOT_DIR/install.sh"
      render_transitional_launcher > "$SSO_LAUNCHER_PATH"
      chmod 0755 "$SSO_LAUNCHER_PATH"
      cp -p "$SSO_LAUNCHER_PATH" "$TMPROOT/expected-launcher"
      mv() {
        local destination="${@: -1}" source="${@: -2:1}"
        if [[ "$destination" == "$SSO_LAUNCHER_PATH" && "$source" == "$SSO_LAUNCHER_PATH.tmp."* ]]; then
          : > "$TMPROOT/MV_INJECTED"
          case "$MODE" in
            false-success) return 0 ;;
            fail) return 78 ;;
            corrupt-success)
              command mv "$@" || return
              printf "#!/usr/bin/env bash\necho corrupted\n" > "$destination"
              return 0
              ;;
          esac
        fi
        command mv "$@"
      }
      if create_launcher >/dev/null 2>&1; then exit 1; fi
      [[ -f "$TMPROOT/MV_INJECTED" ]]
      cmp -s "$SSO_LAUNCHER_PATH" "$TMPROOT/expected-launcher"
      launcher_is_sso_owned "$SSO_LAUNCHER_PATH"
      ! compgen -G "$SSO_LAUNCHER_PATH.tmp.*" >/dev/null
      ! compgen -G "$SSO_LAUNCHER_PATH.previous.*" >/dev/null
      ! compgen -G "$SSO_LAUNCHER_PATH.restore.*" >/dev/null
    ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  done

  case_root="$tmp/first-corrupt-success"
  mkdir -p "$case_root/install" "$case_root/state" "$case_root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_root/install/sso.sh"
  ROOT_DIR="$ROOT_DIR" TMPROOT="$case_root" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    mv() {
      local destination="${@: -1}" source="${@: -2:1}"
      if [[ "$destination" == "$SSO_LAUNCHER_PATH" && "$source" == "$SSO_LAUNCHER_PATH.tmp."* ]]; then
        : > "$TMPROOT/MV_INJECTED"
        command mv "$@" || return
        printf "#!/usr/bin/env bash\necho corrupted\n" > "$destination"
        return 0
      fi
      command mv "$@"
    }
    if create_launcher >/dev/null 2>&1; then exit 1; fi
    [[ -f "$TMPROOT/MV_INJECTED" && ! -e "$SSO_LAUNCHER_PATH" ]]
    ! compgen -G "$SSO_LAUNCHER_PATH.*.*" >/dev/null
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  rm -rf "$tmp"
}

run_test "failed launcher write preserves the existing SSO launcher" test_failed_launcher_write_preserves_existing_launcher
run_test "unowned launcher path is never overwritten" test_unowned_launcher_is_never_overwritten
run_test "launcher ownership requires an exact current/transitional/legacy structure" test_launcher_ownership_requires_exact_generated_structure
run_test "launcher symlink and directory destinations are rejected" test_launcher_symlink_and_directory_are_rejected
run_test "launcher chmod failure preserves the previous launcher" test_launcher_chmod_failure_preserves_previous_launcher
run_test "launcher publication failure, false success, and postcondition corruption preserve prior state" test_launcher_mv_failure_preserves_previous_launcher
run_test "launcher shell-escapes configured runtime paths" test_launcher_shell_escapes_configured_paths
finish_tests
