#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

make_cpu_runtime_snapshot() {
  local d="$1"
  mkdir -p \
    "$d/cpu_irq/runtime/queues/rx-0" \
    "$d/cpu_irq/runtime/queues/tx-0" \
    "$d/cpu_irq" \
    "$d/sysctl" \
    "$d/services/sso-cpuirq.service"
  printf 'cpu_irq:rps_rfs_xps\n' > "$d/TAG"
  printf '2\n' > "$d/FORMAT"
  : > "$d/COMPLETE"
  : > "$d/cpu_irq/runtime/COMPLETE"
  printf 'test0\n' > "$d/cpu_irq/runtime/nic"
  printf '0\n' > "$d/cpu_irq/runtime/rps_sock_flow_entries"
  printf '0\n' > "$d/cpu_irq/runtime/queues/rx-0/rps_cpus"
  printf '0\n' > "$d/cpu_irq/runtime/queues/rx-0/rps_flow_cnt"
  printf '1\n' > "$d/cpu_irq/runtime/queues/tx-0/xps_cpus"
  : > "$d/sysctl/99-sso-rps.conf.absent"
  : > "$d/cpu_irq/sso-cpuirq.service.absent"
  : > "$d/cpu_irq/sso-cpuirq-restore.absent"
  printf 'not-found\n' > "$d/services/sso-cpuirq.service/load"
  printf 'not-found\n' > "$d/services/sso-cpuirq.service/enabled"
  printf 'inactive\n' > "$d/services/sso-cpuirq.service/active"
}

real_rps_payload_is_detected_but_empty_placeholders_are_not() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/sysctl" "$tmp/systemd" "$tmp/sbin"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    SSO_SYSCTL_DIR="$FIXTURE_ROOT/sysctl"
    SSO_SYSTEMD_DIR="$FIXTURE_ROOT/systemd"
    SSO_LOCAL_SBIN_DIR="$FIXTURE_ROOT/sbin"
    source "$ROOT_DIR/modules/uninstall.sh"

    : > "$SSO_SYSCTL_DIR/99-sso-rps.conf"
    : > "$SSO_SYSTEMD_DIR/sso-cpuirq.service"
    : > "$SSO_LOCAL_SBIN_DIR/sso-cpuirq-restore"
    if uninstall_cpu_runtime_owned; then exit 1; fi

    printf "# SSO: RPS/RFS global settings\nnet.core.rps_sock_flow_entries=65536\n" > "$SSO_SYSCTL_DIR/99-sso-rps.conf"
    uninstall_cpu_runtime_owned

    rm -f "$SSO_SYSCTL_DIR/99-sso-rps.conf"
    printf "[Unit]\nDescription=SSO CPU/IRQ tuning (RPS/RFS/XPS)\n" > "$SSO_SYSTEMD_DIR/sso-cpuirq.service"
    uninstall_cpu_runtime_owned
  '
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

explicit_preownership_cpu_snapshot_is_accepted() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_cpu_runtime_snapshot "$tmp/backup"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    uninstall_cpu_runtime_snapshot_is_preownership "$FIXTURE_ROOT/backup"
  '
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

postownership_or_ambiguous_snapshot_is_rejected() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_cpu_runtime_snapshot "$tmp/backup"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    source "$ROOT_DIR/modules/uninstall.sh"

    rm -f "$FIXTURE_ROOT/backup/sysctl/99-sso-rps.conf.absent"
    if uninstall_cpu_runtime_snapshot_is_preownership "$FIXTURE_ROOT/backup"; then exit 1; fi

    : > "$FIXTURE_ROOT/backup/sysctl/99-sso-rps.conf.absent"
    printf "loaded\n" > "$FIXTURE_ROOT/backup/services/sso-cpuirq.service/load"
    if uninstall_cpu_runtime_snapshot_is_preownership "$FIXTURE_ROOT/backup"; then exit 1; fi
  '
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

baseline_finder_returns_only_proven_first_rps_snapshot() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/backups" "$tmp/install.bak/backups"
  make_cpu_runtime_snapshot "$tmp/backups/20260828-120000"
  make_cpu_runtime_snapshot "$tmp/backups/20260828-130000"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"
    SSO_DIR="$FIXTURE_ROOT/install"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    found="$(uninstall_find_cpu_runtime_baseline)"
    [[ "$found" == "$BACKUP_DIR_BASE/20260828-120000" ]]
  '
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

missing_cpu_runtime_baseline_stops_before_recovery_deletion() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/state" "$tmp/backups" "$tmp/install" "$tmp/sysctl" "$tmp/systemd" "$tmp/sbin"
  : > "$tmp/install/sso.sh"
  printf '# SSO: RPS/RFS global settings\nnet.core.rps_sock_flow_entries=65536\n' > "$tmp/sysctl/99-sso-rps.conf"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"
    SSO_DIR="$FIXTURE_ROOT/install"
    SSO_SYSCTL_DIR="$FIXTURE_ROOT/sysctl"
    SSO_SYSTEMD_DIR="$FIXTURE_ROOT/systemd"
    SSO_LOCAL_SBIN_DIR="$FIXTURE_ROOT/sbin"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    header(){ :; }; section(){ :; }; info(){ :; }; warn(){ :; }; err(){ :; }; pause(){ :; }
    read_input(){ local -n out="$2"; out="y"; }
    backup_migrate_ownership_baselines(){ return 0; }
    backup_resource_baseline_dir(){ return 1; }
    uninstall_abort_with_recovery(){ printf "%s\n" "$1" > "$FIXTURE_ROOT/abort"; }

    module_uninstall

    [[ -d "$STATE_DIR" ]]
    [[ -d "$BACKUP_DIR_BASE" ]]
    [[ -d "$SSO_DIR" ]]
    [[ -f "$SSO_SYSCTL_DIR/99-sso-rps.conf" ]]
    grep -q "pre-SSO RPS/RFS/XPS runtime baseline" "$FIXTURE_ROOT/abort"
  '
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

run_test "real RPS payload is detected while empty placeholders are ignored" real_rps_payload_is_detected_but_empty_placeholders_are_not
run_test "explicit pre-ownership CPU runtime snapshot is accepted" explicit_preownership_cpu_snapshot_is_accepted
run_test "ambiguous or post-ownership CPU runtime snapshot is rejected" postownership_or_ambiguous_snapshot_is_rejected
run_test "CPU runtime baseline finder selects the proven first RPS snapshot" baseline_finder_returns_only_proven_first_rps_snapshot
run_test "missing CPU runtime baseline preserves recovery state" missing_cpu_runtime_baseline_stops_before_recovery_deletion
finish_tests
