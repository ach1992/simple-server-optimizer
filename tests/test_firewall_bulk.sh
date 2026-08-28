#!/usr/bin/env bash
set -Euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/testlib.sh"

setup_case() {
  local t="$1"
  STATE_DIR="$t/state"; ASSETS_DIR="$t/assets"; SSO_DIR="$t/install"
  mkdir -p "$STATE_DIR" "$ASSETS_DIR" "$SSO_DIR"
  printf '127.0.0.1\n' > "$ASSETS_DIR/whitelist-default.ipv4"
  source "$ROOT_DIR/modules/utils.sh"
  source "$ROOT_DIR/modules/firewall.sh"
}

test_parse_and_dedupe() (
  local t d=0; local -a ok=() bad=()
  t="$(mktemp -d)"; setup_case "$t"
  firewall_parse_entries '203.0.113.10, 198.51.100.0/24 203.0.113.10,,192.0.2.5' ok bad d
  [[ "${ok[*]}" == '203.0.113.10 198.51.100.0/24 192.0.2.5' && ${#bad[@]} -eq 0 && $d -eq 1 ]]
)

test_invalid_batch_is_atomic() (
  local t out; t="$(mktemp -d)"; setup_case "$t"; printf '1.1.1.1\n' > "$STATE_BLOCKLIST"
  firewall_active_backend() { touch "$t/probed"; printf 'nft\n'; }
  if out="$(firewall_list_change block add '8.8.8.8 bad 999.1.1.1' 2>&1)"; then return 1; fi
  [[ "$(cat "$STATE_BLOCKLIST")" == '1.1.1.1' && ! -e "$t/probed" ]] || return 1
  grep -Fq 'bad' <<<"$out" && grep -Fq '999.1.1.1' <<<"$out"
)

test_protected_whitelist_is_atomic() (
  local t; t="$(mktemp -d)"; setup_case "$t"
  printf '10.235.0.0/19\n203.0.113.5\n' > "$STATE_WHITELIST"
  firewall_active_backend() { touch "$t/probed"; printf 'nft\n'; }
  ! firewall_list_change white remove '203.0.113.5,10.235.0.0/19' >/dev/null 2>&1 || return 1
  grep -qx '203.0.113.5' "$STATE_WHITELIST" && [[ ! -e "$t/probed" ]]
)

test_nft_bulk_immediate() (
  local t log out; t="$(mktemp -d)"; setup_case "$t"; log="$t/log"; : > "$STATE_BLOCKLIST"
  firewall_active_backend() { printf 'nft\n'; }; nft() { printf '%s\n' "$*" >> "$log"; }
  out="$(firewall_list_change block add '8.8.8.8,9.9.9.0/24')" || return 1
  grep -Fq 'add element inet sso sso_block_v4 { 8.8.8.8,9.9.9.0/24 }' "$log" || return 1
  grep -Fq 'Applied now: yes (nftables)' <<<"$out" || return 1
  firewall_list_change block remove '8.8.8.8 9.9.9.0/24' >/dev/null || return 1
  grep -Fq 'delete element inet sso sso_block_v4 { 8.8.8.8,9.9.9.0/24 }' "$log"
)

test_ipset_bulk_immediate() (
  local t log; t="$(mktemp -d)"; setup_case "$t"; log="$t/log"; : > "$STATE_BLOCKLIST"
  firewall_active_backend() { printf 'ipset\n'; }; ipset() { printf '%s\n' "$*" >> "$log"; }
  firewall_list_change block add '8.8.4.4 9.9.9.9' >/dev/null || return 1
  grep -Fq 'add sso_block_v4 8.8.4.4' "$log" && grep -Fq 'add sso_block_v4 9.9.9.9' "$log" || return 1
  firewall_list_change block remove '8.8.4.4,9.9.9.9' >/dev/null || return 1
  grep -Fq 'del sso_block_v4 8.8.4.4' "$log" && grep -Fq 'del sso_block_v4 9.9.9.9' "$log"
)

test_ipset_failure_rolls_back() (
  local t log; t="$(mktemp -d)"; setup_case "$t"; log="$t/log"; printf '1.1.1.1\n' > "$STATE_BLOCKLIST"
  firewall_active_backend() { printf 'ipset\n'; }
  ipset() { printf '%s\n' "$*" >> "$log"; [[ "$*" != 'add sso_block_v4 9.9.9.9' ]]; }
  ! firewall_list_change block add '8.8.8.8 9.9.9.9' >/dev/null 2>&1 || return 1
  [[ "$(cat "$STATE_BLOCKLIST")" == '1.1.1.1' ]] && grep -Fq 'del sso_block_v4 8.8.8.8' "$log"
)

test_summary_and_inactive_no_enable() (
  local t out; t="$(mktemp -d)"; setup_case "$t"; printf '1.1.1.1\n' > "$STATE_BLOCKLIST"
  firewall_active_backend() { printf 'none\n'; }; firewall_persist_enable() { touch "$t/enabled"; }
  out="$(firewall_list_change block add '1.1.1.1,8.8.8.8 8.8.8.8')" || return 1
  [[ "$(grep -c '^8.8.8.8$' "$STATE_BLOCKLIST")" -eq 1 && ! -e "$t/enabled" ]] || return 1
  grep -Fq 'Requested: 2' <<<"$out" && grep -Fq 'Added: 1' <<<"$out" && grep -Fq 'Already present: 1' <<<"$out" && grep -Fq 'Duplicates ignored: 1' <<<"$out" && grep -Fq 'Applied now: no (SSO firewall inactive)' <<<"$out"
)

test_guidance_uses_read_input() (
  local t out entered=''; t="$(mktemp -d)"; setup_case "$t"
  firewall_active_backend() { printf 'none\n'; }
  read_input() { local -n v="$2"; printf '%s' "$1" > "$t/prompt"; v='203.0.113.10,198.51.100.0/24'; }
  firewall_read_entries 'add to blacklist' entered > "$t/out" || return 1; out="$(cat "$t/out")"
  [[ "$entered" == '203.0.113.10,198.51.100.0/24' && "$(cat "$t/prompt")" == 'Entries: ' ]] || return 1
  grep -Fq 'comma and/or spaces' <<<"$out" && grep -Fq 'will not be enabled' <<<"$out"
)

run_test "bulk parser/dedupe" test_parse_and_dedupe
run_test "invalid batch is atomic" test_invalid_batch_is_atomic
run_test "protected whitelist batch is atomic" test_protected_whitelist_is_atomic
run_test "nft bulk applies immediately" test_nft_bulk_immediate
run_test "ipset bulk applies immediately" test_ipset_bulk_immediate
run_test "ipset failure rolls back" test_ipset_failure_rolls_back
run_test "summary and inactive no-enable" test_summary_and_inactive_no_enable
run_test "guidance uses existing input flow" test_guidance_uses_read_input
finish_tests
