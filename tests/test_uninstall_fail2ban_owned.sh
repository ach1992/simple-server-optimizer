#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/testlib.sh"

make_fixture() {
  local tmp="$1"
  mkdir -p \
    "$tmp/state" "$tmp/backups" "$tmp/install" "$tmp/systemd" \
    "$tmp/sysctl" "$tmp/modules-load" "$tmp/sbin" "$tmp/bin" \
    "$tmp/fail2ban/jail.d"
  : > "$tmp/state/installed_fail2ban.marker"
  : > "$tmp/install/sso.sh"
  : > "$tmp/bin/sso"
  printf '[sshd]\nenabled = true\n' > "$tmp/fail2ban/jail.d/sso.local"
  : > "$tmp/commands.log"
}

owned_fail2ban_stops_before_purge_and_uninstall_finishes() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_fixture "$tmp"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"; BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"; SSO_DIR="$FIXTURE_ROOT/install"
    SSO_SYSTEMD_DIR="$FIXTURE_ROOT/systemd"; SSO_SYSCTL_DIR="$FIXTURE_ROOT/sysctl"; SSO_MODULES_LOAD_DIR="$FIXTURE_ROOT/modules-load"
    SSO_LOCAL_SBIN_DIR="$FIXTURE_ROOT/sbin"; SSO_LOCAL_BIN_DIR="$FIXTURE_ROOT/bin"
    F2B_SSO_LOCAL="$FIXTURE_ROOT/fail2ban/jail.d/sso.local"; F2B_NGINX_MARKER="$STATE_DIR/fail2ban-nginx.enabled"
    source "$ROOT_DIR/modules/utils.sh"; source "$ROOT_DIR/modules/rollback.sh"; source "$ROOT_DIR/modules/uninstall.sh"
    header(){ :; }; section(){ :; }; info(){ :; }; warn(){ :; }; err(){ :; }; pause(){ :; }
    read_input(){ local -n out="$2"; out="y"; }
    backup_migrate_ownership_baselines(){ return 0; }
    backup_resource_baseline_dir(){ return 1; }
    uninstall_disable_sso_service(){ return 0; }
    remove_sso_firewall_runtime(){ return 0; }
    uninstall_cpu_runtime_owned(){ return 1; }

    ACTIVE=1
    PURGED=0
    systemd_load_state() {
      if [[ "$1" == "fail2ban.service" ]]; then
        if (( PURGED )); then printf "not-found\n"; else printf "loaded\n"; fi
      else
        printf "not-found\n"
      fi
    }
    systemctl() {
      printf "systemctl %s\n" "$*" >> "$FIXTURE_ROOT/commands.log"
      case "$1" in
        is-active)
          if (( ACTIVE )); then printf "active\n"; return 0; fi
          printf "inactive\n"; return 3
          ;;
        stop)
          [[ "${2:-}" == "fail2ban.service" ]] || return 1
          ACTIVE=0
          return 0
          ;;
        daemon-reload) return 0 ;;
        *) return 0 ;;
      esac
    }
    apt-get() {
      printf "apt-get %s\n" "$*" >> "$FIXTURE_ROOT/commands.log"
      [[ "$*" == "purge -y fail2ban" ]] || return 1
      (( ACTIVE == 0 )) || return 1
      PURGED=1
      return 0
    }
    sysctl(){ return 0; }
    run_step(){ local msg="$1"; shift; "$@"; }

    module_uninstall
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  local stop_line purge_line rc=0
  stop_line="$(grep -n '^systemctl stop fail2ban.service$' "$tmp/commands.log" | cut -d: -f1)"
  purge_line="$(grep -n '^apt-get purge -y fail2ban$' "$tmp/commands.log" | cut -d: -f1)"
  [[ -n "$stop_line" && -n "$purge_line" ]] || rc=1
  if [[ -n "$stop_line" && -n "$purge_line" ]]; then
    (( stop_line < purge_line )) || rc=1
  fi
  [[ ! -e "$tmp/state" ]] || rc=1
  [[ ! -e "$tmp/backups" ]] || rc=1
  [[ ! -e "$tmp/install" ]] || rc=1
  [[ ! -e "$tmp/bin/sso" ]] || rc=1
  [[ ! -e "$tmp/fail2ban/jail.d/sso.local" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

owned_fail2ban_stop_failure_aborts_before_purge() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_fixture "$tmp"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"; BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"; SSO_DIR="$FIXTURE_ROOT/install"
    SSO_SYSTEMD_DIR="$FIXTURE_ROOT/systemd"; SSO_SYSCTL_DIR="$FIXTURE_ROOT/sysctl"; SSO_MODULES_LOAD_DIR="$FIXTURE_ROOT/modules-load"
    SSO_LOCAL_SBIN_DIR="$FIXTURE_ROOT/sbin"; SSO_LOCAL_BIN_DIR="$FIXTURE_ROOT/bin"
    F2B_SSO_LOCAL="$FIXTURE_ROOT/fail2ban/jail.d/sso.local"; F2B_NGINX_MARKER="$STATE_DIR/fail2ban-nginx.enabled"
    source "$ROOT_DIR/modules/utils.sh"; source "$ROOT_DIR/modules/rollback.sh"; source "$ROOT_DIR/modules/uninstall.sh"
    header(){ :; }; section(){ :; }; info(){ :; }; warn(){ :; }; err(){ :; }; pause(){ :; }
    read_input(){ local -n out="$2"; out="y"; }
    backup_migrate_ownership_baselines(){ return 0; }
    backup_resource_baseline_dir(){ return 1; }
    uninstall_disable_sso_service(){ return 0; }
    remove_sso_firewall_runtime(){ return 0; }
    uninstall_cpu_runtime_owned(){ return 1; }
    systemd_load_state(){ [[ "$1" == "fail2ban.service" ]] && printf "loaded\n" || printf "not-found\n"; }
    systemctl() {
      printf "systemctl %s\n" "$*" >> "$FIXTURE_ROOT/commands.log"
      case "$1" in
        is-active) printf "active\n"; return 0 ;;
        stop) return 1 ;;
        *) return 0 ;;
      esac
    }
    apt-get(){ printf "apt-get %s\n" "$*" >> "$FIXTURE_ROOT/commands.log"; return 0; }
    run_step(){ local msg="$1"; shift; "$@"; }
    module_uninstall
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  local rc=0
  grep -q '^systemctl stop fail2ban.service$' "$tmp/commands.log" || rc=1
  if grep -q '^apt-get purge -y fail2ban$' "$tmp/commands.log"; then rc=1; fi
  [[ -f "$tmp/state/installed_fail2ban.marker" ]] || rc=1
  [[ -d "$tmp/backups" ]] || rc=1
  [[ -f "$tmp/install/sso.sh" ]] || rc=1
  [[ -f "$tmp/bin/sso" ]] || rc=1
  [[ -f "$tmp/fail2ban/jail.d/sso.local" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

owned_fail2ban_must_be_inactive_after_stop_before_purge() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_fixture "$tmp"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"; BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"; SSO_DIR="$FIXTURE_ROOT/install"
    SSO_SYSTEMD_DIR="$FIXTURE_ROOT/systemd"; SSO_SYSCTL_DIR="$FIXTURE_ROOT/sysctl"; SSO_MODULES_LOAD_DIR="$FIXTURE_ROOT/modules-load"
    SSO_LOCAL_SBIN_DIR="$FIXTURE_ROOT/sbin"; SSO_LOCAL_BIN_DIR="$FIXTURE_ROOT/bin"
    F2B_SSO_LOCAL="$FIXTURE_ROOT/fail2ban/jail.d/sso.local"; F2B_NGINX_MARKER="$STATE_DIR/fail2ban-nginx.enabled"
    source "$ROOT_DIR/modules/utils.sh"; source "$ROOT_DIR/modules/rollback.sh"; source "$ROOT_DIR/modules/uninstall.sh"
    header(){ :; }; section(){ :; }; info(){ :; }; warn(){ :; }; err(){ :; }; pause(){ :; }
    read_input(){ local -n out="$2"; out="y"; }
    backup_migrate_ownership_baselines(){ return 0; }
    backup_resource_baseline_dir(){ return 1; }
    uninstall_disable_sso_service(){ return 0; }
    remove_sso_firewall_runtime(){ return 0; }
    uninstall_cpu_runtime_owned(){ return 1; }
    systemd_load_state(){ [[ "$1" == "fail2ban.service" ]] && printf "loaded\n" || printf "not-found\n"; }
    systemctl() {
      printf "systemctl %s\n" "$*" >> "$FIXTURE_ROOT/commands.log"
      case "$1" in
        is-active) printf "active\n"; return 0 ;;
        stop) return 0 ;;
        *) return 0 ;;
      esac
    }
    apt-get(){ printf "apt-get %s\n" "$*" >> "$FIXTURE_ROOT/commands.log"; return 0; }
    run_step(){ local msg="$1"; shift; "$@"; }
    module_uninstall
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  local rc=0
  grep -q '^systemctl stop fail2ban.service$' "$tmp/commands.log" || rc=1
  if grep -q '^apt-get purge -y fail2ban$' "$tmp/commands.log"; then rc=1; fi
  [[ -f "$tmp/state/installed_fail2ban.marker" ]] || rc=1
  [[ -d "$tmp/backups" ]] || rc=1
  [[ -f "$tmp/install/sso.sh" ]] || rc=1
  [[ -f "$tmp/fail2ban/jail.d/sso.local" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

run_test "SSO-owned Fail2Ban is stopped before purge and full uninstall completes" owned_fail2ban_stops_before_purge_and_uninstall_finishes
run_test "Fail2Ban stop failure aborts before purge and preserves recovery evidence" owned_fail2ban_stop_failure_aborts_before_purge
run_test "Fail2Ban must verify inactive after stop before purge" owned_fail2ban_must_be_inactive_after_stop_before_purge
finish_tests
