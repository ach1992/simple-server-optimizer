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
}

test_immediate_and_restore_rfs_value_match() {
  local file="$ROOT_DIR/modules/cpu_irq.sh"
  [[ "$(grep -c '^RPS_FLOW_CNT=16384$' "$file")" -eq 2 ]] || return 1
  if grep -q 'rps_flow_cnt.*4096\|echo 4096' "$file"; then
    return 1
  fi
}

test_queue_write_failures_are_not_silently_ignored() {
  local file="$ROOT_DIR/modules/cpu_irq.sh"
  grep -q 'RPS: one or more queue writes were rejected' "$file" || return 1
  grep -q 'RFS: one or more queue writes were rejected' "$file" || return 1
  grep -q 'only partially applied' "$file" || return 1
}

run_test "CPU masks use Linux cpumask grouping across 32-bit boundaries" test_cpu_mask_format
run_test "immediate and reboot restore use the same RFS queue value" test_immediate_and_restore_rfs_value_match
run_test "queue write failures are reported as partial application" test_queue_write_failures_are_not_silently_ignored
finish_tests
