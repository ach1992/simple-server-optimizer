#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TESTLIB_SOURCE="${TESTLIB_SOURCE:-$ROOT_DIR/tests/lib/testlib.sh}"
ROLLBACK_SOURCE="${ROLLBACK_SOURCE:-$ROOT_DIR/modules/rollback.sh}"
UNINSTALL_SOURCE="${UNINSTALL_SOURCE:-$ROOT_DIR/modules/uninstall.sh}"
source "$TESTLIB_SOURCE"

service_inspection_failure_prevents_v2_certification() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    STATE_DIR="$tmp/state"
    BACKUP_DIR_BASE="$tmp/backups"
    SSO_DIR="$tmp/install"
    source "$ROLLBACK_SOURCE"
    ts() { printf '20260825-180000\n'; }
    backup_capture_sysctl() { :; }
    backup_capture_qdisc() { :; }
    backup_capture_firewall() { :; }
    backup_capture_cpu_irq() { :; }
    backup_capture_state() { :; }
    backup_capture_fail2ban() { :; }
    backup_capture_services() { backup_capture_service_state "$1" test.service; }
    systemctl() { return 1; }

    if backup_create 'test:service-inspection' >/dev/null 2>&1; then
      exit 1
    fi
    ! find "$BACKUP_DIR_BASE" -name FORMAT -type f -print -quit | grep -q .
    if backup_last_dir >/dev/null 2>&1; then exit 1; fi
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

failed_cleanup_leaves_quarantined_unselectable_snapshot() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    STATE_DIR="$tmp/state"
    BACKUP_DIR_BASE="$tmp/backups"
    SSO_DIR="$tmp/install"
    source "$ROLLBACK_SOURCE"
    ts() { printf '20260825-180100\n'; }
    backup_capture_sysctl() { return 1; }
    backup_capture_qdisc() { :; }
    backup_capture_firewall() { :; }
    backup_capture_cpu_irq() { :; }
    backup_capture_state() { :; }
    backup_capture_fail2ban() { :; }
    backup_capture_services() { :; }
    rm() {
      if [[ "${1:-}" == "-rf" ]]; then return 99; fi
      command rm "$@"
    }
    err() { :; }

    if backup_create 'test:cleanup-failure' >/dev/null 2>&1; then
      exit 1
    fi
    local leftover="$BACKUP_DIR_BASE/20260825-180100"
    [[ -f "$leftover/INCOMPLETE" ]]
    if backup_is_usable_dir "$leftover"; then exit 1; fi
    if backup_last_dir >/dev/null 2>&1; then exit 1; fi
    [[ -z "$(backup_list_names "$BACKUP_DIR_BASE")" ]]
    if restore_from_dir "$leftover" >/dev/null 2>&1; then exit 1; fi
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

durable_bbr_baseline_survives_online_install_relocation() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p \
    "$tmp/install.bak/backups/20260101-000000/sysctl" \
    "$tmp/install/backups/20260102-000000/sysctl" \
    "$tmp/modules-load"
  printf 'network:fq_bbr\n' > "$tmp/install.bak/backups/20260101-000000/TAG"
  printf 'operator-before\n' > "$tmp/install.bak/backups/20260101-000000/sysctl/bbr.conf"
  printf 'network:fq_bbr\n' > "$tmp/install/backups/20260102-000000/TAG"
  printf '2\n' > "$tmp/install/backups/20260102-000000/FORMAT"
  printf 'sso-modified\n' > "$tmp/install/backups/20260102-000000/sysctl/bbr.conf"
  printf 'net.core.default_qdisc=fq\n' > "$tmp/install/backups/20260102-000000/sysctl/99-sso-qdisc.conf"

  ROOT_DIR="$ROOT_DIR" FIXTURE_ROOT="$tmp" ROLLBACK_SOURCE="$ROLLBACK_SOURCE" UNINSTALL_SOURCE="$UNINSTALL_SOURCE" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE_ROOT/state"
    BACKUP_DIR_BASE="$FIXTURE_ROOT/install/backups"
    SSO_DIR="$FIXTURE_ROOT/install"
    SSO_MODULES_LOAD_DIR="$FIXTURE_ROOT/modules-load"
    source "$ROLLBACK_SOURCE"

    baseline="$(backup_resource_baseline_dir bbr)"
    [[ "$baseline" == "$STATE_DIR/ownership-baselines/bbr" ]]
    [[ "$(cat "$baseline/sysctl/bbr.conf")" == "operator-before" ]]

    rm -rf "$SSO_DIR.bak"
    [[ "$(cat "$(backup_resource_baseline_dir bbr)/sysctl/bbr.conf")" == "operator-before" ]]

    printf "sso-current\n" > "$SSO_MODULES_LOAD_DIR/bbr.conf"
    source "$UNINSTALL_SOURCE"
    uninstall_restore_shared_file_baseline "$(backup_resource_baseline_dir bbr)"
    [[ "$(cat "$SSO_MODULES_LOAD_DIR/bbr.conf")" == "operator-before" ]]
  '
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

