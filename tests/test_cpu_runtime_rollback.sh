#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/testlib.sh"
source "$ROOT_DIR/modules/rollback.sh"
source "$ROOT_DIR/modules/cpu_irq.sh"

setup_tree(){ local root="$1"; mkdir -p "$root/net/test0/queues/rx-0" "$root/net/test0/queues/tx-0" "$root/backup"; printf '0\n' > "$root/net/test0/queues/rx-0/rps_cpus"; printf '0\n' > "$root/net/test0/queues/rx-0/rps_flow_cnt"; printf '1\n' > "$root/net/test0/queues/tx-0/xps_cpus"; }
certify(){ printf '2\n' > "$1/FORMAT"; : > "$1/COMPLETE"; }

full_round_trip(){
  local tmp; tmp="$(mktemp -d)"; setup_tree "$tmp"; printf 'rx-0/rps_cpus\nrx-0/rps_flow_cnt\ntx-0/xps_cpus\n' > "$tmp/inv"
  local rc=0
  ( SSO_SYS_CLASS_NET_DIR="$tmp/net"; CPU_IRQ_MANAGED_INVENTORY_FILE="$tmp/inv"; RPS_GLOBAL=0; detect_nic(){ echo test0; }; warn(){ :; }; sysctl(){ case "$1" in -n) echo "$RPS_GLOBAL";; -w) RPS_GLOBAL="${2#*=}";; *) return 1;; esac; }; backup_capture_cpu_runtime "$tmp/backup"; certify "$tmp/backup"; printf '3\n' > "$tmp/net/test0/queues/rx-0/rps_cpus"; printf '16384\n' > "$tmp/net/test0/queues/rx-0/rps_flow_cnt"; printf '3\n' > "$tmp/net/test0/queues/tx-0/xps_cpus"; RPS_GLOBAL=65536; backup_restore_cpu_runtime "$tmp/backup"; [[ "$RPS_GLOBAL" == 0 ]]; [[ "$(cat "$tmp/net/test0/queues/tx-0/xps_cpus")" == 1 ]] ) || rc=$?
  rm -rf "$tmp"; return "$rc"
}

partial_ignores_unmanaged_unreadable_xps(){
  local tmp; tmp="$(mktemp -d)"; setup_tree "$tmp"; rm -f "$tmp/net/test0/queues/tx-0/xps_cpus"; mkdir "$tmp/net/test0/queues/tx-0/xps_cpus"; printf 'rx-0/rps_cpus\nrx-0/rps_flow_cnt\n' > "$tmp/inv"
  local rc=0
  ( SSO_SYS_CLASS_NET_DIR="$tmp/net"; CPU_IRQ_MANAGED_INVENTORY_FILE="$tmp/inv"; RPS_GLOBAL=0; detect_nic(){ echo test0; }; warn(){ :; }; sysctl(){ case "$1" in -n) echo "$RPS_GLOBAL";; -w) RPS_GLOBAL="${2#*=}";; *) return 1;; esac; }; backup_capture_cpu_runtime "$tmp/backup"; certify "$tmp/backup"; printf '3\n' > "$tmp/net/test0/queues/rx-0/rps_cpus"; printf '16384\n' > "$tmp/net/test0/queues/rx-0/rps_flow_cnt"; RPS_GLOBAL=65536; backup_restore_cpu_runtime "$tmp/backup"; [[ "$(cat "$tmp/net/test0/queues/rx-0/rps_cpus")" == 0 ]]; [[ -d "$tmp/net/test0/queues/tx-0/xps_cpus" ]] ) || rc=$?
  rm -rf "$tmp"; return "$rc"
}

