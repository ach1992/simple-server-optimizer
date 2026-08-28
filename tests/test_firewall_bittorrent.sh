#!/usr/bin/env bash
set -Euo pipefail

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
test_bittorrent_enable_applies_immediately_when_active() (
  local t output
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  firewall_active_backend() { printf '%s\n' nft; }
  firewall_apply_active_backend() {
    [[ -f "$STATE_BTFLAG" ]] || return 9
    touch "$t/applied"
  }

  output="$(firewall_set_bittorrent_state enabled)" || return 1
  [[ -f "$STATE_BTFLAG" && -f "$t/applied" ]] || return 1
  printf '%s\n' "$output" | grep -Fq 'saved and applied immediately using nftables' || return 1
)

test_bittorrent_disable_applies_immediately_when_active() (
  local t output
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  : > "$STATE_BTFLAG"
  firewall_active_backend() { printf '%s\n' ipset; }
  firewall_apply_active_backend() {
    [[ ! -f "$STATE_BTFLAG" ]] || return 9
    touch "$t/applied"
  }

  output="$(firewall_set_bittorrent_state disabled)" || return 1
  [[ ! -f "$STATE_BTFLAG" && -f "$t/applied" ]] || return 1
  printf '%s\n' "$output" | grep -Fq 'saved and applied immediately using iptables+ipset' || return 1
)

test_bittorrent_live_failure_restores_previous_saved_and_runtime_state() (
  local t output calls=0
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  firewall_active_backend() { printf '%s\n' nft; }
  firewall_apply_active_backend() {
    calls=$((calls + 1))
    if [[ "$calls" -eq 1 ]]; then
      [[ -f "$STATE_BTFLAG" ]] || return 8
      return 9
    fi
    [[ ! -f "$STATE_BTFLAG" ]]
  }

  if firewall_set_bittorrent_state enabled > "$t/output" 2>&1; then
    return 1
  fi
  output="$(cat "$t/output")"
  [[ "$calls" -eq 2 ]] || return 1
  [[ ! -f "$STATE_BTFLAG" ]] || return 1
  printf '%s\n' "$output" | grep -Fq 'previous saved toggle and active rules were restored' || return 1
)

test_bittorrent_inactive_change_never_auto_enables_firewall() (
  local t output
  t="$(mktemp -d)" || return 1
  setup_firewall_test "$t"
  firewall_active_backend() { printf '%s\n' none; }
  firewall_apply_active_backend() { touch "$t/unexpected-apply"; return 0; }

  output="$(firewall_set_bittorrent_state enabled)" || return 1
  [[ -f "$STATE_BTFLAG" ]] || return 1
  [[ ! -e "$t/unexpected-apply" ]] || return 1
  printf '%s\n' "$output" | grep -Fq 'firewall is inactive; it was not enabled' || return 1
)

run_test "BitTorrent enable applies immediately on an active firewall" test_bittorrent_enable_applies_immediately_when_active
run_test "BitTorrent disable applies immediately on an active firewall" test_bittorrent_disable_applies_immediately_when_active
run_test "BitTorrent live failure restores previous saved/runtime state" test_bittorrent_live_failure_restores_previous_saved_and_runtime_state
run_test "BitTorrent toggle never auto-enables an inactive firewall" test_bittorrent_inactive_change_never_auto_enables_firewall
finish_tests
