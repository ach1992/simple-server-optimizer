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

run_test "failed launcher write preserves the existing SSO launcher" test_failed_launcher_write_preserves_existing_launcher
run_test "unowned launcher path is never overwritten" test_unowned_launcher_is_never_overwritten
run_test "launcher shell-escapes configured runtime paths" test_launcher_shell_escapes_configured_paths
finish_tests
