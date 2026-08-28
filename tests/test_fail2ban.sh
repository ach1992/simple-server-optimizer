#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

make_mock_bin() {
  local dir="$1"
  local validate_rc="${2:-0}"
  mkdir -p "$dir"

  cat > "$dir/fail2ban-client" <<MOCK
#!/usr/bin/env bash
printf 'fail2ban-client %s\n' "\$*" >> "\${SSO_TEST_COMMAND_LOG}"
if [[ "\${1:-}" == "-t" ]]; then
  exit $validate_rc
fi
exit 0
MOCK

  cat > "$dir/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${SSO_TEST_COMMAND_LOG}"
if [[ "${1:-}" == "is-active" ]]; then
  exit 0
fi
exit 0
MOCK

  cat > "$dir/journalctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

  chmod +x "$dir/fail2ban-client" "$dir/systemctl" "$dir/journalctl"
}

run_fail2ban_fixture() {
  local tmp="$1"
  local validate_rc="${2:-0}"
  local action="$3"

  mkdir -p "$tmp/etc/fail2ban/jail.d" "$tmp/state" "$tmp/bin" "$tmp/var/log"
  : > "$tmp/commands.log"
  make_mock_bin "$tmp/bin" "$validate_rc"

  PATH="$tmp/bin:$PATH" \
  SSO_TEST_COMMAND_LOG="$tmp/commands.log" \
  ROOT_DIR="$ROOT_DIR" \
  FIXTURE_ROOT="$tmp" \
  F2B_AUTH_LOG="$tmp/var/log/auth.log" \
  F2B_SECURE_LOG="$tmp/var/log/secure" \
  ACTION="$action" \
  bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    STATE_WHITELIST="$STATE_DIR/whitelist-ip.ipv4"
    ASSETS_DIR="$ROOT_DIR/assets"
    F2B_DIR="$FIXTURE_ROOT/etc/fail2ban"
    F2B_JAIL_DIR="$F2B_DIR/jail.d"
    F2B_SSO_LOCAL="$F2B_JAIL_DIR/sso.local"
    F2B_NGINX_MARKER="$STATE_DIR/fail2ban-nginx.enabled"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/fail2ban.sh"
    case "$ACTION" in
      write) fail2ban_write_managed_config 0 ;;
      apply) fail2ban_apply_managed_config 0 ;;
      write-nginx) fail2ban_write_managed_config 1 ;;
      *) exit 99 ;;
    esac
  '
}

