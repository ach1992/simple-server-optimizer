#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

source_firewall_fixture() {
  local tmp="$1"
  STATE_DIR="$tmp/state"
  ASSETS_DIR="$ROOT_DIR/assets"
  SSO_DIR="$ROOT_DIR"
  BACKUP_DIR_BASE="$tmp/backups"
  unset FIREWALL_LOCK_FILE FIREWALL_LOCK_FD
  mkdir -p "$STATE_DIR"
  # shellcheck source=modules/utils.sh
  source "$ROOT_DIR/modules/utils.sh"
  # shellcheck source=modules/firewall.sh
  source "$ROOT_DIR/modules/firewall.sh"
}

test_sanitize_canonicalizes_and_collapses_networks() {
  local tmp out
  tmp="$(mktemp -d)" || return 1
  source_firewall_fixture "$tmp"
  out="$(printf '%s\n' \
    '10.235.0.0/19' \
    '10.0.0.0/8' \
    '10.0.0.5/24' \
    '001.002.003.004/32' \
    '192.0.2.1 # comment' \
    '192.0.2.0/31' | sanitize_iplist)" || {
    rm -rf "$tmp"
    return 1
  }

  local expected
  expected=$'1.2.3.4\n10.0.0.0/8\n192.0.2.0/31'
  rm -rf "$tmp"
  [[ "$out" == "$expected" ]]
}

test_sanitize_rejects_invalid_without_partial_output() {
  local tmp out rc
  tmp="$(mktemp -d)" || return 1
  source_firewall_fixture "$tmp"
  out="$(mktemp)"
  if printf '1.2.3.4\n999.2.3.4\n' | sanitize_iplist > "$out" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  local bytes
  bytes="$(wc -c < "$out" | tr -d ' ')"
  rm -rf "$tmp" "$out"
  [[ "$rc" -ne 0 && "$bytes" == "0" ]]
}

test_repository_blocklist_uses_bounded_nft_batches() {
  local tmp normalized log
  tmp="$(mktemp -d)" || return 1
  source_firewall_fixture "$tmp"
  normalized="$tmp/blocklist"
  log="$tmp/batches.log"
  sanitize_iplist < "$ROOT_DIR/assets/blocklist-ip.ipv4" > "$normalized" || {
    rm -rf "$tmp"
    return 1
  }

  nft_apply_chunk_file() {
    local file="$1"
    local commands
    commands="$(grep -c '^add element ' "$file")"
    printf '%s\n' "$commands" >> "$log"
    [[ "$commands" == "1" ]]
  }

  SSO_NFT_CHUNK_SIZE=500
  nft_populate_set_batched sso sso_block_v4 "$normalized" >/dev/null || {
    rm -rf "$tmp"
    return 1
  }

  local batches entries
  batches="$(wc -l < "$log" | tr -d ' ')"
  entries="$(wc -l < "$normalized" | tr -d ' ')"
  rm -rf "$tmp"
  [[ "$entries" == "4224" && "$batches" == "9" ]]
}