rps_only_restore_does_not_touch_unmanaged_global(){
  local tmp; tmp="$(mktemp -d)"; setup_tree "$tmp"; printf 'rx-0/rps_cpus\n' > "$tmp/inv"
  local rc=0
  ( SSO_SYS_CLASS_NET_DIR="$tmp/net"; CPU_IRQ_MANAGED_INVENTORY_FILE="$tmp/inv"; RPS_GLOBAL=5; detect_nic(){ echo test0; }; warn(){ :; }; sysctl(){ case "$1" in -n) echo "$RPS_GLOBAL";; -w) RPS_GLOBAL="${2#*=}";; *) return 1;; esac; }; backup_capture_cpu_runtime "$tmp/backup"; certify "$tmp/backup"; printf '3\n' > "$tmp/net/test0/queues/rx-0/rps_cpus"; RPS_GLOBAL=777; backup_restore_cpu_runtime "$tmp/backup"; [[ "$RPS_GLOBAL" == 777 ]]; [[ "$(cat "$tmp/net/test0/queues/rx-0/rps_cpus")" == 0 ]] ) || rc=$?
  rm -rf "$tmp"; return "$rc"
}

missing_managed_target_fails_before_write(){
  local tmp; tmp="$(mktemp -d)"; setup_tree "$tmp"; printf 'rx-0/rps_cpus\nrx-0/rps_flow_cnt\n' > "$tmp/inv"
  local rc=0
  ( SSO_SYS_CLASS_NET_DIR="$tmp/net"; CPU_IRQ_MANAGED_INVENTORY_FILE="$tmp/inv"; RPS_GLOBAL=0; detect_nic(){ echo test0; }; warn(){ :; }; sysctl(){ case "$1" in -n) echo "$RPS_GLOBAL";; -w) RPS_GLOBAL="${2#*=}";; *) return 1;; esac; }; backup_capture_cpu_runtime "$tmp/backup"; certify "$tmp/backup"; rm -f "$tmp/net/test0/queues/rx-0/rps_flow_cnt"; printf '3\n' > "$tmp/net/test0/queues/rx-0/rps_cpus"; RPS_GLOBAL=65536; x=0; backup_restore_cpu_runtime "$tmp/backup" || x=$?; [[ "$x" == 1 ]]; [[ "$RPS_GLOBAL" == 65536 ]]; [[ "$(cat "$tmp/net/test0/queues/rx-0/rps_cpus")" == 3 ]] ) || rc=$?
  rm -rf "$tmp"; return "$rc"
}

corrupt_snapshot_symlink_fails_before_write(){
  local tmp; tmp="$(mktemp -d)"; setup_tree "$tmp"; printf 'rx-0/rps_cpus\nrx-0/rps_flow_cnt\n' > "$tmp/inv"
  local rc=0
  ( SSO_SYS_CLASS_NET_DIR="$tmp/net"; CPU_IRQ_MANAGED_INVENTORY_FILE="$tmp/inv"; RPS_GLOBAL=0; detect_nic(){ echo test0; }; warn(){ :; }; sysctl(){ case "$1" in -n) echo "$RPS_GLOBAL";; -w) RPS_GLOBAL="${2#*=}";; *) return 1;; esac; }; backup_capture_cpu_runtime "$tmp/backup"; certify "$tmp/backup"; rm -f "$tmp/backup/cpu_irq/runtime/queues/rx-0/rps_cpus"; ln -s /dev/null "$tmp/backup/cpu_irq/runtime/queues/rx-0/rps_cpus"; printf '3\n' > "$tmp/net/test0/queues/rx-0/rps_cpus"; RPS_GLOBAL=65536; x=0; backup_restore_cpu_runtime "$tmp/backup" || x=$?; [[ "$x" == 1 ]]; [[ "$RPS_GLOBAL" == 65536 ]]; [[ "$(cat "$tmp/net/test0/queues/rx-0/rps_cpus")" == 3 ]] ) || rc=$?
  rm -rf "$tmp"; return "$rc"
}

