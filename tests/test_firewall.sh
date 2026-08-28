#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/testlib.sh"

setup_firewall_test() {
  local t="$1"
  STATE_DIR="$t/state"
  ASSETS_DIR="$t/assets"
  SSO_DIR="$t/install"
  mkdir -p "$STATE_DIR" "$ASSETS_DIR" "$SSO_DIR"
  printf '127.0.0.1\n' > "$ASSETS_DIR/whitelist-default.ipv4"
  source "$ROOT_DIR/modules/utils.sh"
  source "$ROOT_DIR/modules/firewall.sh"
}

test_invalid_state_is_rejected_before_apply() (
  local t
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  printf '1.2.3.4\n999.1.1.1\n' > "$STATE_BLOCKLIST"

  if ensure_state_blocklist >/dev/null 2>&1; then
    return 1
  fi
  grep -qx '999.1.1.1' "$STATE_BLOCKLIST" || return 1
)

test_nft_backend_failure_propagates() (
  local t calls=0
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  printf '1.2.3.4\n' > "$STATE_BLOCKLIST"

  nft() {
    calls=$((calls + 1))
    if [[ "$*" == 'list table inet sso' ]]; then
      return 1
    fi
    if (( calls >= 5 )); then
      return 42
    fi
    return 0
  }

  if nft_apply >/dev/null 2>&1; then
    return 1
  fi
)

test_nft_blocklist_uses_one_batch_call() (
  local t log
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  log="$t/nft.log"
  printf '1.2.3.4\n2.3.4.0/24\n' > "$STATE_BLOCKLIST"

  nft() {
    printf '%s\n' "$*" >> "$log"
    case "$*" in
      'list table inet sso') [[ -f "$t/table" ]] ;;
      'add table inet sso') touch "$t/table"; return 0 ;;
      'delete table inet sso') rm -f "$t/table"; return 0 ;;
      *) return 0 ;;
    esac
  }

  nft_apply >/dev/null || return 1
  [[ "$(grep -c 'add element inet sso sso_block_v4' "$log")" -eq 1 ]] || return 1
  grep -Fq '1.2.3.4,2.3.4.0/24' "$log" || return 1
)

test_active_nft_add_is_immediate_and_persisted() (
  local t log
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  log="$t/nft.log"
  : > "$STATE_BLOCKLIST"

  cmd_exists() { [[ "$1" == nft ]]; }
  nft() {
    printf '%s\n' "$*" >> "$log"
    case "$*" in
      'list table inet sso') return 0 ;;
      'get element inet sso sso_block_v4 { 8.8.8.8 }') return 1 ;;
      'add element inet sso sso_block_v4 { 8.8.8.8 }') return 0 ;;
      *) return 0 ;;
    esac
  }

  firewall_list_change block add 8.8.8.8 >/dev/null || return 1
  grep -qx '8.8.8.8' "$STATE_BLOCKLIST" || return 1
  grep -Fq 'add element inet sso sso_block_v4 { 8.8.8.8 }' "$log" || return 1
)

test_runtime_failure_restores_persisted_list() (
  local t
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  printf '1.1.1.1\n' > "$STATE_BLOCKLIST"

  cmd_exists() { [[ "$1" == nft ]]; }
  nft() {
    case "$*" in
      'list table inet sso') return 0 ;;
      'get element inet sso sso_block_v4 { 8.8.8.8 }') return 1 ;;
      'add element inet sso sso_block_v4 { 8.8.8.8 }') return 9 ;;
      *) return 0 ;;
    esac
  }

  if firewall_list_change block add 8.8.8.8 >/dev/null 2>&1; then
    return 1
  fi
  [[ "$(cat "$STATE_BLOCKLIST")" == '1.1.1.1' ]] || return 1
)

test_active_ipset_whitelist_remove_is_immediate() (
  local t log
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  log="$t/ipset.log"
  printf '10.235.0.0/19\n203.0.113.5\n' > "$STATE_WHITELIST"

  cmd_exists() {
    [[ "$1" == ipset || "$1" == iptables ]]
  }
  iptables() { return 0; }
  ipset() {
    printf '%s\n' "$*" >> "$log"
    case "$*" in
      'list sso_block_v4'|'list sso_white_v4') return 0 ;;
      'test sso_white_v4 203.0.113.5') return 0 ;;
      'del sso_white_v4 203.0.113.5') return 0 ;;
      *) return 0 ;;
    esac
  }

  firewall_list_change white remove 203.0.113.5 >/dev/null || return 1
  ! grep -qx '203.0.113.5' "$STATE_WHITELIST" || return 1
  grep -qx '10.235.0.0/19' "$STATE_WHITELIST" || return 1
  grep -Fq 'del sso_white_v4 203.0.113.5' "$log" || return 1
)

test_nft_reapply_replaces_existing_sso_table() (
  local t log
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  log="$t/nft.log"
  : > "$STATE_BLOCKLIST"

  nft() {
    printf '%s\n' "$*" >> "$log"
    case "$*" in
      'list table inet sso') [[ -f "$t/table" ]] ;;
      'add table inet sso') touch "$t/table"; return 0 ;;
      'delete table inet sso') rm -f "$t/table"; return 0 ;;
      *) return 0 ;;
    esac
  }

  nft_apply >/dev/null || return 1
  nft_apply >/dev/null || return 1
  [[ "$(grep -c '^delete table inet sso$' "$log")" -eq 1 ]] || return 1
)

run_test "invalid stored firewall entries are rejected before apply" test_invalid_state_is_rejected_before_apply
run_test "nft backend failures propagate instead of false-success" test_nft_backend_failure_propagates
run_test "nft blocklist loading uses one batch element call" test_nft_blocklist_uses_one_batch_call
run_test "active nft blacklist add persists and applies immediately" test_active_nft_add_is_immediate_and_persisted
run_test "runtime update failure restores the persisted list" test_runtime_failure_restores_persisted_list
run_test "active ipset whitelist removal applies immediately" test_active_ipset_whitelist_remove_is_immediate
run_test "re-applying nft rules replaces the existing SSO table" test_nft_reapply_replaces_existing_sso_table
finish_tests
