#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

make_strict_cpu_snapshot() {
  local d="$1"
  mkdir -p \
    "$d/cpu_irq/runtime/queues/rx-0" \
    "$d/cpu_irq/runtime/queues/rx-1" \
    "$d/cpu_irq/runtime/queues/tx-0" \
    "$d/cpu_irq/runtime/queues/tx-1" \
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
  printf '0\n' > "$d/cpu_irq/runtime/queues/rx-1/rps_cpus"
  printf '0\n' > "$d/cpu_irq/runtime/queues/rx-0/rps_flow_cnt"
  printf '0\n' > "$d/cpu_irq/runtime/queues/rx-1/rps_flow_cnt"
  printf '1\n' > "$d/cpu_irq/runtime/queues/tx-0/xps_cpus"
  printf '2\n' > "$d/cpu_irq/runtime/queues/tx-1/xps_cpus"
  : > "$d/sysctl/99-sso-rps.conf.absent"
  : > "$d/cpu_irq/sso-cpuirq.service.absent"
  : > "$d/cpu_irq/sso-cpuirq-restore.absent"
  printf 'not-found\n' > "$d/services/sso-cpuirq.service/load"
  printf 'not-found\n' > "$d/services/sso-cpuirq.service/enabled"
  printf 'inactive\n' > "$d/services/sso-cpuirq.service/active"
}

make_partial_cpu_snapshot() {
  local d="$1"
  make_strict_cpu_snapshot "$d"
  rm -rf "$d/cpu_irq/runtime/queues/tx-0" "$d/cpu_irq/runtime/queues/tx-1"
  cat > "$d/cpu_irq/runtime/managed-queues" <<'EOF_MANAGED'
rx-0/rps_cpus
rx-0/rps_flow_cnt
rx-1/rps_cpus
rx-1/rps_flow_cnt
EOF_MANAGED
}

make_live_rps_fixture() {
  local root="$1"
  mkdir -p \
    "$root/sys/class/net/test0/queues/rx-0" \
    "$root/sys/class/net/test0/queues/rx-1" \
    "$root/sys/class/net/test0/queues/tx-0" \
    "$root/sys/class/net/test0/queues/tx-1"
  printf '3\n' > "$root/sys/class/net/test0/queues/rx-0/rps_cpus"
  printf '3\n' > "$root/sys/class/net/test0/queues/rx-1/rps_cpus"
  printf '16384\n' > "$root/sys/class/net/test0/queues/rx-0/rps_flow_cnt"
  printf '16384\n' > "$root/sys/class/net/test0/queues/rx-1/rps_flow_cnt"
  printf '3\n' > "$root/sys/class/net/test0/queues/tx-0/xps_cpus"
  printf '3\n' > "$root/sys/class/net/test0/queues/tx-1/xps_cpus"
  printf '65536\n' > "$root/rps-global"
}

make_uninstall_owned_files() {
  local root="$1"
  mkdir -p \
    "$root/state" "$root/backups" "$root/install" "$root/sysctl" \
    "$root/systemd" "$root/sbin" "$root/bin" "$root/modules-load" \
    "$root/fail2ban/jail.d"
  : > "$root/install/sso.sh"
  : > "$root/bin/sso"
  printf '# SSO: RPS/RFS global settings\nnet.core.rps_sock_flow_entries=65536\n' > "$root/sysctl/99-sso-rps.conf"
  cat > "$root/systemd/sso-cpuirq.service" <<'UNIT'
[Unit]
Description=SSO CPU/IRQ tuning (RPS/RFS/XPS)
UNIT
  cat > "$root/sbin/sso-cpuirq-restore" <<'RESTORE'
#!/usr/bin/env bash
sysctl -w net.core.rps_sock_flow_entries=65536
RESTORE
}

