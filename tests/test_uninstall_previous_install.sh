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
  : > "$tmp/state/recovery.marker"
  : > "$tmp/backups/recovery.marker"
  : > "$tmp/install/sso.sh"
  : > "$tmp/bin/sso"
  : > "$tmp/sysctl/operator.conf"
}

make_recognized_sso_payload() {
  local root="$1" rel
  mkdir -p "$root/modules" "$root/assets"
  for rel in \
    install.sh \
    sso.sh \
    modules/utils.sh \
    modules/network.sh \
    modules/cpu_irq.sh \
    modules/firewall.sh \
    modules/fail2ban.sh \
    modules/rollback.sh \
    modules/uninstall.sh \
    assets/whitelist-default.ipv4; do
    : > "$root/$rel"
  done
}

run_fixture_uninstall() {
  local tmp="$1"
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
    systemctl(){ [[ "$1" == "is-active" ]] && return 3; return 0; }
    run_step(){ return 0; }
    module_uninstall
  ' >/dev/null 2>&1
}

recognized_previous_install_is_removed_on_success() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_fixture "$tmp"
  make_recognized_sso_payload "$tmp/install.bak"

  run_fixture_uninstall "$tmp" || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ ! -e "$tmp/install.bak" ]] || rc=1
  [[ ! -e "$tmp/state" ]] || rc=1
  [[ ! -e "$tmp/backups" ]] || rc=1
  [[ ! -e "$tmp/install" ]] || rc=1
  [[ ! -e "$tmp/bin/sso" ]] || rc=1
  [[ -f "$tmp/sysctl/operator.conf" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

unrecognized_previous_install_blocks_destructive_completion() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_fixture "$tmp"
  mkdir -p "$tmp/install.bak"
  printf 'operator-data\n' > "$tmp/install.bak/operator.txt"

  run_fixture_uninstall "$tmp" || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ -f "$tmp/install.bak/operator.txt" ]] || rc=1
  [[ -f "$tmp/state/recovery.marker" ]] || rc=1
  [[ -f "$tmp/backups/recovery.marker" ]] || rc=1
  [[ -f "$tmp/install/sso.sh" ]] || rc=1
  [[ -f "$tmp/bin/sso" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

symlink_previous_install_blocks_destructive_completion() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_fixture "$tmp"
  mkdir -p "$tmp/operator-target"
  printf 'operator-data\n' > "$tmp/operator-target/keep"
  ln -s "$tmp/operator-target" "$tmp/install.bak"

  run_fixture_uninstall "$tmp" || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ -L "$tmp/install.bak" ]] || rc=1
  [[ -f "$tmp/operator-target/keep" ]] || rc=1
  [[ -f "$tmp/state/recovery.marker" ]] || rc=1
  [[ -f "$tmp/backups/recovery.marker" ]] || rc=1
  [[ -f "$tmp/install/sso.sh" ]] || rc=1
  [[ -f "$tmp/bin/sso" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

previous_install_remove_failure_preserves_recovery() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_fixture "$tmp"
  make_recognized_sso_payload "$tmp/install.bak"

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
    systemctl(){ [[ "$1" == "is-active" ]] && return 3; return 0; }
    run_step(){ return 0; }
    rm() {
      if [[ "$#" -eq 3 && "$1" == "-rf" && "$2" == "--" && "$3" == "${SSO_DIR}.bak" ]]; then
        return 71
      fi
      command rm "$@"
    }
    module_uninstall
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ -d "$tmp/install.bak" ]] || rc=1
  [[ -f "$tmp/state/recovery.marker" ]] || rc=1
  [[ -f "$tmp/backups/recovery.marker" ]] || rc=1
  [[ -f "$tmp/install/sso.sh" ]] || rc=1
  [[ -f "$tmp/bin/sso" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

run_test "recognized previous SSO install fallback is removed by full uninstall" recognized_previous_install_is_removed_on_success
run_test "unrecognized previous-install directory blocks destructive completion" unrecognized_previous_install_blocks_destructive_completion
run_test "symlink previous-install path blocks destructive completion" symlink_previous_install_blocks_destructive_completion
run_test "previous-install removal failure preserves recovery state" previous_install_remove_failure_preserves_recovery
finish_tests
