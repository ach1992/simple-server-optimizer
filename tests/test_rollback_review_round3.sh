#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TESTLIB_SOURCE="${TESTLIB_SOURCE:-$ROOT_DIR/tests/lib/testlib.sh}"
ROLLBACK_SOURCE="${ROLLBACK_SOURCE:-$ROOT_DIR/modules/rollback.sh}"
source "$TESTLIB_SOURCE"

certification_read_failure_stays_quarantined_if_cleanup_fails() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    STATE_DIR="$tmp/state"
    BACKUP_DIR_BASE="$tmp/backups"
    SSO_DIR="$tmp/install"
    source "$ROLLBACK_SOURCE"
    ts() { printf '20260825-190000\n'; }
    backup_capture_sysctl() { :; }
    backup_capture_qdisc() { :; }
    backup_capture_firewall() { :; }
    backup_capture_cpu_irq() { :; }
    backup_capture_state() { :; }
    backup_capture_fail2ban() { :; }
    backup_capture_services() { :; }

    local real_cat
    real_cat="$(command -v cat)"
    FORMAT_READ_FAILS=1
    cat() {
      if [[ "${1:-}" == */FORMAT && "$FORMAT_READ_FAILS" == "1" ]]; then
        FORMAT_READ_FAILS=0
        return 71
      fi
      "$real_cat" "$@"
    }
    rm() {
      if [[ "${1:-}" == "-rf" ]]; then
        : > "$tmp/rm-rf-called"
        return 99
      fi
      command rm "$@"
    }

    if backup_create 'test:post-write-certification-failure' >/dev/null 2>&1; then
      exit 1
    fi
    local leftover="$BACKUP_DIR_BASE/20260825-190000"
    [[ ! -e "$tmp/rm-rf-called" ]]
    [[ -f "$leftover/TAG" && -f "$leftover/FORMAT" ]]
    [[ -f "$leftover/INCOMPLETE" ]]
    [[ ! -e "$leftover/COMPLETE" ]]
    if backup_is_usable_dir "$leftover"; then exit 1; fi
    if backup_last_dir >/dev/null 2>&1; then exit 1; fi
    [[ -z "$(backup_list_names "$BACKUP_DIR_BASE")" ]]
    if restore_from_dir "$leftover" >/dev/null 2>&1; then exit 1; fi
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