run_full_uninstall_fixture() {
  local root="$1"
  local fail_global_write="${2:-0}"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$root" FAIL_GLOBAL_WRITE="$fail_global_write" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"
    SSO_DIR="$FIXTURE_ROOT/install"
    SSO_SYSCTL_DIR="$FIXTURE_ROOT/sysctl"
    SSO_SYSTEMD_DIR="$FIXTURE_ROOT/systemd"
    SSO_LOCAL_SBIN_DIR="$FIXTURE_ROOT/sbin"
    SSO_LOCAL_BIN_DIR="$FIXTURE_ROOT/bin"
    SSO_MODULES_LOAD_DIR="$FIXTURE_ROOT/modules-load"
    SSO_SYS_CLASS_NET_DIR="$FIXTURE_ROOT/sys/class/net"
    F2B_SSO_LOCAL="$FIXTURE_ROOT/fail2ban/jail.d/sso.local"
    F2B_NGINX_MARKER="$STATE_DIR/fail2ban-nginx.enabled"
    LOG="$FIXTURE_ROOT/actions.log"
    : > "$LOG"

    systemctl() {
      printf "systemctl %s\n" "$*" >> "$LOG"
      local action="${1:-}" unit="${*: -1}"
      case "$action" in
        show)
          if [[ "$unit" == "sso-cpuirq.service" && -f "$SSO_SYSTEMD_DIR/sso-cpuirq.service" ]]; then
            printf "loaded\n"
          else
            printf "not-found\n"
          fi
          ;;
        is-active)
          if [[ "$unit" == "sso-cpuirq.service" ]]; then printf "inactive\n"; fi
          return 3
          ;;
        is-enabled)
          if [[ "$unit" == "sso-cpuirq.service" ]]; then printf "disabled\n"; fi
          return 1
          ;;
        unmask|stop|disable|reset-failed|daemon-reload|restart) return 0 ;;
        *) return 0 ;;
      esac
    }
    sysctl() {
      printf "sysctl %s\n" "$*" >> "$LOG"
      case "${1:-}" in
        -n)
          [[ "${2:-}" == "net.core.rps_sock_flow_entries" ]] || return 1
          cat "$FIXTURE_ROOT/rps-global"
          ;;
        -w)
          [[ "${2:-}" == net.core.rps_sock_flow_entries=* ]] || return 1
          if [[ "$FAIL_GLOBAL_WRITE" == "1" ]]; then return 1; fi
          printf "%s\n" "${2#net.core.rps_sock_flow_entries=}" > "$FIXTURE_ROOT/rps-global"
          printf "%s\n" "$2"
          ;;
        --system) return 0 ;;
        *) return 1 ;;
      esac
    }

    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    # Runtime sso.sh sources cpu_irq.sh after rollback.sh; do the same here so
    # uninstall exercises the capability-aware capture/restore override.
    source "$ROOT_DIR/modules/cpu_irq.sh"
    source "$ROOT_DIR/modules/uninstall.sh"

    header(){ :; }; section(){ :; }; info(){ :; }; pause(){ :; }; ok(){ :; }
    warn(){ printf "warn %s\n" "$*" >> "$LOG"; }
    err(){ printf "err %s\n" "$*" >> "$LOG"; }
    read_input(){ local -n out="$2"; out="y"; }
    remove_sso_firewall_runtime(){ return 0; }

    module_uninstall
  '
}

full_uninstall_restores_cpu_runtime_before_cleanup() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_uninstall_owned_files "$tmp"
  make_live_rps_fixture "$tmp"
  make_strict_cpu_snapshot "$tmp/backups/20260828-120000"

  run_full_uninstall_fixture "$tmp" 0 >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then rm -rf "$tmp"; return 1; fi

  local stop_line restore_line test_rc=0
  stop_line="$(grep -n '^systemctl stop sso-cpuirq.service$' "$tmp/actions.log" | head -n1 | cut -d: -f1)"
  restore_line="$(grep -n '^sysctl -w net.core.rps_sock_flow_entries=0$' "$tmp/actions.log" | head -n1 | cut -d: -f1)"
  [[ -n "$stop_line" && -n "$restore_line" && "$stop_line" -lt "$restore_line" ]] || test_rc=1

  [[ "$(cat "$tmp/rps-global")" == "0" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/rx-0/rps_cpus")" == "0" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/rx-1/rps_cpus")" == "0" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/rx-0/rps_flow_cnt")" == "0" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/rx-1/rps_flow_cnt")" == "0" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/tx-0/xps_cpus")" == "1" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/tx-1/xps_cpus")" == "2" ]] || test_rc=1

  [[ ! -e "$tmp/state" ]] || test_rc=1
  [[ ! -e "$tmp/backups" ]] || test_rc=1
  [[ ! -e "$tmp/install" ]] || test_rc=1
  [[ ! -e "$tmp/bin/sso" ]] || test_rc=1
  [[ ! -e "$tmp/sysctl/99-sso-rps.conf" ]] || test_rc=1
  [[ ! -e "$tmp/systemd/sso-cpuirq.service" ]] || test_rc=1
  [[ ! -e "$tmp/sbin/sso-cpuirq-restore" ]] || test_rc=1

  rm -rf "$tmp"
  return "$test_rc"
}

