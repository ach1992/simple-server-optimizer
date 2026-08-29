#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/testlib.sh"
source "$ROOT_DIR/modules/cpu_irq.sh"

test_cpu_mask_format(){
  [[ "$(hex_mask_all_cpus 1)" == "1" ]] && [[ "$(hex_mask_all_cpus 32)" == "ffffffff" ]] \
    && [[ "$(hex_mask_all_cpus 33)" == "1,ffffffff" ]] && [[ "$(hex_mask_all_cpus 64)" == "ffffffff,ffffffff" ]] \
    && [[ "$(hex_mask_all_cpus 65)" == "1,ffffffff,ffffffff" ]]
}
test_no_python(){ ! grep -Eq 'python3|python[[:space:]]+-' "$ROOT_DIR/modules/cpu_irq.sh"; }
test_constants_and_helper(){ grep -q '^RPS_FLOW_CNT=16384$' "$ROOT_DIR/modules/cpu_irq.sh" && grep -q '^RPS_SOCK_FLOW_ENTRIES=65536$' "$ROOT_DIR/modules/cpu_irq.sh" && grep -Fq 'source "$INSTALL_DIR/modules/cpu_irq.sh"' "$ROOT_DIR/modules/cpu_irq.sh"; }
test_failures_visible(){ grep -q 'managed queue writes were rejected' "$ROOT_DIR/modules/cpu_irq.sh" && grep -q 'reboot persistence is not confirmed' "$ROOT_DIR/modules/cpu_irq.sh"; }

test_unreadable_xps_is_skipped(){
  local tmp inv; tmp="$(mktemp -d)"; inv="$tmp/inv"
  mkdir -p "$tmp/test0/queues/rx-0" "$tmp/test0/queues/tx-0/xps_cpus"
  printf '00\n' > "$tmp/test0/queues/rx-0/rps_cpus"; printf '0\n' > "$tmp/test0/queues/rx-0/rps_flow_cnt"
  ( SSO_SYS_CLASS_NET_DIR="$tmp"; info(){ :; }; warn(){ :; }; err(){ :; }; cpu_irq_build_managed_inventory test0 "$inv"; grep -Fxq 'rx-0/rps_cpus' "$inv"; grep -Fxq 'rx-0/rps_flow_cnt' "$inv"; ! grep -q xps_cpus "$inv" )
  local rc=$?; rm -rf "$tmp"; return "$rc"
}

test_all_readable_are_managed(){
  local tmp inv; tmp="$(mktemp -d)"; inv="$tmp/inv"
  mkdir -p "$tmp/test0/queues/rx-0" "$tmp/test0/queues/tx-0"
  printf '00\n' > "$tmp/test0/queues/rx-0/rps_cpus"; printf '0\n' > "$tmp/test0/queues/rx-0/rps_flow_cnt"; printf '00\n' > "$tmp/test0/queues/tx-0/xps_cpus"
  ( SSO_SYS_CLASS_NET_DIR="$tmp"; info(){ :; }; warn(){ :; }; err(){ :; }; cpu_irq_build_managed_inventory test0 "$inv"; [[ "$(wc -l < "$inv")" -eq 3 ]] )
  local rc=$?; rm -rf "$tmp"; return "$rc"
}

test_helper_pins_inventory_and_nic(){
  local tmp inv; tmp="$(mktemp -d)"; inv="$tmp/inv"; printf 'rx-0/rps_cpus\nrx-0/rps_flow_cnt\n' > "$inv"
  ( SSO_LOCAL_SBIN_DIR="$tmp/sbin"; cpu_irq_write_restore_helper test0 "$inv"; grep -Fxq 'nic=test0' "$tmp/sbin/sso-cpuirq-restore"; grep -Fq 'rx-0/rps_cpus' "$tmp/sbin/sso-cpuirq-restore"; ! grep -Fq 'tx-0/xps_cpus' "$tmp/sbin/sso-cpuirq-restore" )
  local rc=$?; rm -rf "$tmp"; return "$rc"
}

test_backup_failure_guarded(){ grep -Fq 'if ! d="$(backup_create "cpu_irq:rps_rfs_xps")"; then' "$ROOT_DIR/modules/cpu_irq.sh" && grep -Fq 'No RPS/RFS/XPS settings were changed.' "$ROOT_DIR/modules/cpu_irq.sh"; }

run_test "CPU masks group correctly" test_cpu_mask_format
run_test "CPU mask has no Python dependency" test_no_python
run_test "CPU constants and helper reuse remain" test_constants_and_helper
run_test "queue/persistence failures stay visible" test_failures_visible
run_test "unreadable XPS is skipped while RPS/RFS remain managed" test_unreadable_xps_is_skipped
run_test "all readable capability classes are managed" test_all_readable_are_managed
run_test "persistence pins exact managed inventory and NIC" test_helper_pins_inventory_and_nic
run_test "backup failure remains in menu flow" test_backup_failure_guarded
finish_tests