ambiguous_sso_bbr_history_is_not_promoted_or_replaced_by_current() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p \
    "$tmp/install.bak/backups/20260101-000000/sysctl" \
    "$tmp/install/backups/20260102-000000/sysctl"

  printf 'network:fq_bbr\n' > "$tmp/install.bak/backups/20260101-000000/TAG"
  printf 'tcp_bbr\n' > "$tmp/install.bak/backups/20260101-000000/sysctl/bbr.conf"

  printf 'network:fq_bbr\n' > "$tmp/install/backups/20260102-000000/TAG"
  printf '2\n' > "$tmp/install/backups/20260102-000000/FORMAT"
  : > "$tmp/install/backups/20260102-000000/COMPLETE"
  : > "$tmp/install/backups/20260102-000000/sysctl/bbr.conf.absent"
  : > "$tmp/install/backups/20260102-000000/sysctl/99-sso-qdisc.conf.absent"
  : > "$tmp/install/backups/20260102-000000/sysctl/99-sso-bbr.conf.absent"

  (
    set -Eeuo pipefail
    STATE_DIR="$tmp/state"
    BACKUP_DIR_BASE="$tmp/install/backups"
    SSO_DIR="$tmp/install"
    source "$ROLLBACK_SOURCE"

    if backup_resource_baseline_dir bbr >/dev/null 2>&1; then exit 1; fi
    if backup_snapshot_is_preownership bbr "$SSO_DIR.bak/backups/20260101-000000" historical; then exit 1; fi

    backup_record_ownership_baseline network:fq_bbr "$BACKUP_DIR_BASE/20260102-000000"
    [[ ! -e "$STATE_DIR/ownership-baselines/bbr" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

fresh_first_bbr_operation_can_preserve_explicit_absence() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/install/backups/20260102-000000/sysctl"
  printf 'network:fq_bbr\n' > "$tmp/install/backups/20260102-000000/TAG"
  printf '2\n' > "$tmp/install/backups/20260102-000000/FORMAT"
  : > "$tmp/install/backups/20260102-000000/COMPLETE"
  : > "$tmp/install/backups/20260102-000000/sysctl/bbr.conf.absent"
  : > "$tmp/install/backups/20260102-000000/sysctl/99-sso-qdisc.conf.absent"
  : > "$tmp/install/backups/20260102-000000/sysctl/99-sso-bbr.conf.absent"

  (
    set -Eeuo pipefail
    STATE_DIR="$tmp/state"
    BACKUP_DIR_BASE="$tmp/install/backups"
    SSO_DIR="$tmp/install"
    source "$ROLLBACK_SOURCE"
    backup_record_ownership_baseline network:fq_bbr "$BACKUP_DIR_BASE/20260102-000000"
    local baseline
    baseline="$(backup_resource_baseline_dir bbr)"
    [[ -f "$baseline/sysctl/bbr.conf.absent" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

markerless_v2_residue_needs_positive_complete_marker() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p \
    "$tmp/backups/20260101-legacy" \
    "$tmp/backups/20260102-complete" \
    "$tmp/backups/20260103-residue" \
    "$tmp/backups/20260104-symlink"

  printf 'legacy:test\n' > "$tmp/backups/20260101-legacy/TAG"

  printf 'test:complete\n' > "$tmp/backups/20260102-complete/TAG"
  printf '2\n' > "$tmp/backups/20260102-complete/FORMAT"
  : > "$tmp/backups/20260102-complete/COMPLETE"

  printf 'test:residue\n' > "$tmp/backups/20260103-residue/TAG"
  printf '2\n' > "$tmp/backups/20260103-residue/FORMAT"

  printf 'test:symlink\n' > "$tmp/backups/20260104-symlink/TAG"
  printf '2\n' > "$tmp/backups/20260104-symlink/FORMAT"
  : > "$tmp/sentinel"
  ln -s "$tmp/sentinel" "$tmp/backups/20260104-symlink/COMPLETE"

  (
    set -Eeuo pipefail
    STATE_DIR="$tmp/state"
    BACKUP_DIR_BASE="$tmp/backups"
    SSO_DIR="$tmp/install"
    source "$ROLLBACK_SOURCE"
    err() { :; }

    backup_is_usable_dir "$BACKUP_DIR_BASE/20260101-legacy"
    backup_is_usable_dir "$BACKUP_DIR_BASE/20260102-complete"
    if backup_is_usable_dir "$BACKUP_DIR_BASE/20260103-residue"; then exit 1; fi
    if backup_is_usable_dir "$BACKUP_DIR_BASE/20260104-symlink"; then exit 1; fi

    local listed
    listed="$(backup_list_names "$BACKUP_DIR_BASE")"
    printf '%s\n' "$listed" | grep -Fxq '20260101-legacy'
    printf '%s\n' "$listed" | grep -Fxq '20260102-complete'
    if printf '%s\n' "$listed" | grep -Fxq '20260103-residue'; then exit 1; fi
    if printf '%s\n' "$listed" | grep -Fxq '20260104-symlink'; then exit 1; fi
    [[ "$(backup_last_dir)" == "$BACKUP_DIR_BASE/20260102-complete" ]]
    if restore_from_dir "$BACKUP_DIR_BASE/20260103-residue" >/dev/null 2>&1; then exit 1; fi
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

run_test "certification failure remains quarantined without unsafe cleanup" certification_read_failure_stays_quarantined_if_cleanup_fails
run_test "ambiguous tcp_bbr legacy history is never promoted or replaced by current fallback" ambiguous_sso_bbr_history_is_not_promoted_or_replaced_by_current
run_test "fresh first BBR operation preserves explicit shared-file absence" fresh_first_bbr_operation_can_preserve_explicit_absence
run_test "FORMAT=2 selectors require a positive non-symlink COMPLETE marker" markerless_v2_residue_needs_positive_complete_marker
finish_tests