partial_uninstall_restores_managed_rps_rfs_and_preserves_xps() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_uninstall_owned_files "$tmp"
  make_live_rps_fixture "$tmp"
  make_partial_cpu_snapshot "$tmp/backups/20260828-120000"
  # XPS was skipped by SSO in this snapshot generation. Model independent
  # runtime values and require uninstall to leave them exactly untouched.
  printf '7\n' > "$tmp/sys/class/net/test0/queues/tx-0/xps_cpus"
  printf '8\n' > "$tmp/sys/class/net/test0/queues/tx-1/xps_cpus"

  run_full_uninstall_fixture "$tmp" 0 >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then rm -rf "$tmp"; return 1; fi

  local test_rc=0
  [[ "$(cat "$tmp/rps-global")" == "0" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/rx-0/rps_cpus")" == "0" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/rx-1/rps_cpus")" == "0" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/rx-0/rps_flow_cnt")" == "0" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/rx-1/rps_flow_cnt")" == "0" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/tx-0/xps_cpus")" == "7" ]] || test_rc=1
  [[ "$(cat "$tmp/sys/class/net/test0/queues/tx-1/xps_cpus")" == "8" ]] || test_rc=1
  [[ ! -e "$tmp/state" && ! -e "$tmp/backups" && ! -e "$tmp/install" ]] || test_rc=1

  rm -rf "$tmp"
  return "$test_rc"
}

restore_failure_preserves_recovery_and_persistence() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_uninstall_owned_files "$tmp"
  make_live_rps_fixture "$tmp"
  make_strict_cpu_snapshot "$tmp/backups/20260828-120000"

  run_full_uninstall_fixture "$tmp" 1 >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then rm -rf "$tmp"; return 1; fi

  local test_rc=0
  grep -q 'Could not fully restore the captured pre-SSO RPS/RFS/XPS runtime state' "$tmp/actions.log" || test_rc=1
  [[ "$(cat "$tmp/rps-global")" == "65536" ]] || test_rc=1
  [[ -d "$tmp/state" ]] || test_rc=1
  [[ -d "$tmp/backups" ]] || test_rc=1
  [[ -d "$tmp/install" ]] || test_rc=1
  [[ -f "$tmp/bin/sso" ]] || test_rc=1
  [[ -f "$tmp/sysctl/99-sso-rps.conf" ]] || test_rc=1
  [[ -f "$tmp/systemd/sso-cpuirq.service" ]] || test_rc=1
  [[ -f "$tmp/sbin/sso-cpuirq-restore" ]] || test_rc=1

  rm -rf "$tmp"
  return "$test_rc"
}

previous_install_backup_fallback_requires_strict_snapshot() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/backups" "$tmp/install.bak/backups"
  make_strict_cpu_snapshot "$tmp/backups/20260828-120000"
  rm -f "$tmp/backups/20260828-120000/FORMAT"
  make_strict_cpu_snapshot "$tmp/install.bak/backups/20260828-110000"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    BACKUP_DIR_BASE="$FIXTURE_ROOT/backups"
    SSO_DIR="$FIXTURE_ROOT/install"
    mkdir -p "$STATE_DIR"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    source "$ROOT_DIR/modules/cpu_irq.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    if uninstall_cpu_runtime_snapshot_is_preownership "$BACKUP_DIR_BASE/20260828-120000"; then
      exit 1
    fi
    found="$(uninstall_find_cpu_runtime_baseline)"
    [[ "$found" == "$SSO_DIR.bak/backups/20260828-110000" ]]
  '
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

run_test "full uninstall restores exact legacy CPU runtime before destructive cleanup" full_uninstall_restores_cpu_runtime_before_cleanup
run_test "partial uninstall restores managed RPS/RFS and preserves skipped XPS" partial_uninstall_restores_managed_rps_rfs_and_preserves_xps
run_test "CPU restore failure preserves uninstall recovery and persistence evidence" restore_failure_preserves_recovery_and_persistence
run_test "previous-install CPU baseline fallback requires a strict current-format snapshot" previous_install_backup_fallback_requires_strict_snapshot
finish_tests