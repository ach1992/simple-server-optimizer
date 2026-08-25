#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

run_package_ownership_fixture() {
  local tmp="$1"
  local preinstalled="$2"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" PREINSTALLED="$preinstalled" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    mkdir -p "$STATE_DIR"
    client_available=0
    package_installed="$PREINSTALLED"

    cmd_exists() {
      if [[ "$1" == "fail2ban-client" ]]; then
        [[ "$client_available" == "1" ]]
        return
      fi
      command -v "$1" >/dev/null 2>&1
    }
    run_step() { shift; "$@"; }
    ensure_dirs() { mkdir -p "$@"; }
    dpkg() {
      [[ "${1:-}" == "-s" && "${2:-}" == "fail2ban" && "$package_installed" == "1" ]]
    }
    apt-get() {
      if [[ "${1:-}" == "install" ]]; then
        client_available=1
        package_installed=1
      fi
      return 0
    }

    source "$ROOT_DIR/modules/fail2ban.sh"
    ensure_fail2ban_installed
  '
}

test_preinstalled_package_is_not_marked_sso_owned() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  if ! run_package_ownership_fixture "$tmp" 1 >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  local rc=0
  [[ ! -e "$tmp/state/installed_fail2ban.marker" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_sso_installed_package_is_marked_owned() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  if ! run_package_ownership_fixture "$tmp" 0 >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  local rc=0
  [[ -e "$tmp/state/installed_fail2ban.marker" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

run_service_fixture() {
  local mode="$1"
  local active_rc="$2"
  local log="$3"

  ROOT_DIR="$ROOT_DIR" SERVICE_MODE="$mode" ACTIVE_RC="$active_rc" COMMAND_LOG="$log" bash -c '
    set -Eeuo pipefail
    STATE_DIR="/tmp/sso-test-state-unused"
    run_step() { shift; "$@"; }
    info() { :; }
    systemctl() {
      printf "systemctl %s\n" "$*" >> "$COMMAND_LOG"
      if [[ "${1:-}" == "is-active" ]]; then
        return "$ACTIVE_RC"
      fi
      return 0
    }
    source "$ROOT_DIR/modules/fail2ban.sh"
    fail2ban_apply_service "$SERVICE_MODE"
  '
}

test_config_only_apply_preserves_inactive_service() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  : > "$tmp/commands.log"
  if ! run_service_fixture preserve 3 "$tmp/commands.log" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  local rc=0
  grep -q '^systemctl is-active --quiet fail2ban$' "$tmp/commands.log" || rc=1
  if grep -Eq '^systemctl (restart|enable|start) ' "$tmp/commands.log"; then
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

test_explicit_enable_starts_inactive_service() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  : > "$tmp/commands.log"
  if ! run_service_fixture enable 3 "$tmp/commands.log" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  local rc=0
  grep -q '^systemctl enable --now fail2ban$' "$tmp/commands.log" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_active_service_is_restarted() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  : > "$tmp/commands.log"
  if ! run_service_fixture preserve 0 "$tmp/commands.log" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  local rc=0
  grep -q '^systemctl restart fail2ban$' "$tmp/commands.log" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_whitelist_parser_strips_inline_comments() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  printf '203.0.113.10 # office\n198.51.100.0/24;partner\n# comment\n' > "$tmp/whitelist"

  local output
  output="$(ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    STATE_WHITELIST="$FIXTURE_ROOT/whitelist"
    source "$ROOT_DIR/modules/fail2ban.sh"
    fail2ban_collect_whitelist_ips
  ')" || {
    rm -rf "$tmp"
    return 1
  }

  rm -rf "$tmp"
  [[ "$output" == "203.0.113.10 198.51.100.0/24" ]]
}

test_handled_menu_failure_returns_to_caller() {
  ROOT_DIR="$ROOT_DIR" bash -c '
    set -Eeuo pipefail
    STATE_DIR="/tmp/sso-test-state-unused"
    source "$ROOT_DIR/modules/fail2ban.sh"
    header() { :; }
    section() { :; }
    backup_create() { printf "%s\n" "/tmp/backup"; }
    ensure_fail2ban_installed() { return 0; }
    detect_nginx() { return 1; }
    warn() { :; }
    pause() { :; }
    module_fail2ban_enable_nginx
    printf "returned-to-menu\n"
  ' | grep -q '^returned-to-menu$'
}

run_test "preinstalled Fail2Ban package is not marked as SSO-owned" test_preinstalled_package_is_not_marked_sso_owned
run_test "SSO-installed Fail2Ban package is marked as SSO-owned" test_sso_installed_package_is_marked_owned
run_test "config-only Fail2Ban apply preserves inactive service state" test_config_only_apply_preserves_inactive_service
run_test "explicit Fail2Ban enable starts an inactive service" test_explicit_enable_starts_inactive_service
run_test "active Fail2Ban service is restarted after config apply" test_active_service_is_restarted
run_test "Fail2Ban whitelist parser strips inline comments" test_whitelist_parser_strips_inline_comments
run_test "handled Fail2Ban menu failures return to the menu" test_handled_menu_failure_returns_to_caller
finish_tests