active_backup_is_not_invented_as_ownership_baseline() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/install/backups/20260102-000000/sysctl"
  printf 'network:fq_bbr\n' > "$tmp/install/backups/20260102-000000/TAG"
  printf '2\n' > "$tmp/install/backups/20260102-000000/FORMAT"
  printf 'sso-modified\n' > "$tmp/install/backups/20260102-000000/sysctl/bbr.conf"
  printf 'net.core.default_qdisc=fq\n' > "$tmp/install/backups/20260102-000000/sysctl/99-sso-qdisc.conf"
  (
    set -Eeuo pipefail
    STATE_DIR="$tmp/state"
    BACKUP_DIR_BASE="$tmp/install/backups"
    SSO_DIR="$tmp/install"
    source "$ROLLBACK_SOURCE"
    if backup_resource_baseline_dir bbr >/dev/null 2>&1; then exit 1; fi
    backup_record_ownership_baseline network:fq_bbr "$BACKUP_DIR_BASE/20260102-000000"
    [[ ! -e "$STATE_DIR/ownership-baselines/bbr" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

runtime_service_states_clear_conflicting_persistent_state() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/backup/services/test.service"

  (
    set -Eeuo pipefail
    source "$ROLLBACK_SOURCE"
    local_state_test() {
      local desired="$1" desired_active="$2"
      printf 'loaded\n' > "$tmp/backup/services/test.service/load"
      printf '%s\n' "$desired" > "$tmp/backup/services/test.service/enabled"
      printf '%s\n' "$desired_active" > "$tmp/backup/services/test.service/active"

      PERSIST=1; RUNTIME=1; PMASK=0; RMASK=0; ACTIVE=1
      systemctl() {
        case "$1" in
          unmask)
            if [[ "${2:-}" == "--runtime" ]]; then RMASK=0; else PMASK=0; fi
            ;;
          disable)
            if [[ "${2:-}" == "--runtime" ]]; then RUNTIME=0; else PERSIST=0; fi
            ;;
          enable)
            if [[ "${2:-}" == "--runtime" ]]; then RUNTIME=1; else PERSIST=1; fi
            ;;
          mask)
            if [[ "${2:-}" == "--runtime" ]]; then RMASK=1; else PMASK=1; fi
            ;;
          start|restart) ACTIVE=1 ;;
          stop) ACTIVE=0 ;;
          reset-failed) : ;;
          show) printf 'loaded\n' ;;
          is-enabled)
            if (( RMASK )); then printf 'masked-runtime\n'
            elif (( PMASK )); then printf 'masked\n'
            elif (( RUNTIME )); then printf 'enabled-runtime\n'
            elif (( PERSIST )); then printf 'enabled\n'
            else printf 'disabled\n'; fi
            ;;
          is-active)
            if (( ACTIVE )); then printf 'active\n'; else printf 'inactive\n'; fi
            ;;
          *) return 99 ;;
        esac
        return 0
      }

      backup_restore_service_state "$tmp/backup" test.service 0
      case "$desired" in
        enabled-runtime) (( PERSIST == 0 && RUNTIME == 1 && PMASK == 0 && RMASK == 0 && ACTIVE == 1 )) ;;
        masked-runtime) (( PERSIST == 0 && RUNTIME == 0 && PMASK == 0 && RMASK == 1 && ACTIVE == 0 )) ;;
        *) return 1 ;;
      esac
    }

    local_state_test enabled-runtime active
    local_state_test masked-runtime inactive
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

