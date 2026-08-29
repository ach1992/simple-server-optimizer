#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/testlib.sh"
source "$ROOT_DIR/modules/cpu_irq.sh"

test_cpu_mask_format() {
  [[ "$(hex_mask_all_cpus 1)" == "1" ]] || return 1
  [[ "$(hex_mask_all_cpus 32)" == "ffffffff" ]] || return 1
  [[ "$(hex_mask_all_cpus 33)" == "1,ffffffff" ]] || return 1
  [[ "$(hex_mask_all_cpus 64)" == "ffffffff,ffffffff" ]] || return 1
  [[ "$(hex_mask_all_cpus 65)" == "1,ffffffff,ffffffff" ]] || return 1
  [[ "$(hex_mask_all_cpus 96)" == "ffffffff,ffffffff,ffffffff" ]] || return 1
  [[ "$(hex_mask_all_cpus 97)" == "1,ffffffff,ffffffff,ffffffff" ]] || return 1
}

test_cpu_mask_has_no_python_dependency() {
  local file="$ROOT_DIR/modules/cpu_irq.sh"
  if grep -Eq 'python3|python[[:space:]]+-' "$file"; then
    return 1
  fi
}

test_restore_reuses_module_constants_and_mask_logic() {
  local file="$ROOT_DIR/modules/cpu_irq.sh"
  [[ "$(grep -c '^RPS_FLOW_CNT=16384$' "$file")" -eq 1 ]] || return 1
  [[ "$(grep -c '^RPS_SOCK_FLOW_ENTRIES=65536$' "$file")" -eq 1 ]] || return 1
  grep -Fq 'source "$INSTALL_DIR/modules/cpu_irq.sh"' "$file" || return 1
  if grep -q 'rps_flow_cnt.*4096\|echo 4096' "$file"; then
    return 1
  fi
}

test_queue_write_failures_are_not_silently_ignored() {
  local file="$ROOT_DIR/modules/cpu_irq.sh"
  grep -q 'RPS: one or more queue writes were rejected' "$file" || return 1
  grep -q 'RFS: one or more queue writes were rejected' "$file" || return 1
  grep -q 'only partially applied' "$file" || return 1
  grep -q 'reboot persistence is not confirmed' "$file" || return 1
}

test_unreadable_queue_state_fails_preflight() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p \
    "$tmp/test0/queues/rx-0" \
    "$tmp/test0/queues/tx-0/xps_cpus"
  printf '00\n' > "$tmp/test0/queues/rx-0/rps_cpus"
  printf '0\n' > "$tmp/test0/queues/rx-0/rps_flow_cnt"

  local rc=0
  (
    SSO_SYS_CLASS_NET_DIR="$tmp"
    err(){ :; }
    warn(){ :; }
    cpu_irq_preflight_queue_snapshot test0
  ) || rc=$?

  rm -rf "$tmp"
  [[ "$rc" -ne 0 ]]
}

test_readable_queue_state_passes_preflight() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p \
    "$tmp/test0/queues/rx-0" \
    "$tmp/test0/queues/tx-0"
  printf '00\n' > "$tmp/test0/queues/rx-0/rps_cpus"
  printf '0\n' > "$tmp/test0/queues/rx-0/rps_flow_cnt"
  printf '00\n' > "$tmp/test0/queues/tx-0/xps_cpus"

  local rc=0
  (
    SSO_SYS_CLASS_NET_DIR="$tmp"
    err(){ :; }
    warn(){ :; }
    cpu_irq_preflight_queue_snapshot test0
  ) || rc=$?

  rm -rf "$tmp"
  [[ "$rc" -eq 0 ]]
}

test_rps_backup_failure_is_handled_in_menu_flow() {
  local file="$ROOT_DIR/modules/cpu_irq.sh"
  grep -Fq 'if ! d="$(backup_create "cpu_irq:rps_rfs_xps")"; then' "$file" || return 1
  grep -Fq 'Could not create a complete pre-change backup.' "$file" || return 1
  grep -Fq 'No RPS/RFS/XPS settings were changed.' "$file" || return 1
}

run_test "CPU masks use Linux cpumask grouping across 32-bit boundaries" test_cpu_mask_format
run_test "CPU mask rendering has no hidden Python dependency" test_cpu_mask_has_no_python_dependency
run_test "reboot restore reuses the same CPU/RFS constants and mask logic" test_restore_reuses_module_constants_and_mask_logic
run_test "queue and persistence failures are reported as partial application" test_queue_write_failures_are_not_silently_ignored
run_test "unreadable queue state fails the pre-mutation CPU snapshot preflight" test_unreadable_queue_state_fails_preflight
run_test "readable queue state passes the pre-mutation CPU snapshot preflight" test_readable_queue_state_passes_preflight
run_test "RPS backup failure is handled without terminating the menu flow" test_rps_backup_failure_is_handled_in_menu_flow
finish_tests