test_nft_chunk_failure_is_not_reported_as_success() {
  local tmp mock rules marker
  tmp="$(mktemp -d)" || return 1
  mock="$tmp/bin"
  rules="$tmp/rules.nft"
  marker="$tmp/nft-called"
  mkdir -p "$mock"
  cat > "$mock/nft" <<MOCK
#!/usr/bin/env bash
: > "$marker"
if [[ "\$*" == *"-c -f"* ]]; then
  exit 17
fi
exit 0
MOCK
  chmod +x "$mock/nft"
  printf 'add element inet sso s { 1.2.3.4 }\n' > "$rules"

  PATH="$mock:$PATH" ROOT_DIR="$ROOT_DIR" FIXTURE="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE/state"; ASSETS_DIR="$ROOT_DIR/assets"; SSO_DIR="$ROOT_DIR"
    mkdir -p "$STATE_DIR"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/firewall.sh"
    if nft_apply_chunk_file "$FIXTURE/rules.nft" >/dev/null 2>&1; then
      exit 1
    fi
  ' || {
    rm -rf "$tmp"
    return 1
  }

  local rc=0
  [[ -f "$marker" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_immediate_blocklist_add_persists_and_applies() {
  local tmp log
  tmp="$(mktemp -d)" || return 1
  log="$tmp/apply.log"
  source_firewall_fixture "$tmp"
  printf '2.2.2.2\n' > "$STATE_BLOCKLIST"

  firewall_get_active_backends() {
    local -n out="$1"
    out=(nft)
  }
  firewall_apply_backend() {
    printf '%s\n' "$1" >> "$log"
  }

  firewall_update_list_entry block add 1.2.3.4 >/dev/null || {
    rm -rf "$tmp"
    return 1
  }

  local rc=0
  grep -qx '1.2.3.4' "$STATE_BLOCKLIST" || rc=1
  grep -qx '2.2.2.2' "$STATE_BLOCKLIST" || rc=1
  [[ "$(cat "$log")" == "nft" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_failed_immediate_apply_restores_persisted_list() {
  local tmp before after
  tmp="$(mktemp -d)" || return 1
  source_firewall_fixture "$tmp"
  printf '2.2.2.2\n' > "$STATE_BLOCKLIST"
  before="$(cat "$STATE_BLOCKLIST")"

  firewall_get_active_backends() {
    local -n out="$1"
    out=(nft)
  }
  firewall_apply_backend() { return 1; }

  if firewall_update_list_entry block add 1.2.3.4 >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  after="$(cat "$STATE_BLOCKLIST")"
  rm -rf "$tmp"
  [[ "$after" == "$before" ]]
}

test_required_whitelist_coverage_cannot_be_removed_directly() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  source_firewall_fixture "$tmp"
  firewall_get_active_backends() {
    local -n out="$1"
    out=()
  }

  if firewall_update_list_entry white remove 10.235.0.0/19 >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  local rc=0
  grep -qx '10.0.0.0/8' "$STATE_WHITELIST" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

test_ambiguous_dual_nft_tables_fail_closed() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  source_firewall_fixture "$tmp"
  cmd_exists() { [[ "$1" == "nft" ]]; }
  nft_table_is_active() { return 0; }

  local -a active=()
  if firewall_get_active_backends active >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
}

test_ipset_path_validates_iptables_before_live_swap() {
  local tmp log mock marker
  tmp="$(mktemp -d)" || return 1
  log="$tmp/commands.log"
  mock="$tmp/bin"
  marker="$tmp/iptables-validated"
  mkdir -p "$mock" "$tmp/state"
  : > "$log"

  cat > "$mock/ipset" <<'MOCK'
#!/usr/bin/env bash
printf 'ipset %s\n' "$*" >> "$SSO_TEST_COMMAND_LOG"
if [[ "${1:-}" == "swap" && ! -f "$SSO_TEST_VALIDATED_MARKER" ]]; then
  exit 88
fi
exit 0
MOCK
  cat > "$mock/iptables" <<'MOCK'
#!/usr/bin/env bash
printf 'iptables %s\n' "$*" >> "$SSO_TEST_COMMAND_LOG"
exit 0
MOCK
  cat > "$mock/iptables-restore" <<'MOCK'
#!/usr/bin/env bash
printf 'iptables-restore %s\n' "$*" >> "$SSO_TEST_COMMAND_LOG"
cat >/dev/null
if [[ " $* " == *" --test "* ]]; then
  : > "$SSO_TEST_VALIDATED_MARKER"
fi
exit 0
MOCK
  chmod +x "$mock"/*

  PATH="$mock:$PATH" \
  SSO_TEST_COMMAND_LOG="$log" \
  SSO_TEST_VALIDATED_MARKER="$marker" \
  ROOT_DIR="$ROOT_DIR" FIXTURE="$tmp" bash -c '
    set -Eeuo pipefail
    STATE_DIR="$FIXTURE/state"; ASSETS_DIR="$ROOT_DIR/assets"; SSO_DIR="$ROOT_DIR"
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/firewall.sh"
    _ensure_default_whitelist_core() { printf "10.0.0.0/8\n" > "$STATE_WHITELIST"; }
    _ensure_state_blocklist_core() { printf "1.2.3.4\n" > "$STATE_BLOCKLIST"; }
    ipset_prepare_next_sets() { printf "prepare-next\n" >> "$SSO_TEST_COMMAND_LOG"; }
    ipset_cleanup_next_sets() { printf "cleanup-next\n" >> "$SSO_TEST_COMMAND_LOG"; }
    iptables_build_restore_file() { printf "*filter\nCOMMIT\n" > "$1"; }
    _ipset_apply_core >/dev/null
  ' || {
    rm -rf "$tmp"
    return 1
  }

  local rc=0
  [[ -f "$marker" ]] || rc=1
  grep -q '^ipset swap sso_block_v4_next sso_block_v4$' "$log" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

run_test "firewall sanitizer canonicalizes and collapses redundant IPv4 networks" test_sanitize_canonicalizes_and_collapses_networks
run_test "firewall sanitizer rejects invalid input without partial output" test_sanitize_rejects_invalid_without_partial_output
run_test "repository blocklist is staged in nine bounded nft batches" test_repository_blocklist_uses_bounded_nft_batches
run_test "nft validation failure cannot produce a false success" test_nft_chunk_failure_is_not_reported_as_success
run_test "blacklist add persists and applies immediately when firewall is active" test_immediate_blocklist_add_persists_and_applies
run_test "failed immediate firewall apply restores the previous persisted list" test_failed_immediate_apply_restores_persisted_list
run_test "managed whitelist safety coverage cannot be removed directly" test_required_whitelist_coverage_cannot_be_removed_directly
run_test "ambiguous dual nft active tables fail closed" test_ambiguous_dual_nft_tables_fail_closed
run_test "iptables restore is validated before ipset live swap" test_ipset_path_validates_iptables_before_live_swap
finish_tests
