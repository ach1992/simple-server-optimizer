#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/testlib.sh"

backup_ids_do_not_collide_with_same_timestamp() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    BACKUP_DIR_BASE="$tmp"
    ts() { printf '20260825-120000\n'; }
    local_a="$(backup_create_dir)"
    local_b="$(backup_create_dir)"
    [[ "$local_a" != "$local_b" ]]
    [[ -d "$local_a" && -d "$local_b" ]]
    [[ "$(basename "$local_b")" == "20260825-120000-0001" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

file_state_capture_preserves_presence_absence_and_metadata() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/sysctl" "$tmp/modules-load" "$tmp/systemd" "$tmp/sbin" "$tmp/backup"
  printf 'old-qdisc\n' > "$tmp/sysctl/99-sso-qdisc.conf"
  chmod 0640 "$tmp/sysctl/99-sso-qdisc.conf"
  printf '#!/bin/sh\n' > "$tmp/sbin/sso-cpuirq-restore"
  chmod 0750 "$tmp/sbin/sso-cpuirq-restore"

  (
    set -Eeuo pipefail
    SSO_SYSCTL_DIR="$tmp/sysctl"
    SSO_MODULES_LOAD_DIR="$tmp/modules-load"
    SSO_SYSTEMD_DIR="$tmp/systemd"
    SSO_LOCAL_SBIN_DIR="$tmp/sbin"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    backup_capture_sysctl "$tmp/backup"
    backup_capture_cpu_irq "$tmp/backup"
  ) || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ "$(cat "$tmp/backup/sysctl/99-sso-qdisc.conf")" == "old-qdisc" ]] || rc=1
  [[ "$(stat -c '%a' "$tmp/backup/sysctl/99-sso-qdisc.conf")" == "640" ]] || rc=1
  [[ -f "$tmp/backup/sysctl/bbr.conf.absent" ]] || rc=1
  [[ -f "$tmp/backup/cpu_irq/sso-cpuirq.service.absent" ]] || rc=1
  [[ "$(stat -c '%a' "$tmp/backup/cpu_irq/sso-cpuirq-restore")" == "750" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

restore_file_state_restores_prior_presence_and_absence() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/captured" "$tmp/live"
  printf 'before\n' > "$tmp/captured/present"
  chmod 0600 "$tmp/captured/present"
  : > "$tmp/captured/absent.absent"
  printf 'after\n' > "$tmp/live/present"
  printf 'created-by-sso\n' > "$tmp/live/absent"

  (
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/rollback.sh"
    backup_restore_file_state "$tmp/captured/present" "$tmp/live/present"
    backup_restore_file_state "$tmp/captured/absent" "$tmp/live/absent"
  ) || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ "$(cat "$tmp/live/present")" == "before" ]] || rc=1
  [[ "$(stat -c '%a' "$tmp/live/present")" == "600" ]] || rc=1
  [[ ! -e "$tmp/live/absent" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

service_restore_preserves_disabled_inactive_state() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/backup/services/irqbalance.service"
  printf 'loaded\n' > "$tmp/backup/services/irqbalance.service/load"
  printf 'disabled\n' > "$tmp/backup/services/irqbalance.service/enabled"
  printf 'inactive\n' > "$tmp/backup/services/irqbalance.service/active"
  : > "$tmp/commands.log"

  (
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    systemctl() {
      printf '%s\n' "$*" >> "$tmp/commands.log"
      return 0
    }
    backup_restore_service_state "$tmp/backup" irqbalance.service 0
  ) || { rm -rf "$tmp"; return 1; }

  local rc=0
  grep -q '^disable irqbalance.service$' "$tmp/commands.log" || rc=1
  grep -q '^stop irqbalance.service$' "$tmp/commands.log" || rc=1
  if grep -Eq '^(enable|start|restart) irqbalance.service$' "$tmp/commands.log"; then rc=1; fi
  rm -rf "$tmp"
  return "$rc"
}

uninstall_removes_only_namespaced_owned_files() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/sysctl" "$tmp/systemd" "$tmp/sbin" "$tmp/bin"
  : > "$tmp/sysctl/99-sso-rps.conf"
  : > "$tmp/sysctl/operator.conf"
  : > "$tmp/systemd/sso-cpuirq.service"
  : > "$tmp/systemd/operator.service"
  : > "$tmp/sbin/sso-cpuirq-restore"
  : > "$tmp/sbin/operator-tool"
  : > "$tmp/bin/sso"
  : > "$tmp/bin/operator-tool"

  (
    set -Eeuo pipefail
    SSO_SYSCTL_DIR="$tmp/sysctl"
    SSO_SYSTEMD_DIR="$tmp/systemd"
    SSO_LOCAL_SBIN_DIR="$tmp/sbin"
    SSO_LOCAL_BIN_DIR="$tmp/bin"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    uninstall_remove_owned_persistence_files
    uninstall_remove_launcher
  ) || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ ! -e "$tmp/sysctl/99-sso-rps.conf" ]] || rc=1
  [[ ! -e "$tmp/systemd/sso-cpuirq.service" ]] || rc=1
  [[ ! -e "$tmp/sbin/sso-cpuirq-restore" ]] || rc=1
  [[ ! -e "$tmp/bin/sso" ]] || rc=1
  [[ -e "$tmp/sysctl/operator.conf" ]] || rc=1
  [[ -e "$tmp/systemd/operator.service" ]] || rc=1
  [[ -e "$tmp/sbin/operator-tool" ]] || rc=1
  [[ -e "$tmp/bin/operator-tool" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

uninstall_shared_bbr_uses_explicit_baseline() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/modules-load" "$tmp/baseline/sysctl" "$tmp/absent/sysctl"
  printf 'operator-before\n' > "$tmp/baseline/sysctl/bbr.conf"
  chmod 0640 "$tmp/baseline/sysctl/bbr.conf"
  : > "$tmp/absent/sysctl/bbr.conf.absent"
  printf 'sso-current\n' > "$tmp/modules-load/bbr.conf"

  (
    set -Eeuo pipefail
    SSO_MODULES_LOAD_DIR="$tmp/modules-load"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    uninstall_restore_shared_file_baseline "$tmp/baseline"
    [[ "$(cat "$tmp/modules-load/bbr.conf")" == "operator-before" ]]
    [[ "$(stat -c '%a' "$tmp/modules-load/bbr.conf")" == "640" ]]
    printf 'sso-again\n' > "$tmp/modules-load/bbr.conf"
    uninstall_restore_shared_file_baseline "$tmp/absent"
    [[ ! -e "$tmp/modules-load/bbr.conf" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

firewall_runtime_cleanup_is_namespaced() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  : > "$tmp/commands.log"

  (
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/rollback.sh"
    nft() {
      printf 'nft %s\n' "$*" >> "$tmp/commands.log"
      case "$*" in
        'list table inet sso') return 1 ;;
        'list table ip sso') return 1 ;;
      esac
      return 0
    }
    iptables() {
      printf 'iptables %s\n' "$*" >> "$tmp/commands.log"
      case "$1" in
        -C|-S) return 1 ;;
      esac
      return 0
    }
    ipset() {
      printf 'ipset %s\n' "$*" >> "$tmp/commands.log"
      [[ "$1" == "list" ]] && return 1
      return 0
    }
    remove_sso_firewall_runtime
  ) || { rm -rf "$tmp"; return 1; }

  local rc=0
  if grep -Ev 'sso|SSO_(IN|OUT)' "$tmp/commands.log" | grep -q .; then rc=1; fi
  rm -rf "$tmp"
  return "$rc"
}


network_runtime_restore_uses_captured_supported_values() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/backup/net"
  printf 'fq_codel\n' > "$tmp/backup/net/net.core.default_qdisc"
  printf 'cubic\n' > "$tmp/backup/net/net.ipv4.tcp_congestion_control"
  : > "$tmp/commands.log"

  (
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/rollback.sh"
    warn() { :; }
    sysctl() {
      printf '%s\n' "$*" >> "$tmp/commands.log"
      return 0
    }
    backup_restore_network_runtime "$tmp/backup"
  ) || { rm -rf "$tmp"; return 1; }

  local rc=0
  grep -q '^-w net.core.default_qdisc=fq_codel$' "$tmp/commands.log" || rc=1
  grep -q '^-w net.ipv4.tcp_congestion_control=cubic$' "$tmp/commands.log" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

uninstall_firewall_failure_preserves_recovery_state() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/state" "$tmp/backups" "$tmp/install"
  : > "$tmp/state/recovery.marker"
  : > "$tmp/install/sso.sh"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"
    SSO_DIR="$FIXTURE_ROOT/install"
    SSO_SYSTEMD_DIR="$FIXTURE_ROOT/systemd"
    SSO_SYSCTL_DIR="$FIXTURE_ROOT/sysctl"
    SSO_MODULES_LOAD_DIR="$FIXTURE_ROOT/modules-load"
    SSO_LOCAL_SBIN_DIR="$FIXTURE_ROOT/sbin"
    SSO_LOCAL_BIN_DIR="$FIXTURE_ROOT/bin"
    mkdir -p "$SSO_SYSTEMD_DIR" "$SSO_SYSCTL_DIR" "$SSO_MODULES_LOAD_DIR" "$SSO_LOCAL_SBIN_DIR" "$SSO_LOCAL_BIN_DIR"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    header() { :; }
    section() { :; }
    info() { :; }
    warn() { :; }
    err() { :; }
    pause() { :; }
    read_input() { local -n out="$2"; out="y"; }
    uninstall_disable_sso_service() { return 0; }
    remove_sso_firewall_runtime() { return 1; }
    module_uninstall
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ -f "$tmp/state/recovery.marker" ]] || rc=1
  [[ -f "$tmp/install/sso.sh" ]] || rc=1
  [[ -d "$tmp/backups" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

uninstall_package_purge_failure_preserves_ownership_evidence() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/state" "$tmp/backups" "$tmp/install" "$tmp/fail2ban/jail.d"
  : > "$tmp/state/installed_fail2ban.marker"
  : > "$tmp/install/sso.sh"
  printf '[sshd]\nenabled = true\n' > "$tmp/fail2ban/jail.d/sso.local"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"
    SSO_DIR="$FIXTURE_ROOT/install"
    SSO_SYSTEMD_DIR="$FIXTURE_ROOT/systemd"
    SSO_SYSCTL_DIR="$FIXTURE_ROOT/sysctl"
    SSO_MODULES_LOAD_DIR="$FIXTURE_ROOT/modules-load"
    SSO_LOCAL_SBIN_DIR="$FIXTURE_ROOT/sbin"
    SSO_LOCAL_BIN_DIR="$FIXTURE_ROOT/bin"
    F2B_SSO_LOCAL="$FIXTURE_ROOT/fail2ban/jail.d/sso.local"
    F2B_NGINX_MARKER="$STATE_DIR/fail2ban-nginx.enabled"
    mkdir -p "$SSO_SYSTEMD_DIR" "$SSO_SYSCTL_DIR" "$SSO_MODULES_LOAD_DIR" "$SSO_LOCAL_SBIN_DIR" "$SSO_LOCAL_BIN_DIR"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    header() { :; }
    section() { :; }
    info() { :; }
    warn() { :; }
    err() { :; }
    pause() { :; }
    read_input() { local -n out="$2"; out="y"; }
    uninstall_disable_sso_service() { return 0; }
    remove_sso_firewall_runtime() { return 0; }
    run_step() {
      [[ "$1" == "Removing Fail2Ban (purge)" ]] && return 1
      return 0
    }
    module_uninstall
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ -f "$tmp/state/installed_fail2ban.marker" ]] || rc=1
  [[ -f "$tmp/fail2ban/jail.d/sso.local" ]] || rc=1
  [[ -f "$tmp/install/sso.sh" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

full_uninstall_removes_sso_artifacts_after_verified_cleanup() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/state" "$tmp/backups" "$tmp/install" "$tmp/systemd" "$tmp/sysctl" "$tmp/modules-load" "$tmp/sbin" "$tmp/bin" "$tmp/fail2ban/jail.d"
  : > "$tmp/install/sso.sh"
  : > "$tmp/systemd/sso-firewall.service"
  : > "$tmp/systemd/sso-cpuirq.service"
  : > "$tmp/sysctl/99-sso-rps.conf"
  : > "$tmp/sbin/sso-firewall-restore"
  : > "$tmp/sbin/sso-cpuirq-restore"
  : > "$tmp/bin/sso"
  : > "$tmp/sysctl/operator.conf"
  : > "$tmp/bin/operator-tool"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"
    SSO_DIR="$FIXTURE_ROOT/install"
    SSO_SYSTEMD_DIR="$FIXTURE_ROOT/systemd"
    SSO_SYSCTL_DIR="$FIXTURE_ROOT/sysctl"
    SSO_MODULES_LOAD_DIR="$FIXTURE_ROOT/modules-load"
    SSO_LOCAL_SBIN_DIR="$FIXTURE_ROOT/sbin"
    SSO_LOCAL_BIN_DIR="$FIXTURE_ROOT/bin"
    F2B_SSO_LOCAL="$FIXTURE_ROOT/fail2ban/jail.d/sso.local"
    F2B_NGINX_MARKER="$STATE_DIR/fail2ban-nginx.enabled"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    header() { :; }
    section() { :; }
    info() { :; }
    warn() { :; }
    err() { :; }
    pause() { :; }
    read_input() { local -n out="$2"; out="y"; }
    uninstall_disable_sso_service() { return 0; }
    remove_sso_firewall_runtime() { return 0; }
    cmd_exists() { return 1; }
    run_step() { return 0; }
    module_uninstall
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ ! -e "$tmp/state" ]] || rc=1
  [[ ! -e "$tmp/backups" ]] || rc=1
  [[ ! -e "$tmp/install" ]] || rc=1
  [[ ! -e "$tmp/systemd/sso-firewall.service" ]] || rc=1
  [[ ! -e "$tmp/systemd/sso-cpuirq.service" ]] || rc=1
  [[ ! -e "$tmp/sysctl/99-sso-rps.conf" ]] || rc=1
  [[ ! -e "$tmp/sbin/sso-firewall-restore" ]] || rc=1
  [[ ! -e "$tmp/sbin/sso-cpuirq-restore" ]] || rc=1
  [[ ! -e "$tmp/bin/sso" ]] || rc=1
  [[ -e "$tmp/sysctl/operator.conf" ]] || rc=1
  [[ -e "$tmp/bin/operator-tool" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

run_test "backup IDs are collision-resistant within one second" backup_ids_do_not_collide_with_same_timestamp
run_test "backup captures file presence, absence, and metadata" file_state_capture_preserves_presence_absence_and_metadata
run_test "file restore handles prior presence and prior absence" restore_file_state_restores_prior_presence_and_absence
run_test "service restore preserves disabled/inactive lifecycle" service_restore_preserves_disabled_inactive_state
run_test "captured fq/BBR runtime values are restored through supported sysctls" network_runtime_restore_uses_captured_supported_values
run_test "uninstall removes launcher/CPU artifacts but preserves unrelated files" uninstall_removes_only_namespaced_owned_files
run_test "uninstall restores or removes shared bbr.conf from explicit baseline" uninstall_shared_bbr_uses_explicit_baseline
run_test "firewall runtime cleanup is limited to SSO namespaces" firewall_runtime_cleanup_is_namespaced
run_test "firewall cleanup failure preserves recovery state" uninstall_firewall_failure_preserves_recovery_state
run_test "package purge failure preserves ownership evidence" uninstall_package_purge_failure_preserves_ownership_evidence
run_test "verified uninstall removes SSO artifacts and preserves unrelated files" full_uninstall_removes_sso_artifacts_after_verified_cleanup
finish_tests
