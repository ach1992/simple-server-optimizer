#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

test_runtime_paths_are_canonical_and_persistence_is_independent() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"

    INSTALL_DIR="$tmp/install"
    STATE_DIR="$tmp/state"
    LAUNCHER_PATH="$tmp/bin/sso"
    validate_runtime_paths

    local bad
    for bad in '/root/' '/root/.' '/tmp/../root' '//root/simple-server-optimizer' '/opt/sso/../sso'; do
      INSTALL_DIR="$bad"
      STATE_DIR="$tmp/state"
      LAUNCHER_PATH="$tmp/bin/sso"
      if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi
    done

    INSTALL_DIR="$tmp/install"
    STATE_DIR='/etc'
    LAUNCHER_PATH="$tmp/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    INSTALL_DIR="$tmp/install"
    STATE_DIR="$tmp/install/state"
    LAUNCHER_PATH="$tmp/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    STATE_DIR="$tmp/install.bak/state"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    STATE_DIR="$tmp/state"
    INSTALL_DIR="$tmp/state/install"
    LAUNCHER_PATH="$tmp/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    INSTALL_DIR="$tmp/install"
    STATE_DIR="$tmp/state"
    LAUNCHER_PATH="$tmp/install/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    LAUNCHER_PATH="$tmp/install.bak/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    mkdir -p "$tmp/real-install"
    ln -s "$tmp/real-install" "$tmp/install-link"
    INSTALL_DIR="$tmp/install-link"
    STATE_DIR="$tmp/state"
    LAUNCHER_PATH="$tmp/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_finish_install_only_runs_after_success() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"

    SOURCE_DIR="$tmp/source"
    has_local_payload() { return 0; }
    install_local() { return 42; }
    download_online() { return 43; }
    finish_install() { : > "$tmp/FINISHED"; return 0; }
    read_input() { local -n out="$2"; out=1; }
    say() { :; }
    info() { :; }
    err() { :; }

    if menu local; then exit 1; fi
    [[ ! -e "$tmp/FINISHED" ]]

    if menu online; then exit 1; fi
    [[ ! -e "$tmp/FINISHED" ]]

    if menu auto; then exit 1; fi
    [[ ! -e "$tmp/FINISHED" ]]

    has_local_payload() { return 1; }
    if menu auto; then exit 1; fi
    [[ ! -e "$tmp/FINISHED" ]]

    install_local() { return 0; }
    has_local_payload() { return 0; }
    menu local
    [[ -f "$tmp/FINISHED" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

run_test "runtime paths are canonical and durable state/launcher stay outside replaceable trees" test_runtime_paths_are_canonical_and_persistence_is_independent
run_test "finish_install runs only after successful install/download" test_finish_install_only_runs_after_success
finish_tests
