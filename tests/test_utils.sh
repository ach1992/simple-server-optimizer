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

run_test "prompt_choice writes to the caller-provided variable" test_prompt_choice_writes_named_output
run_test "IPv4/CIDR validator rejects malformed values" test_validate_ipv4_helpers
finish_tests
