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

run_test "v1.1.0 release-candidate version is shown in the UI" test_release_candidate_version_is_visible
run_test "Fail2Ban menu describes SSO-only disable behavior" test_fail2ban_menu_does_not_claim_service_stop_is_rollback
run_test "network apply failures are not presented as unconditional success" test_network_apply_does_not_report_unconditional_success
run_test "firewall menu clearly separates import from apply" test_firewall_menu_makes_apply_boundary_clear
finish_tests