extra_unmanaged_queue_allowed_for_new_snapshot(){
  local tmp; tmp="$(mktemp -d)"; setup_tree "$tmp"; printf 'rx-0/rps_cpus\nrx-0/rps_flow_cnt\n' > "$tmp/inv"
  local rc=0
  ( SSO_SYS_CLASS_NET_DIR="$tmp/net"; CPU_IRQ_MANAGED_INVENTORY_FILE="$tmp/inv"; RPS_GLOBAL=0; detect_nic(){ echo test0; }; warn(){ :; }; sysctl(){ case "$1" in -n) echo "$RPS_GLOBAL";; -w) RPS_GLOBAL="${2#*=}";; *) return 1;; esac; }; backup_capture_cpu_runtime "$tmp/backup"; certify "$tmp/backup"; mkdir -p "$tmp/net/test0/queues/rx-1"; printf '7\n' > "$tmp/net/test0/queues/rx-1/rps_cpus"; printf '3\n' > "$tmp/net/test0/queues/rx-0/rps_cpus"; RPS_GLOBAL=65536; backup_restore_cpu_runtime "$tmp/backup"; [[ "$(cat "$tmp/net/test0/queues/rx-0/rps_cpus")" == 0 ]]; [[ "$(cat "$tmp/net/test0/queues/rx-1/rps_cpus")" == 7 ]] ) || rc=$?
  rm -rf "$tmp"; return "$rc"
}

legacy_snapshot_keeps_strict_topology(){
  local tmp; tmp="$(mktemp -d)"; setup_tree "$tmp"; printf 'rx-0/rps_cpus\nrx-0/rps_flow_cnt\ntx-0/xps_cpus\n' > "$tmp/inv"
  local rc=0
  ( SSO_SYS_CLASS_NET_DIR="$tmp/net"; CPU_IRQ_MANAGED_INVENTORY_FILE="$tmp/inv"; RPS_GLOBAL=0; detect_nic(){ echo test0; }; warn(){ :; }; sysctl(){ case "$1" in -n) echo "$RPS_GLOBAL";; -w) RPS_GLOBAL="${2#*=}";; *) return 1;; esac; }; backup_capture_cpu_runtime "$tmp/backup"; certify "$tmp/backup"; rm -f "$tmp/backup/cpu_irq/runtime/managed-queues"; mkdir -p "$tmp/net/test0/queues/rx-1"; printf '7\n' > "$tmp/net/test0/queues/rx-1/rps_cpus"; printf '3\n' > "$tmp/net/test0/queues/rx-0/rps_cpus"; RPS_GLOBAL=65536; x=0; backup_restore_cpu_runtime "$tmp/backup" || x=$?; [[ "$x" == 1 ]]; [[ "$RPS_GLOBAL" == 65536 ]]; [[ "$(cat "$tmp/net/test0/queues/rx-0/rps_cpus")" == 3 ]] ) || rc=$?
  rm -rf "$tmp"; return "$rc"
}

missing_complete_returns_two(){ local tmp; tmp="$(mktemp -d)"; mkdir -p "$tmp/cpu_irq/runtime"; local x=0; backup_restore_cpu_runtime "$tmp" || x=$?; rm -rf "$tmp"; [[ "$x" == 2 ]]; }

run_test "full RPS/RFS/XPS runtime values round-trip" full_round_trip
run_test "partial snapshot ignores unmanaged unreadable XPS" partial_ignores_unmanaged_unreadable_xps
run_test "RPS-only restore leaves unmanaged global RFS state untouched" rps_only_restore_does_not_touch_unmanaged_global
run_test "missing managed target fails before writes" missing_managed_target_fails_before_write
run_test "corrupt captured symlink fails before runtime writes" corrupt_snapshot_symlink_fails_before_write
run_test "new partial snapshot ignores extra unmanaged queues" extra_unmanaged_queue_allowed_for_new_snapshot
run_test "legacy snapshot keeps strict topology guard" legacy_snapshot_keeps_strict_topology
run_test "runtime restore requires COMPLETE marker" missing_complete_returns_two
finish_tests