test_preserves_operator_jail_local() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/etc/fail2ban"
  printf '[custom]\nenabled = true\n' > "$tmp/etc/fail2ban/jail.local"
  local before
  before="$(cat "$tmp/etc/fail2ban/jail.local")"

  if ! run_fail2ban_fixture "$tmp" 0 write >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  local after
  after="$(cat "$tmp/etc/fail2ban/jail.local")"
  local rc=0
  [[ "$before" == "$after" ]] || rc=1
  [[ -f "$tmp/etc/fail2ban/jail.d/sso.local" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_whitelist_is_under_default_section() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/state"
  printf '203.0.113.10\n198.51.100.0/24\n' > "$tmp/state/whitelist-ip.ipv4"

  if ! run_fail2ban_fixture "$tmp" 0 write >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  local file="$tmp/etc/fail2ban/jail.d/sso.local"
  local default_line ignore_line
  default_line="$(grep -n '^\[DEFAULT\]$' "$file" | cut -d: -f1)"
  ignore_line="$(grep -n '^ignoreip = 203.0.113.10 198.51.100.0/24$' "$file" | cut -d: -f1)"
  local rc=0
  [[ -n "$default_line" && -n "$ignore_line" && "$ignore_line" -gt "$default_line" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_missing_auth_logs_use_systemd_backend() {
  local tmp
  tmp="$(mktemp -d)" || return 1

  if ! run_fail2ban_fixture "$tmp" 0 write >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  local rc=0
  grep -qx 'backend = systemd' "$tmp/etc/fail2ban/jail.d/sso.local" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_existing_auth_log_keeps_default_backend() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/var/log"
  : > "$tmp/var/log/auth.log"

  if ! run_fail2ban_fixture "$tmp" 0 write >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  local rc=0
  if grep -qx 'backend = systemd' "$tmp/etc/fail2ban/jail.d/sso.local"; then rc=1; fi
  rm -rf "$tmp"
  return "$rc"
}

test_validation_failure_restores_previous_config_and_skips_service() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/etc/fail2ban/jail.d"
  printf 'OLD-CONFIG\n' > "$tmp/etc/fail2ban/jail.d/sso.local"

  if run_fail2ban_fixture "$tmp" 1 apply >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  local rc=0
  [[ "$(cat "$tmp/etc/fail2ban/jail.d/sso.local")" == "OLD-CONFIG" ]] || rc=1
  if grep -q '^systemctl ' "$tmp/commands.log"; then rc=1; fi
  rm -rf "$tmp"
  return "$rc"
}

test_managed_config_is_idempotent() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  if ! run_fail2ban_fixture "$tmp" 0 write >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  local first
  first="$(sha256sum "$tmp/etc/fail2ban/jail.d/sso.local" | awk '{print $1}')"
  if ! run_fail2ban_fixture "$tmp" 0 write >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  local second
  second="$(sha256sum "$tmp/etc/fail2ban/jail.d/sso.local" | awk '{print $1}')"
  rm -rf "$tmp"
  [[ "$first" == "$second" ]]
}

test_nginx_section_is_explicit() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  if ! run_fail2ban_fixture "$tmp" 0 write-nginx >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  local rc=0
  grep -q '^\[nginx-http-auth\]$' "$tmp/etc/fail2ban/jail.d/sso.local" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_backup_captures_only_sso_fail2ban_state() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/etc/fail2ban/jail.d" "$tmp/state" "$tmp/backup"
  printf '[operator]\nenabled = true\n' > "$tmp/etc/fail2ban/jail.local"
  printf '[sshd]\nenabled = true\n' > "$tmp/etc/fail2ban/jail.d/sso.local"
  : > "$tmp/state/fail2ban-nginx.enabled"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"
    F2B_SSO_LOCAL="$FIXTURE_ROOT/etc/fail2ban/jail.d/sso.local"
    F2B_NGINX_MARKER="$STATE_DIR/fail2ban-nginx.enabled"
    source "$ROOT_DIR/modules/rollback.sh"
    backup_capture_fail2ban "$FIXTURE_ROOT/backup"
  ' || {
    rm -rf "$tmp"
    return 1
  }

  local rc=0
  [[ -f "$tmp/backup/fail2ban/sso.local" ]] || rc=1
  [[ -f "$tmp/backup/fail2ban/nginx.enabled" ]] || rc=1
  [[ ! -e "$tmp/backup/fail2ban/jail.local" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

run_disable_fixture() {
  local tmp="$1"
  local active_rc="$2"
  local validate_rc="$3"

  mkdir -p "$tmp/etc/fail2ban/jail.d" "$tmp/state"
  printf '[sshd]\nenabled = true\n' > "$tmp/etc/fail2ban/jail.d/sso.local"
  : > "$tmp/state/fail2ban-nginx.enabled"
  : > "$tmp/commands.log"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" ACTIVE_RC="$active_rc" VALIDATE_RC="$validate_rc" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    F2B_DIR="$FIXTURE_ROOT/etc/fail2ban"
    F2B_JAIL_DIR="$F2B_DIR/jail.d"
    F2B_SSO_LOCAL="$F2B_JAIL_DIR/sso.local"
    F2B_NGINX_MARKER="$STATE_DIR/fail2ban-nginx.enabled"
    COMMAND_LOG="$FIXTURE_ROOT/commands.log"

    systemctl() {
      printf "systemctl %s\n" "$*" >> "$COMMAND_LOG"
      if [[ "${1:-}" == "is-active" ]]; then
        return "$ACTIVE_RC"
      fi
      return 0
    }
    fail2ban-client() {
      printf "fail2ban-client %s\n" "$*" >> "$COMMAND_LOG"
      if [[ "${1:-}" == "-t" ]]; then
        return "$VALIDATE_RC"
      fi
      return 0
    }

    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/fail2ban.sh"
    fail2ban_disable_managed_config
  '
}

test_disable_removes_only_sso_config_and_restarts_active_service() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  run_disable_fixture "$tmp" 0 0 >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ ! -e "$tmp/etc/fail2ban/jail.d/sso.local" ]] || rc=1
  [[ ! -e "$tmp/state/fail2ban-nginx.enabled" ]] || rc=1
  grep -q '^systemctl restart fail2ban$' "$tmp/commands.log" || rc=1
  if grep -Eq '^systemctl (stop|disable|enable) ' "$tmp/commands.log"; then rc=1; fi
  rm -rf "$tmp"
  return "$rc"
}

test_disable_preserves_inactive_service_state() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  run_disable_fixture "$tmp" 3 0 >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ ! -e "$tmp/etc/fail2ban/jail.d/sso.local" ]] || rc=1
  if grep -Eq '^systemctl (restart|stop|disable|enable|start) ' "$tmp/commands.log"; then rc=1; fi
  rm -rf "$tmp"
  return "$rc"
}

test_disable_validation_failure_restores_sso_config() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  if run_disable_fixture "$tmp" 3 1 >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  local rc=0
  [[ -f "$tmp/etc/fail2ban/jail.d/sso.local" ]] || rc=1
  [[ -f "$tmp/state/fail2ban-nginx.enabled" ]] || rc=1
  if grep -Eq '^systemctl (restart|stop|disable|enable|start) ' "$tmp/commands.log"; then rc=1; fi
  rm -rf "$tmp"
  return "$rc"
}

run_test "Fail2Ban integration preserves operator jail.local" test_preserves_operator_jail_local
run_test "whitelist ignoreip is rendered inside DEFAULT" test_whitelist_is_under_default_section
run_test "missing SSH auth log selects the systemd backend" test_missing_auth_logs_use_systemd_backend
run_test "existing SSH auth log keeps the default Fail2Ban backend" test_existing_auth_log_keeps_default_backend
run_test "validation failure restores previous SSO config and skips systemctl" test_validation_failure_restores_previous_config_and_skips_service
run_test "SSO Fail2Ban config rendering is idempotent" test_managed_config_is_idempotent
run_test "nginx jail is an explicit managed section" test_nginx_section_is_explicit
run_test "Fail2Ban backup captures only SSO-owned state" test_backup_captures_only_sso_fail2ban_state
run_test "Fail2Ban disable removes only SSO config and restarts an active service" test_disable_removes_only_sso_config_and_restarts_active_service
run_test "Fail2Ban disable preserves an inactive service state" test_disable_preserves_inactive_service_state
run_test "Fail2Ban disable validation failure restores SSO config" test_disable_validation_failure_restores_sso_config
finish_tests