not_found_service_state_requires_verified_absence() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/backup/services/test.service"
  printf 'not-found\n' > "$tmp/backup/services/test.service/load"
  printf 'not-found\n' > "$tmp/backup/services/test.service/enabled"
  printf 'inactive\n' > "$tmp/backup/services/test.service/active"

  (
    set -Eeuo pipefail
    source "$ROLLBACK_SOURCE"
    : > "$tmp/commands.log"
    systemctl() {
      printf '%s\n' "$*" >> "$tmp/commands.log"
      if [[ "$1" == "show" ]]; then printf 'not-found\n'; return 0; fi
      return 99
    }
    backup_restore_service_state "$tmp/backup" test.service 0
    [[ "$(wc -l < "$tmp/commands.log")" -eq 1 ]]
    grep -q '^show -p LoadState --value test.service$' "$tmp/commands.log"
  ) || { rm -rf "$tmp"; return 1; }

  (
    set -Eeuo pipefail
    source "$ROLLBACK_SOURCE"
    systemctl() { return 99; }
    if backup_restore_service_state "$tmp/backup" test.service 0; then exit 1; fi
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

positive_firewall_cleanup_removes_only_sso_objects() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    source "$ROLLBACK_SOURCE"
    NFT_INET=1; NFT_IP=1
    IPT_IN_JUMP=1; IPT_OUT_JUMP=1; IPT_IN=1; IPT_OUT=1
    SET_BLOCK=1; SET_WHITE=1

    nft() {
      if [[ "$*" == "list tables" ]]; then
        (( NFT_INET )) && printf 'table inet sso\n'
        (( NFT_IP )) && printf 'table ip sso\n'
        printf 'table inet operator\n'
        return 0
      fi
      case "$*" in
        'flush table inet sso') : ;;
        'delete table inet sso') NFT_INET=0 ;;
        'flush table ip sso') : ;;
        'delete table ip sso') NFT_IP=0 ;;
        *) return 99 ;;
      esac
    }
    iptables() {
      if [[ "$1" == "-S" ]]; then
        printf '%s\n' '-P INPUT ACCEPT' '-N OPERATOR'
        (( IPT_IN )) && printf '%s\n' '-N SSO_IN'
        (( IPT_OUT )) && printf '%s\n' '-N SSO_OUT'
        (( IPT_IN_JUMP )) && printf '%s\n' '-A INPUT -j SSO_IN'
        (( IPT_OUT_JUMP )) && printf '%s\n' '-A OUTPUT -j SSO_OUT'
        return 0
      fi
      case "$*" in
        '-D INPUT -j SSO_IN') IPT_IN_JUMP=0 ;;
        '-D OUTPUT -j SSO_OUT') IPT_OUT_JUMP=0 ;;
        '-F SSO_IN') : ;;
        '-X SSO_IN') IPT_IN=0 ;;
        '-F SSO_OUT') : ;;
        '-X SSO_OUT') IPT_OUT=0 ;;
        *) return 99 ;;
      esac
    }
    ipset() {
      if [[ "$*" == "list -name" ]]; then
        (( SET_BLOCK )) && printf 'sso_block_v4\n'
        (( SET_WHITE )) && printf 'sso_white_v4\n'
        printf 'operator_set\n'
        return 0
      fi
      case "$*" in
        'destroy sso_block_v4') SET_BLOCK=0 ;;
        'destroy sso_white_v4') SET_WHITE=0 ;;
        *) return 99 ;;
      esac
    }

    remove_sso_firewall_runtime
    (( NFT_INET == 0 && NFT_IP == 0 ))
    (( IPT_IN_JUMP == 0 && IPT_OUT_JUMP == 0 && IPT_IN == 0 && IPT_OUT == 0 ))
    (( SET_BLOCK == 0 && SET_WHITE == 0 ))
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

run_test "service inspection failure prevents FORMAT=2 certification" service_inspection_failure_prevents_v2_certification
run_test "failed cleanup leaves an INCOMPLETE snapshot that selectors reject" failed_cleanup_leaves_quarantined_unselectable_snapshot
run_test "durable BBR baseline survives online install relocation and .bak deletion" durable_bbr_baseline_survives_online_install_relocation
run_test "active retained backup is not invented as an ownership baseline" active_backup_is_not_invented_as_ownership_baseline
run_test "runtime service states clear conflicting persistent enablement" runtime_service_states_clear_conflicting_persistent_state
run_test "not-found service state requires verified absence" not_found_service_state_requires_verified_absence
run_test "positive firewall cleanup removes only SSO objects" positive_firewall_cleanup_removes_only_sso_objects
finish_tests
