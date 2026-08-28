#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"
# shellcheck source=modules/utils.sh
source "$ROOT_DIR/modules/utils.sh"

read_input() {
  local _prompt="$1"
  local -n _out="$2"
  _out="7"
}

test_prompt_choice_writes_named_output() {
  local choice=""
  prompt_choice "Select" choice >/dev/null 2>&1 || return 1
  [[ "$choice" == "7" ]]
}

test_validate_ipv4_helpers() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  STATE_DIR="$tmp"
  ASSETS_DIR="$ROOT_DIR/assets"
  # shellcheck source=modules/firewall.sh
  source "$ROOT_DIR/modules/firewall.sh"

  local rc=0
  validate_ipv4_or_cidr "1.2.3.4" || rc=1
  validate_ipv4_or_cidr "10.20.30.0/24" || rc=1
  if validate_ipv4_or_cidr "999.2.3.4"; then rc=1; fi
  if validate_ipv4_or_cidr "not-an-ip"; then rc=1; fi
  rm -rf "$tmp"
  return "$rc"
}

test_ensure_dirs_does_not_clobber_caller_d() {
  local tmp d
  tmp="$(mktemp -d)" || return 1
  d="expected-backup-path"

  ensure_dirs "$tmp/one" "$tmp/two" || { rm -rf "$tmp"; return 1; }

  local rc=0
  [[ "$d" == "expected-backup-path" ]] || rc=1
  [[ -d "$tmp/one" && -d "$tmp/two" ]] || rc=1
  rm -rf "$tmp"
  return "$rc"
}


test_semantic_menu_helpers_preserve_plain_text_and_success() {
  local output
  local saved_c_reset="$c_reset" saved_c_bold="$c_bold" saved_c_dim="$c_dim"
  local saved_c_grn="$c_grn" saved_c_ylw="$c_ylw" saved_c_cyn="$c_cyn" saved_c_mag="$c_mag"

  c_reset=""; c_bold=""; c_dim=""; c_grn=""; c_ylw=""; c_cyn=""; c_mag=""
  output="$({
    menu_item '1) Normal action'
    menu_warn '2) High-impact action'
    menu_secondary '0) Back'
    status_active 'Feature: ACTIVE'
    status_inactive 'Feature: inactive'
    section 'Section title'
  })" || return 1

  c_reset="$saved_c_reset"; c_bold="$saved_c_bold"; c_dim="$saved_c_dim"
  c_grn="$saved_c_grn"; c_ylw="$saved_c_ylw"; c_cyn="$saved_c_cyn"; c_mag="$saved_c_mag"

  printf '%s\n' "$output" | grep -Fqx '1) Normal action' || return 1
  printf '%s\n' "$output" | grep -Fqx '2) High-impact action' || return 1
  printf '%s\n' "$output" | grep -Fqx '0) Back' || return 1
  printf '%s\n' "$output" | grep -Fqx 'Feature: ACTIVE' || return 1
  printf '%s\n' "$output" | grep -Fqx 'Feature: inactive' || return 1
  printf '%s\n' "$output" | grep -Fqx 'Section title' || return 1
}
run_test "prompt_choice writes to the caller-provided variable" test_prompt_choice_writes_named_output
run_test "IPv4/CIDR validator rejects malformed values" test_validate_ipv4_helpers
run_test "ensure_dirs does not overwrite a caller's local d variable" test_ensure_dirs_does_not_clobber_caller_d
run_test "semantic menu helpers preserve plain text and success return codes" test_semantic_menu_helpers_preserve_plain_text_and_success
finish_tests
