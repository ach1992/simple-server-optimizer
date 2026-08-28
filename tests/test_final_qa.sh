#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/testlib.sh"

test_release_candidate_version_is_visible() {
  grep -q '^SSO_VERSION="1\.1\.0"$' "$ROOT_DIR/sso.sh" || return 1
}

test_fail2ban_menu_does_not_claim_service_stop_is_rollback() {
  grep -Fq 'Remove SSO Fail2Ban config (preserve service state)' "$ROOT_DIR/sso.sh" || return 1
  if grep -Fq 'Disable Fail2Ban changes (rollback f2b only)' "$ROOT_DIR/sso.sh"; then
    return 1
  fi
}

test_fail2ban_invalid_whitelist_returns_to_menu() {
  ROOT_DIR="$ROOT_DIR" bash -c '
    set -Eeuo pipefail
    STATE_DIR="/tmp/sso-final-qa-state-unused"
    source "$ROOT_DIR/modules/fail2ban.sh"
    header() { :; }
    section() { :; }
    pause() { :; }
    err() { :; }
    backup_create() { printf "%s\n" "/tmp/backup"; }
    ensure_fail2ban_installed() { return 0; }
    ensure_default_whitelist() { return 1; }
    module_fail2ban_sync_whitelist
    printf "returned-to-menu\n"
  ' | grep -q '^returned-to-menu$'
}

test_network_apply_does_not_report_unconditional_success() {
  local file="$ROOT_DIR/modules/network.sh"
  grep -Fq 'runtime application may be partial' "$file" || return 1
  grep -Fq 'Network configuration finished with warnings' "$file" || return 1
  grep -Fq 'grep -qxF' "$file" || return 1
  if grep -Fq 'echo tcp_bbr > /etc/modules-load.d/bbr.conf' "$file"; then
    return 1
  fi
}

test_firewall_menu_makes_apply_boundary_clear() {
  grep -Fq 'Import bundled blocklist into SSO state' "$ROOT_DIR/sso.sh" || return 1
  grep -Fq 'Apply/refresh SSO firewall rules' "$ROOT_DIR/sso.sh" || return 1
}

test_firewall_system_check_explains_missing_ipset() {
  local output
  output="$(ROOT_DIR="$ROOT_DIR" bash -c '
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/utils.sh"
    cmd_exists() {
      [[ "$1" == "iptables" ]]
    }
    info() { printf "INFO:%s\n" "$*"; }
    warn() { printf "WARN:%s\n" "$*"; }
    firewall_info
  ')" || return 1

  grep -Fq 'iptables is present but ipset is missing' <<<"$output" || return 1
  grep -Fq 'apt-get update && apt-get install -y ipset' <<<"$output" || return 1
}

test_firewall_system_check_accepts_iptables_with_ipset() {
  local output
  output="$(ROOT_DIR="$ROOT_DIR" bash -c '
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/utils.sh"
    cmd_exists() {
      [[ "$1" == "iptables" || "$1" == "ipset" ]]
    }
    info() { printf "INFO:%s\n" "$*"; }
    warn() { printf "WARN:%s\n" "$*"; }
    firewall_info
  ')" || return 1

  grep -Fq 'SSO firewall backend: iptables + ipset ready' <<<"$output" || return 1
}

run_test "v1.1.0 release-candidate version is shown in the UI" test_release_candidate_version_is_visible
run_test "Fail2Ban menu describes SSO-only disable behavior" test_fail2ban_menu_does_not_claim_service_stop_is_rollback
run_test "invalid Fail2Ban whitelist returns cleanly to the menu" test_fail2ban_invalid_whitelist_returns_to_menu
run_test "network apply failures are not presented as unconditional success" test_network_apply_does_not_report_unconditional_success
run_test "firewall menu clearly separates import from apply" test_firewall_menu_makes_apply_boundary_clear
run_test "System Check explains when iptables is present but ipset is missing" test_firewall_system_check_explains_missing_ipset
run_test "System Check accepts iptables plus ipset as a usable backend" test_firewall_system_check_accepts_iptables_with_ipset
finish_tests
