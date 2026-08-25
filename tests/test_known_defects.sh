#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/testlib.sh"

rollback_choose_uses_prompt_contract() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/20260101-000000"

  ROOT_DIR="$ROOT_DIR" BACKUP_DIR_BASE="$tmp" bash -c '
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/rollback.sh"
    header() { :; }
    section() { :; }
    err() { :; }
    pause() { :; }
    restore_from_dir() { :; }
    read_input() {
      local _prompt="$1"
      local -n _out="$2"
      _out="0"
    }
    module_rollback_choose >/dev/null 2>&1
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

backup_create_returns_only_path_on_stdout() {
  local tmp
  tmp="$(mktemp -d)" || return 1

  local captured
  captured="$(
    (
      source "$ROOT_DIR/modules/utils.sh"
      source "$ROOT_DIR/modules/rollback.sh"

      BACKUP_DIR_BASE="$tmp"
      backup_create_dir() {
        local d="$BACKUP_DIR_BASE/backup-id"
        mkdir -p "$d"
        printf '%s\n' "$d"
      }
      backup_capture_sysctl() { :; }
      backup_capture_qdisc() { :; }
      backup_capture_firewall() { :; }
      backup_capture_cpu_irq() { :; }
      backup_capture_state() { :; }
      backup_capture_fail2ban() { :; }
      backup_capture_services() { :; }
      backup_mark() { :; }

      backup_create "test:contract"
    )
  )" || {
    rm -rf "$tmp"
    return 1
  }

  local expected="$tmp/backup-id"
  rm -rf "$tmp"
  [[ "$captured" == "$expected" ]]
}

run_test "rollback chooser follows prompt_choice output-variable contract" rollback_choose_uses_prompt_contract
run_test "backup_create stdout is a machine-readable path only" backup_create_returns_only_path_on_stdout
finish_tests
