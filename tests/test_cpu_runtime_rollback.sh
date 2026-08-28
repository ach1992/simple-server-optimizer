#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

cpu_runtime_capture_and_restore_round_trip() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p \
    "$tmp/sys/class/net/test0/queues/rx-0" \
    "$tmp/sys/class/net/test0/queues/rx-1" \
    "$tmp/sys/class/net/test0/queues/tx-0" \
    "$tmp/sys/class/net/test0/queues/tx-1" \
    "$tmp/backup"
  printf '0\n' > "$tmp/sys/class/net/test0/queues/rx-0/rps_cpus"
  printf '0\n' > "$tmp/sys/class/net/test0/queues/rx-1/rps_cpus"
  printf '0\n' > "$tmp/sys/class/net/test0/queues/rx-0/rps_flow_cnt"
  printf '0\n' > "$tmp/sys/class/net/test0/queues/rx-1/rps_flow_cnt"
  printf '1\n' > "$tmp/sys/class/net/test0/queues/tx-0/xps_cpus"
  printf '2\n' > "$tmp/sys/class/net/test0/queues/tx-1/xps_cpus"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    SSO_SYS_CLASS_NET_DIR="$FIXTURE_ROOT/sys/class/net"
    RPS_GLOBAL=0
    source "$ROOT_DIR/modules/rollback.sh"
    detect_nic(){ printf "test0\n"; }
    warn(){ :; }
    sysctl(){
      case "$1" in
        -n) [[ "$2" == "net.core.rps_sock_flow_entries" ]] || return 1; printf "%s\n" "$RPS_GLOBAL" ;;
        -w) RPS_GLOBAL="${2#net.core.rps_sock_flow_entries=}"; printf "%s\n" "$2" ;;
        *) return 1 ;;
      esac
    }

    backup_capture_cpu_runtime "$FIXTURE_ROOT/backup"
    printf "3\n" > "$SSO_SYS_CLASS_NET_DIR/test0/queues/rx-0/rps_cpus"
    printf "3\n" > "$SSO_SYS_CLASS_NET_DIR/test0/queues/rx-1/rps_cpus"
    printf "16384\n" > "$SSO_SYS_CLASS_NET_DIR/test0/queues/rx-0/rps_flow_cnt"
    printf "16384\n" > "$SSO_SYS_CLASS_NET_DIR/test0/queues/rx-1/rps_flow_cnt"
    printf "3\n" > "$SSO_SYS_CLASS_NET_DIR/test0/queues/tx-0/xps_cpus"
    printf "3\n" > "$SSO_SYS_CLASS_NET_DIR/test0/queues/tx-1/xps_cpus"
    RPS_GLOBAL=65536

    backup_restore_cpu_runtime "$FIXTURE_ROOT/backup"
    [[ "$RPS_GLOBAL" == "0" ]]
    [[ "$(cat "$SSO_SYS_CLASS_NET_DIR/test0/queues/rx-0/rps_cpus")" == "0" ]]
    [[ "$(cat "$SSO_SYS_CLASS_NET_DIR/test0/queues/rx-1/rps_cpus")" == "0" ]]
    [[ "$(cat "$SSO_SYS_CLASS_NET_DIR/test0/queues/rx-0/rps_flow_cnt")" == "0" ]]
    [[ "$(cat "$SSO_SYS_CLASS_NET_DIR/test0/queues/rx-1/rps_flow_cnt")" == "0" ]]
    [[ "$(cat "$SSO_SYS_CLASS_NET_DIR/test0/queues/tx-0/xps_cpus")" == "1" ]]
    [[ "$(cat "$SSO_SYS_CLASS_NET_DIR/test0/queues/tx-1/xps_cpus")" == "2" ]]
  '
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

rps_runtime_restore_requires_captured_runtime_marker() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/backup/cpu_irq/runtime"
  (
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/rollback.sh"
    rc=0
    backup_restore_cpu_runtime "$tmp/backup" || rc=$?
    [[ "$rc" == "2" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

run_test "captured RPS/RFS/XPS runtime values round-trip exactly" cpu_runtime_capture_and_restore_round_trip
run_test "RPS runtime restore requires an explicit captured runtime marker" rps_runtime_restore_requires_captured_runtime_marker
finish_tests
